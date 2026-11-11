import Foundation

public enum ProjectError: Error, Equatable, CustomStringConvertible {
    /// The file was saved by a newer MacPlayer. Opening it could lose data, so it is refused.
    case newerVersion(Int)
    case corrupted(String)

    public var description: String {
        switch self {
        case .newerVersion(let v): return "This project was saved by a newer version of MacPlayer (format \(v)). Update MacPlayer to open it."
        case .corrupted(let m): return "The project file is damaged: \(m)"
        }
    }
}

/// The on-disk project format: JSON with a schema version and a chain of migrations (design section 10).
public enum ProjectCodec {
    /// `migrations[n]` upgrades a document from schema n to n+1, working on the raw JSON dictionary.
    /// 1 -> 2: layers over the timeline did not exist, so an old project has none.
    /// 2 -> 3: "mode" (quick / project) gives way to "kind" (video / photo); the quick edit of one video is turned into a
    ///         timeline after decoding (`ProjectUpgrade`), because that needs typed values.
    nonisolated(unsafe) public static var migrations: [Int: (inout [String: Any]) throws -> Void] = [
        1: { obj in if obj["overlayClips"] == nil { obj["overlayClips"] = [Any]() } },
        2: { obj in
            if obj["kind"] == nil {
                let firstPath = ((obj["sources"] as? [[String: Any]])?.first)?["path"] as? String
                obj["kind"] = ProjectUpgrade.kind(legacyMode: obj["mode"] as? String, firstSourcePath: firstPath).rawValue
            }
            if obj["mode"] == nil { obj["mode"] = "project" }
        },
    ]

    public static func encode(_ p: Project) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates keep their full precision (default strategy): file fingerprints are compared exactly.
        return try enc.encode(p)
    }

    public static func decode(_ data: Data) throws -> Project { try decodeDetailed(data).project }

    /// The project, and the schema the file was written in (below `Project.currentSchema` means it was upgraded on reading).
    public static func decodeDetailed(_ data: Data) throws -> (project: Project, fileSchema: Int) {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ProjectError.corrupted("not a JSON document") }
        var version = obj["schemaVersion"] as? Int ?? 0
        guard version >= 1 else { throw ProjectError.corrupted("missing schema version") }
        if version > Project.currentSchema { throw ProjectError.newerVersion(version) }
        let fileSchema = version
        while version < Project.currentSchema {
            guard let step = migrations[version] else { throw ProjectError.corrupted("no migration from format \(version)") }
            try step(&obj)
            version += 1
            obj["schemaVersion"] = version
        }
        var p: Project
        do {
            let migrated = try JSONSerialization.data(withJSONObject: obj)
            p = try JSONDecoder().decode(Project.self, from: migrated)
        } catch {
            throw ProjectError.corrupted("\(error)")
        }
        if p.mode != nil { ProjectUpgrade.upgradeQuickVideo(&p) }
        p.schemaVersion = Project.currentSchema
        return (p, fileSchema)
    }

    /// The schema a project file says it is in, without decoding the rest (nil when it is not a project file).
    public static func schema(of data: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] as? Int
    }
}

public struct RecoveryCandidate: Equatable, Sendable {
    public var projectID: UUID
    public var name: String
    public var autosavedAt: Date
    /// Where the user last saved this project; nil if it was never saved.
    public var savedPath: String?
    public var autosavePath: String
}

/// Why a project file was not written.
public enum ProjectSaveError: Error, Equatable, CustomStringConvertible {
    /// Only `.macplayer` / `.macvideo` files are ever written: a video or photo is never a target.
    case notAProjectFile(String)
    /// A new project would land on a file that is already there. Nothing is overwritten.
    case exists(String)
    /// The file changed on disk since MacPlayer last wrote or read it (another app, another Mac, a sync service). It is left alone.
    case changedOnDisk(String)
    case folderMissing(String)
    case folderNotWritable(String)
    /// The written file did not read back as the same project.
    case readBackFailed(String)

    public var description: String {
        switch self {
        case .notAProjectFile(let p): return "Only project files are written, not \(p)."
        case .exists(let p): return "A file already exists at \(p). Nothing was overwritten."
        case .changedOnDisk(let p): return "The project file was changed outside MacPlayer: \(p)"
        case .folderMissing(let p): return "The folder is not there: \(p)"
        case .folderNotWritable(let p): return "MacPlayer cannot write to the folder: \(p)"
        case .readBackFailed(let m): return "The saved project did not read back correctly (\(m))."
        }
    }
}

/// Saving projects into their files, keeping crash copies, and keeping restore points.
/// None of this ever touches a video or photo: only project files and MacPlayer's own data are written.
public final class ProjectStore {
    struct Meta: Codable, Equatable { var projectID: UUID; var name: String; var savedPath: String?; var autosavedAt: Date }

    private let fs: FileSystem
    private let recoveryFolder: String
    private let now: () -> Date

    public init(fs: FileSystem, recoveryFolder: String, now: @escaping () -> Date = Date.init) {
        self.fs = fs; self.recoveryFolder = recoveryFolder; self.now = now
    }

    // MARK: Project files

    public static func isProjectPath(_ path: String) -> Bool { ProjectFile.isProject(path: path) }

    /// Makes the file of a new project. Refuses to overwrite anything.
    @discardableResult
    public func create(_ project: Project, at path: String) throws -> FileFingerprint {
        guard Self.isProjectPath(path) else { throw ProjectSaveError.notAProjectFile(path) }
        let dir = PathUtil.directory(of: path)
        guard fs.isDirectory(dir) else { throw ProjectSaveError.folderMissing(dir) }
        guard fs.isWritable(dir) else { throw ProjectSaveError.folderNotWritable(dir) }
        guard !fs.exists(path) else { throw ProjectSaveError.exists(path) }
        return try write(project, to: path)
    }

    /// Writes the project into its file (autosave and "save now"). `expected` is the file as MacPlayer last left it: if the file on
    /// disk is different, someone else changed it and it is not overwritten (unless `force`). Returns the file's new fingerprint.
    @discardableResult
    public func saveFile(_ project: Project, to path: String, expected: FileFingerprint?, force: Bool = false) throws -> FileFingerprint {
        guard Self.isProjectPath(path) else { throw ProjectSaveError.notAProjectFile(path) }
        let dir = PathUtil.directory(of: path)
        guard fs.isDirectory(dir) else { throw ProjectSaveError.folderMissing(dir) }
        if fs.exists(path), !force, let expected, let current = try? fs.fingerprint(path), current != expected {
            throw ProjectSaveError.changedOnDisk(path)
        }
        guard fs.isWritable(dir) else { throw ProjectSaveError.folderNotWritable(dir) }
        return try write(project, to: path)
    }

    /// Kept for callers that only want "write this project here" (the file may exist; it is a project file).
    public func save(_ project: Project, to path: String) throws {
        try saveFile(project, to: path, expected: nil, force: true)
        clearAutosave(projectID: project.id)
    }

    private func write(_ project: Project, to path: String) throws -> FileFingerprint {
        var p = project
        p.modified = now()
        let data = try ProjectCodec.encode(p)
        // The bytes are checked before they reach the disk, and read back after.
        guard (try? ProjectCodec.decode(data)) != nil else { throw ProjectSaveError.readBackFailed("the project could not be encoded") }
        try fs.writeAtomically(data, to: path)
        guard let back = try? fs.read(path), back == data else { throw ProjectSaveError.readBackFailed("the file on disk differs") }
        return try fs.fingerprint(path)
    }

    public func load(path: String) throws -> Project { try loadDetailed(path: path).project }

    public func loadDetailed(path: String) throws -> (project: Project, fileSchema: Int) {
        do { return try ProjectCodec.decodeDetailed(try fs.read(path)) }
        catch let e as ProjectError { throw e }
        catch { throw ProjectError.corrupted("\(error)") }
    }

    /// Before an old file (an older schema) is written in the new format for the first time, the file as it was is copied into the
    /// recovery folder, so the change of format can always be undone by hand. Done once per project and schema.
    public func keepPreUpgradeCopy(of path: String, projectID: UUID, fileSchema: Int) {
        guard fileSchema < Project.currentSchema, fs.exists(path) else { return }
        let dir = folder(projectID)
        let target = PathUtil.join(dir, "pre-upgrade-schema\(fileSchema).\(PathUtil.ext(of: path).isEmpty ? "macplayer" : PathUtil.ext(of: path))")
        guard !fs.exists(target) else { return }
        if !fs.exists(dir) { try? fs.createDirectory(dir) }
        try? fs.copy(from: path, to: target)
    }

    public func preUpgradeCopies(projectID: UUID) -> [String] {
        ((try? fs.contents(ofDirectory: folder(projectID))) ?? []).filter { $0.name.hasPrefix("pre-upgrade-") }.map { PathUtil.join(folder(projectID), $0.name) }
    }

    /// The project file moved (renamed): the crash copy must point at the new place, or it would look "never saved".
    public func updateSavedPath(projectID: UUID, to path: String) {
        let metaPath = PathUtil.join(folder(projectID), "meta.json")
        guard let data = try? fs.read(metaPath), var meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        meta.savedPath = path
        if let d = try? JSONEncoder().encode(meta) { try? fs.writeAtomically(d, to: metaPath) }
    }

    /// Everything MacPlayer keeps for one project (crash copy, restore points, pre-upgrade copy). Used when the project goes to the
    /// Trash, so it can never come back by itself. Only MacPlayer's own data folder is touched.
    public func removeRecovery(projectID: UUID) {
        removeTree(folder(projectID))
    }

    private func removeTree(_ dir: String) {
        for e in (try? fs.contents(ofDirectory: dir)) ?? [] {
            let p = PathUtil.join(dir, e.name)
            if e.isDirectory { removeTree(p) } else { try? fs.remove(p) }
        }
        try? fs.remove(dir)
    }

    // MARK: Autosave

    func folder(_ id: UUID) -> String { PathUtil.join(recoveryFolder, id.uuidString) }

    /// Writes the recovery copy. Callers run this off the main thread on a value copy, so editing is never blocked.
    public func autosave(_ project: Project, savedPath: String?) throws {
        let dir = folder(project.id)
        if !fs.exists(dir) { try fs.createDirectory(dir) } // creates the recovery folder too
        let data = try ProjectCodec.encode(project)
        try fs.writeAtomically(data, to: PathUtil.join(dir, "autosave.json"))
        let meta = Meta(projectID: project.id, name: project.name, savedPath: savedPath, autosavedAt: now())
        try fs.writeAtomically(try JSONEncoder().encode(meta), to: PathUtil.join(dir, "meta.json"))
    }

    public func clearAutosave(projectID: UUID) {
        let dir = folder(projectID)
        try? fs.remove(PathUtil.join(dir, "autosave.json"))
        try? fs.remove(PathUtil.join(dir, "meta.json"))
    }

    /// Projects whose crash copy is newer than the file the user saved (or that were never saved).
    public func recoverable() -> [RecoveryCandidate] {
        guard let dirs = try? fs.contents(ofDirectory: recoveryFolder) else { return [] }
        var out: [RecoveryCandidate] = []
        for d in dirs where d.isDirectory {
            let dir = PathUtil.join(recoveryFolder, d.name)
            guard let data = try? fs.read(PathUtil.join(dir, "meta.json")), let meta = try? JSONDecoder().decode(Meta.self, from: data),
                  fs.exists(PathUtil.join(dir, "autosave.json")) else { continue }
            if let saved = meta.savedPath, let fp = try? fs.fingerprint(saved), fp.modified >= meta.autosavedAt { continue }
            out.append(RecoveryCandidate(projectID: meta.projectID, name: meta.name, autosavedAt: meta.autosavedAt,
                                         savedPath: meta.savedPath, autosavePath: PathUtil.join(dir, "autosave.json")))
        }
        return out.sorted { $0.autosavedAt > $1.autosavedAt }
    }

    public func loadAutosave(_ c: RecoveryCandidate) throws -> Project { try load(path: c.autosavePath) }

    // MARK: Restore points

    public struct Snapshot: Equatable, Sendable { public var path: String; public var date: Date; public var size: Int64 }

    /// Keeps a restore point (at most one per `minInterval`), so the user can go back further than the last autosave.
    public func takeSnapshot(_ project: Project, minInterval: TimeInterval = 300) throws {
        let dir = PathUtil.join(folder(project.id), "snapshots")
        if !fs.exists(folder(project.id)) { try fs.createDirectory(folder(project.id)) }
        if !fs.exists(dir) { try fs.createDirectory(dir) }
        if let last = snapshots(projectID: project.id).first, now().timeIntervalSince(last.date) < minInterval { return }
        let stamp = String(Int(now().timeIntervalSince1970))
        try fs.writeAtomically(try ProjectCodec.encode(project), to: PathUtil.join(dir, "\(stamp).json"))
        pruneSnapshots(projectID: project.id, maxCount: 50, maxBytes: 50_000_000)
    }

    /// Newest first.
    public func snapshots(projectID: UUID) -> [Snapshot] {
        let dir = PathUtil.join(folder(projectID), "snapshots")
        guard let entries = try? fs.contents(ofDirectory: dir) else { return [] }
        return entries.filter { $0.name.hasSuffix(".json") }
            .map { Snapshot(path: PathUtil.join(dir, $0.name), date: Date(timeIntervalSince1970: Double(PathUtil.stem(of: $0.name)) ?? 0), size: $0.size) }
            .sorted { $0.date > $1.date }
    }

    /// Drops the oldest restore points beyond a count or total size (design section 10: clean history by size).
    @discardableResult
    public func pruneSnapshots(projectID: UUID, maxCount: Int, maxBytes: Int64) -> Int {
        var removed = 0
        var kept = snapshots(projectID: projectID)
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        while kept.count > 1, kept.count > maxCount || total > maxBytes {
            let oldest = kept.removeLast()
            total -= oldest.size
            if (try? fs.remove(oldest.path)) != nil { removed += 1 }
        }
        return removed
    }

    /// Total size of everything kept for recovery (shown in Settings next to "Clear").
    public func recoveryBytes() -> Int64 {
        var total: Int64 = 0
        func walk(_ dir: String) {
            for e in (try? fs.contents(ofDirectory: dir)) ?? [] {
                if e.isDirectory { walk(PathUtil.join(dir, e.name)) } else { total += e.size }
            }
        }
        walk(recoveryFolder)
        return total
    }
}

/// When to autosave. Pure timing logic so it is testable without a clock or a run loop.
///
/// Saves `idle` seconds after the last change (so it lands well inside the design's 5-second limit), and at
/// least every `maxStaleness` seconds while the user keeps working.
public struct AutosaveSchedule {
    public var idle: TimeInterval
    public var maxStaleness: TimeInterval
    private var firstDirty: Date?
    private var lastChange: Date?

    public init(idle: TimeInterval = 2, maxStaleness: TimeInterval = 15) {
        self.idle = idle; self.maxStaleness = maxStaleness
    }

    public var isDirty: Bool { firstDirty != nil }

    public mutating func noteChange(at now: Date) {
        if firstDirty == nil { firstDirty = now }
        lastChange = now
    }

    /// The moment the next autosave should run, or nil if nothing changed.
    public var dueAt: Date? {
        guard let first = firstDirty, let last = lastChange else { return nil }
        return min(last.addingTimeInterval(idle), first.addingTimeInterval(maxStaleness))
    }

    public func isDue(at now: Date) -> Bool { dueAt.map { now >= $0 } ?? false }

    public mutating func didSave() { firstDirty = nil; lastChange = nil }
}
