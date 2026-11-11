import Foundation

/// What a file brought into a project's library is: a video, a picture or a sound.
public enum BinKind: String, Codable, Sendable { case video, photo, audio }

/// A file brought into a video project's library ("Media" panel), ready to be dragged onto the timeline. Bringing a file in only remembers
/// where it is: the file is never copied, moved or changed, and taking it out of the library never touches it.
public struct BinItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var bookmark: Data?
    public var kind: BinKind
    public var added: Date

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, kind: BinKind, added: Date = Date()) {
        self.id = id; self.path = path; self.bookmark = bookmark; self.kind = kind; self.added = added
    }

    public var name: String { (PathUtil.fileName(of: path) as NSString).deletingPathExtension }

    /// The same id for the same file every time (for the files a project uses but never brought into its library). A new id at every look
    /// made the library's tiles be made again at every redraw: they flickered while the video played (0.14).
    public static func stableID(for path: String) -> UUID {
        let key = PathUtil.key(path)
        var a: UInt64 = 0xcbf29ce484222325, b: UInt64 = 0x84222325cbf29ce4
        for byte in key.utf8 { a = (a ^ UInt64(byte)) &* 0x100000001b3; b = (b ^ UInt64(byte)) &* 0x100000001b3 &+ 0x9e3779b97f4a7c15 }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((a >> (8 * UInt64(i))) & 0xff); bytes[8 + i] = UInt8((b >> (8 * UInt64(i))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80     // a name-based UUID shape
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public enum AudioFiles {
    public static let candidateExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "m4b", "mp2", "ac3"]
    public static func isCandidate(_ path: String) -> Bool { candidateExtensions.contains(PathUtil.ext(of: path).lowercased()) }
}

public enum MediaBin {
    /// What kind of library item a file would be; nil for files the library does not take (projects, documents…).
    public static func kind(of path: String) -> BinKind? {
        if AudioFiles.isCandidate(path) { return .audio }
        switch MediaFiles.kind(of: path) {
        case .video?: return .video
        case .image?: return .photo
        case nil: return nil
        }
    }

    /// Adds the files the library does not have yet (the same file twice is kept once), in the order given. Returns the new items.
    @discardableResult
    public static func add(_ paths: [String], to items: inout [BinItem], bookmark: (String) -> Data? = { _ in nil }, now: Date = Date()) -> [BinItem] {
        var added: [BinItem] = []
        for p in paths {
            guard let k = kind(of: p) else { continue }
            if items.contains(where: { PathUtil.same($0.path, p) }) || added.contains(where: { PathUtil.same($0.path, p) }) { continue }
            added.append(BinItem(path: p, bookmark: bookmark(p), kind: k, added: now))
        }
        items += added
        return added
    }
}

public extension Project {
    /// The files in this project's library. Older projects have none in their file: they show what their timeline, layers and sounds use.
    var mediaBin: [BinItem] {
        get { binStore ?? [] }
        set { binStore = newValue.isEmpty ? nil : newValue }
    }

    /// Every file the project already uses, as library items (for older projects, and so nothing on the timeline is missing from the library).
    var usedMedia: [BinItem] {
        var items: [BinItem] = []
        MediaBin.add(sources.map(\.mediaPath), to: &items, now: created)
        for c in overlayClips { if case .image(let path, _) = c.kind { MediaBin.add([path], to: &items, now: created) } }
        MediaBin.add(soundClips.map(\.path), to: &items, now: created)
        for i in items.indices { items[i].id = BinItem.stableID(for: items[i].path) }
        return items
    }

    /// The library as shown: what was brought in, then anything used but not brought in (older projects).
    var libraryItems: [BinItem] {
        var items = mediaBin
        for u in usedMedia where !items.contains(where: { PathUtil.same($0.path, u.path) }) { items.append(u) }
        return items
    }

    /// True when the file is used on the timeline, in a layer or as a sound.
    func uses(path: String) -> Bool {
        if sources.contains(where: { PathUtil.same($0.mediaPath, path) }) {
            let ids = Set(sources.filter { PathUtil.same($0.mediaPath, path) }.map(\.id))
            if timeline.contains(where: { ids.contains($0.sourceID) }) || overlayClips.contains(where: { $0.sourceID.map(ids.contains) ?? false }) { return true }
        }
        if overlayClips.contains(where: { if case .image(let p, _) = $0.kind { return PathUtil.same(p, path) }; return false }) { return true }
        return soundClips.contains { PathUtil.same($0.path, path) }
    }
}
