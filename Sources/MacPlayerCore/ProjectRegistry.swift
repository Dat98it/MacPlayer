import Foundation

/// One project in the list of projects. The project file itself lives wherever the person chose to save it; this entry only
/// remembers where that is and what to show for it.
public struct ProjectEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        /// The file is not at its place and could not be found again.
        case missing
        /// The disk the file is on is not connected right now.
        case driveOffline
        /// The file was moved to the Trash outside MacPlayer.
        case inTrash
        /// The file cannot be read as a project (damaged).
        case unreadable
        /// Saved by a newer MacPlayer: shown, but not opened.
        case newerVersion
    }

    public var id: UUID
    public var projectID: UUID
    public var path: String
    /// Made by the app (opaque here): finds the file again after it was moved or renamed outside MacPlayer.
    public var bookmark: Data?
    public var name: String
    public var kind: ProjectKind
    public var created: Date
    public var modified: Date
    public var lastOpened: Date?
    /// What the card shows under the name: number of clips and length, or the photo's size.
    public var clipCount: Int
    public var seconds: Double
    public var photoWidth: Int?
    public var photoHeight: Int?
    /// The media the project uses (to count the missing ones without opening it).
    public var sourcePaths: [String]
    public var missingSources: Int
    /// Written in an older format: it is upgraded the first time it is opened.
    public var olderFormat: Bool
    public var status: Status
    public var fileFingerprint: FileFingerprint?

    public init(id: UUID = UUID(), projectID: UUID, path: String, bookmark: Data? = nil, name: String, kind: ProjectKind, created: Date, modified: Date,
                lastOpened: Date? = nil, clipCount: Int = 0, seconds: Double = 0, photoWidth: Int? = nil, photoHeight: Int? = nil,
                sourcePaths: [String] = [], missingSources: Int = 0, olderFormat: Bool = false, status: Status = .ok, fileFingerprint: FileFingerprint? = nil) {
        self.id = id; self.projectID = projectID; self.path = path; self.bookmark = bookmark; self.name = name; self.kind = kind
        self.created = created; self.modified = modified; self.lastOpened = lastOpened; self.clipCount = clipCount; self.seconds = seconds
        self.photoWidth = photoWidth; self.photoHeight = photoHeight; self.sourcePaths = sourcePaths; self.missingSources = missingSources
        self.olderFormat = olderFormat; self.status = status; self.fileFingerprint = fileFingerprint
    }

    /// The details of a project as read from its file.
    public mutating func describe(_ p: Project, fileSchema: Int, fs: FileSystem) {
        projectID = p.id
        kind = p.kind
        name = PathUtil.stem(of: path)
        created = p.created
        modified = p.modified
        clipCount = p.timeline.count
        seconds = p.timelineDuration.seconds
        let photo = p.kind == .photo ? p.sources.first?.info?.primaryVideo : nil
        photoWidth = photo?.width; photoHeight = photo?.height
        sourcePaths = Array(p.sources.map(\.path).prefix(40))
        missingSources = sourcePaths.filter { !fs.exists($0) }.count
        olderFormat = fileSchema < Project.currentSchema
    }
}

public enum ProjectSort: String, CaseIterable, Codable, Sendable { case modified, name, created }
public enum ProjectFilter: String, CaseIterable, Codable, Sendable { case all, video, photo }

/// The list of every project the person made or opened, kept in MacPlayer's own data folder (registry.json).
/// Pure: the file system and the way bookmarks and drives are looked at are given to it, so every case is tested.
public final class ProjectRegistry {
    public struct Environment {
        /// Where a bookmark points now (nil when it cannot be resolved).
        public var resolveBookmark: (Data?) -> String?
        /// Makes a bookmark for a path.
        public var makeBookmark: (String) -> Data?
        /// Whether the disk a path is on is connected.
        public var driveConnected: (String) -> Bool
        /// Whether a path is inside a Trash folder.
        public var isInTrash: (String) -> Bool
        public init(resolveBookmark: @escaping (Data?) -> String?, makeBookmark: @escaping (String) -> Data?,
                    driveConnected: @escaping (String) -> Bool, isInTrash: @escaping (String) -> Bool) {
            self.resolveBookmark = resolveBookmark; self.makeBookmark = makeBookmark; self.driveConnected = driveConnected; self.isInTrash = isInTrash
        }
        public static let plain = Environment(resolveBookmark: { _ in nil }, makeBookmark: { _ in nil }, driveConnected: { _ in true },
                                              isInTrash: { $0.contains("/.Trash/") })
    }

    private struct Document: Codable { var version = 1; var entries: [ProjectEntry] = [] }

    public private(set) var entries: [ProjectEntry] = []
    private let fs: FileSystem
    private let path: String
    private let env: Environment
    private let now: () -> Date

    public init(fs: FileSystem, path: String, environment: Environment = .plain, now: @escaping () -> Date = Date.init) {
        self.fs = fs; self.path = path; self.env = environment; self.now = now
        if let data = try? fs.read(path), let doc = try? JSONDecoder().decode(Document.self, from: data) { entries = doc.entries }
    }

    public func save() throws {
        let dir = PathUtil.directory(of: path)
        if !fs.exists(dir) { try fs.createDirectory(dir) }
        try fs.writeAtomically(try JSONEncoder().encode(Document(entries: entries)), to: path)
    }

    private static func key(_ p: String) -> String { PathUtil.key(p) }

    public func entry(forPath p: String) -> ProjectEntry? { entries.first { Self.key($0.path) == Self.key(p) } }
    public func entry(id: UUID) -> ProjectEntry? { entries.first { $0.id == id } }

    /// Adds the project file (or refreshes its entry when it is already listed). Returns the entry; nil when the file is not a project.
    @discardableResult
    public func register(path p: String, opened: Bool = false) -> ProjectEntry? {
        guard ProjectFile.isProject(path: p) else { return nil }
        var e = entry(forPath: p) ?? ProjectEntry(projectID: UUID(), path: p, name: PathUtil.stem(of: p), kind: .video, created: now(), modified: now())
        e.path = p
        if e.bookmark == nil || entry(forPath: p) == nil { e.bookmark = env.makeBookmark(p) }
        read(&e)
        if opened { e.lastOpened = now() }
        upsert(e)
        return e
    }

    /// Reads the file of an entry and updates what is shown. Never writes the project file.
    private func read(_ e: inout ProjectEntry) {
        guard fs.exists(e.path) else { e.status = .missing; return }
        do {
            let data = try fs.read(e.path)
            let (p, schema) = try ProjectCodec.decodeDetailed(data)
            e.describe(p, fileSchema: schema, fs: fs)
            e.status = .ok
            e.fileFingerprint = try? fs.fingerprint(e.path)
        } catch ProjectError.newerVersion {
            e.status = .newerVersion
        } catch {
            e.status = .unreadable
        }
    }

    private func upsert(_ e: ProjectEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id || Self.key($0.path) == Self.key(e.path) }) { entries[i] = e } else { entries.append(e) }
    }

    public func update(_ e: ProjectEntry) { upsert(e) }

    /// Looks at every entry again: moved files are followed through their bookmark, files on a disk that is not connected are not
    /// called missing, files moved to the Trash are marked. Entries are never dropped here.
    public func refresh() {
        for i in entries.indices {
            var e = entries[i]
            if fs.exists(e.path) {
                if let fp = try? fs.fingerprint(e.path), fp == e.fileFingerprint, e.status == .ok {
                    e.missingSources = e.sourcePaths.filter { !fs.exists($0) }.count
                } else { read(&e) }
            } else if !env.driveConnected(e.path) {
                e.status = .driveOffline
            } else if let moved = env.resolveBookmark(e.bookmark), moved != e.path, fs.exists(moved) {
                if env.isInTrash(moved) { e.status = .inTrash; e.path = moved }
                else { e.path = moved; e.bookmark = env.makeBookmark(moved); read(&e) }
            } else {
                e.status = .missing
            }
            entries[i] = e
        }
    }

    /// The project file was renamed or moved by MacPlayer.
    public func moved(from old: String, to new: String) {
        guard var e = entry(forPath: old) else { return }
        e.path = new
        e.name = PathUtil.stem(of: new)
        e.bookmark = env.makeBookmark(new)
        e.fileFingerprint = try? fs.fingerprint(new)
        if e.status != .ok { read(&e) }
        upsert(e)
    }

    /// Takes an entry off the list. The file is not touched.
    public func remove(id: UUID) { entries.removeAll { $0.id == id } }

    public func remove(path p: String) { entries.removeAll { Self.key($0.path) == Self.key(p) } }

    /// After the project was saved: what the card shows follows the file.
    public func noteSaved(_ p: Project, at filePath: String, fingerprint: FileFingerprint?) {
        guard var e = entry(forPath: filePath) else { return }
        e.describe(p, fileSchema: Project.currentSchema, fs: fs)
        e.fileFingerprint = fingerprint
        e.status = .ok
        upsert(e)
    }

    /// What the list shows: entries in the Trash are left out; filter and sort as chosen, search by name.
    public func visible(filter: ProjectFilter = .all, sort: ProjectSort = .modified, query: String = "") -> [ProjectEntry] {
        func fold(_ t: String) -> String {
            // "đ" is a letter of its own, not a "d" with a mark: Vietnamese typists still search for it as "d".
            t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "đ", with: "d")
        }
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        let list = entries.filter { e in
            guard e.status != .inTrash else { return false }
            switch filter { case .all: break; case .video: if e.kind != .video { return false }; case .photo: if e.kind != .photo { return false } }
            return q.isEmpty || fold(e.name).contains(q)
        }
        switch sort {
        case .modified: return list.sorted { ($0.modified, $0.name) > ($1.modified, $1.name) }
        case .created: return list.sorted { $0.created > $1.created }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public var inTrashCount: Int { entries.filter { $0.status == .inTrash }.count }

    /// Another project file already uses this project id (a copy made in Finder): the caller gives the copy a new id.
    public func idIsTaken(_ projectID: UUID, byOtherThan p: String) -> Bool {
        entries.contains { $0.projectID == projectID && Self.key($0.path) != Self.key(p) && fs.exists($0.path) }
    }
}
