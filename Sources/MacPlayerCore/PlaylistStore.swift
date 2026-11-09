import Foundation

/// Playlists on disk: one JSON file per playlist, so a damaged file loses one list, not all of them.
/// Deleting a playlist removes only its own file. Video files are never touched.
public final class PlaylistStore {
    private let fs: FileSystem
    private let folder: String

    public init(fs: FileSystem, folder: String) { self.fs = fs; self.folder = folder }

    private func path(_ id: UUID) -> String { PathUtil.join(folder, "\(id.uuidString).playlist.json") }

    public func save(_ p: Playlist) throws {
        if !fs.exists(folder) { try fs.createDirectory(folder) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.writeAtomically(try enc.encode(p), to: path(p.id))
    }

    public struct LoadResult { public var playlists: [Playlist]; public var damaged: [String] }

    /// Oldest first. Unreadable files are reported and left where they are (never deleted).
    public func loadAll() -> LoadResult {
        guard let entries = try? fs.contents(ofDirectory: folder) else { return LoadResult(playlists: [], damaged: []) }
        var lists: [Playlist] = [], bad: [String] = []
        for e in entries where e.name.hasSuffix(".playlist.json") {
            let p = PathUtil.join(folder, e.name)
            if let d = try? fs.read(p), let pl = try? JSONDecoder().decode(Playlist.self, from: d) { lists.append(pl) } else { bad.append(p) }
        }
        return LoadResult(playlists: lists.sorted { $0.created < $1.created }, damaged: bad)
    }

    public func delete(_ id: UUID) { try? fs.remove(path(id)) }
}
