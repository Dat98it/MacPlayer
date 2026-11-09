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
    nonisolated(unsafe) public static var migrations: [Int: (inout [String: Any]) throws -> Void] = [
        1: { obj in if obj["overlayClips"] == nil { obj["overlayClips"] = [Any]() } },
    ]

    public static func encode(_ p: Project) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates keep their full precision (default strategy): file fingerprints are compared exactly.
        return try enc.encode(p)
    }

    public static func decode(_ data: Data) throws -> Project {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ProjectError.corrupted("not a JSON document") }
        var version = obj["schemaVersion"] as? Int ?? 0
        guard version >= 1 else { throw ProjectError.corrupted("missing schema version") }
        if version > Project.currentSchema { throw ProjectError.newerVersion(version) }
        while version < Project.currentSchema {
            guard let step = migrations[version] else { throw ProjectError.corrupted("no migration from format \(version)") }
            try step(&obj)
            version += 1
            obj["schemaVersion"] = version
        }
        do {
            let migrated = try JSONSerialization.data(withJSONObject: obj)
            return try JSONDecoder().decode(Project.self, from: migrated)
        } catch {
            throw ProjectError.corrupted("\(error)")
        }
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

/// Saving projects, autosaving them for crash recovery, and keeping restore points.
/// None of this ever touches a video file: it only writes project state (design section 6).
public final class ProjectStore {
    struct Meta: Codable, Equatable { var projectID: UUID; var name: String; var savedPath: String?; var autosavedAt: Date }

    private let fs: FileSystem
    private let recoveryFolder: String
    private let now: () -> Date

    public init(fs: FileSystem, recoveryFolder: String, now: @escaping () -> Date = Date.init) {
        self.fs = fs; self.recoveryFolder = recoveryFolder; self.now = now
    }

    // MARK: Explicit save / open

    public func save(_ project: Project, to path: String) throws {
        var p = project
        p.modified = now()
        try fs.writeAtomically(try ProjectCodec.encode(p), to: path)
        // The saved file is now the truth; the crash copy is no longer needed.
        clearAutosave(projectID: project.id)
    }

    public func load(path: String) throws -> Project {
        do { return try ProjectCodec.decode(try fs.read(path)) }
        catch let e as ProjectError { throw e }
        catch { throw ProjectError.corrupted("\(error)") }
    }

    // MARK: Autosave

    private func folder(_ id: UUID) -> String { PathUtil.join(recoveryFolder, id.uuidString) }

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
