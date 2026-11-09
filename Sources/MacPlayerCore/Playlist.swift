import Foundation

public enum PlayMode: String, Codable, CaseIterable, Sendable { case sequential, shuffle }
public enum RepeatMode: String, Codable, CaseIterable, Sendable { case off, one, all }

public enum PlaylistSort: String, Codable, CaseIterable, Sendable {
    /// "video 2" before "video 10".
    case naturalName, modified, duration, manual
    /// When the file was made, and how big it is.
    case created, size
    /// By the folder the file is in (a folder's own subfolders first), then by name: what the folder tree shows, top to bottom.
    case folder
}

/// How a playlist keeps its videos in order, remembered with the playlist. `manual` means the person arranged them by hand and nothing
/// moves them; any other key keeps the list sorted, also when videos are added or their lengths become known.
public struct PlaylistOrder: Codable, Equatable, Sendable {
    public var key: PlaylistSort
    public var descending: Bool
    public init(key: PlaylistSort, descending: Bool = false) { self.key = key; self.descending = descending }
    public static let manual = PlaylistOrder(key: .manual)
    public var isAutomatic: Bool { key != .manual }
}

public enum Availability: String, Codable, Sendable {
    case available, missing, unreadable, unsupported
    public var isPlayable: Bool { self == .available }
}

/// A reference to a video in a playlist. Its own id lets the same source appear twice on purpose.
public struct PlaylistItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Last known location. The bookmark (kept by the app, opaque here) is what survives moves and sandboxing.
    public var path: String
    public var bookmark: Data?
    public var title: String
    public var duration: MediaTime?
    public var modified: Date?
    /// When the file was created and how big it is (nil until read; older playlists do not have them).
    public var created: Date?
    public var fileSize: Int64?
    /// Where the item came from, so "Follow folder" knows which items it owns.
    public var folderSourceID: UUID?
    /// Last state seen. Runtime checks update it; it is shown as a badge and never deletes anything.
    public var availability: Availability

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, title: String? = nil, duration: MediaTime? = nil,
                modified: Date? = nil, created: Date? = nil, fileSize: Int64? = nil, folderSourceID: UUID? = nil, availability: Availability = .available) {
        self.created = created; self.fileSize = fileSize
        self.id = id; self.path = path; self.bookmark = bookmark
        self.title = title ?? PathUtil.stem(of: path)
        self.duration = duration; self.modified = modified; self.folderSourceID = folderSourceID; self.availability = availability
    }
}

/// A folder the user added with permission. Items from it can be refreshed or followed.
public struct PlaylistFolderSource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var bookmark: Data?
    public var includeSubfolders: Bool
    /// Off by default (design section 4.1): only on when the user turns it on.
    public var follow: Bool
    public var lastScan: Date?
    public var sort: PlaylistSort

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, includeSubfolders: Bool = false, follow: Bool = false,
                lastScan: Date? = nil, sort: PlaylistSort = .naturalName) {
        self.id = id; self.path = path; self.bookmark = bookmark; self.includeSubfolders = includeSubfolders
        self.follow = follow; self.lastScan = lastScan; self.sort = sort
    }
}

public struct Playlist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [PlaylistItem]
    public var playMode: PlayMode
    public var repeatMode: RepeatMode
    /// When off, playback stops after each video.
    public var autoAdvance: Bool
    public var currentItemID: UUID?
    public var resumePosition: MediaTime?
    public var folderSources: [PlaylistFolderSource]
    /// Videos the person took out of the list that a followed folder would otherwise bring back (standardised paths).
    public var excludedPaths: [String] = []
    /// The order the list keeps (see `PlaylistOrder`).
    public var order: PlaylistOrder = .manual
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), name: String, items: [PlaylistItem] = [], playMode: PlayMode = .sequential, repeatMode: RepeatMode = .off,
                autoAdvance: Bool = true, currentItemID: UUID? = nil, resumePosition: MediaTime? = nil,
                folderSources: [PlaylistFolderSource] = [], now: Date = Date()) {
        self.id = id; self.name = name; self.items = items; self.playMode = playMode; self.repeatMode = repeatMode
        self.autoAdvance = autoAdvance; self.currentItemID = currentItemID; self.resumePosition = resumePosition
        self.folderSources = folderSources; self.created = now; self.modified = now
    }

    public var count: Int { items.count }
    public var totalDuration: MediaTime { items.compactMap(\.duration).reduce(.zero, +) }
    public var unknownDurationCount: Int { items.filter { $0.duration == nil }.count }
}

extension Playlist {
    enum CodingKeys: String, CodingKey {
        case id, name, items, playMode, repeatMode, autoAdvance, currentItemID, resumePosition, folderSources, excludedPaths, order, created, modified
    }

    /// Playlist files written before `excludedPaths` existed have no such key: they decode with an empty list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        items = try c.decode([PlaylistItem].self, forKey: .items)
        playMode = try c.decode(PlayMode.self, forKey: .playMode)
        repeatMode = try c.decode(RepeatMode.self, forKey: .repeatMode)
        autoAdvance = try c.decode(Bool.self, forKey: .autoAdvance)
        currentItemID = try c.decodeIfPresent(UUID.self, forKey: .currentItemID)
        resumePosition = try c.decodeIfPresent(MediaTime.self, forKey: .resumePosition)
        folderSources = try c.decode([PlaylistFolderSource].self, forKey: .folderSources)
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        order = try c.decodeIfPresent(PlaylistOrder.self, forKey: .order) ?? .manual
        created = try c.decode(Date.self, forKey: .created)
        modified = try c.decode(Date.self, forKey: .modified)
    }
}

public struct AddReport: Equatable, Sendable {
    public var added: [UUID] = []
    public var duplicates: [String] = []
    public var unsupported: [String] = []
    public init() {}
}

public enum VideoFiles {
    /// Extensions treated as "might be a video" when scanning. Whether AVFoundation can really play one is
    /// decided by probing; this list only keeps obvious non-video files out.
    public static let candidateExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "m2ts", "mts", "3gp", "3g2", "flv", "wmv", "mxf", "ogv",
    ]
    public static func isCandidate(_ path: String) -> Bool { candidateExtensions.contains(PathUtil.ext(of: path).lowercased()) }
}

/// Edits to a playlist's list of items. All of them only change references, never files.
public enum PlaylistEditor {
    static func key(_ path: String) -> String { (path as NSString).standardizingPath }

    /// Inserts `newItems` at `index` (nil = end). Items already in the list (same path) are skipped unless
    /// `allowDuplicates`. Anything that is not a candidate video is reported, not added.
    @discardableResult
    public static func add(_ newItems: [PlaylistItem], to p: inout Playlist, at index: Int? = nil, allowDuplicates: Bool = false) -> AddReport {
        var report = AddReport()
        var existing = Set(p.items.map { key($0.path) })
        var accepted: [PlaylistItem] = []
        for item in newItems {
            guard MediaFiles.isCandidate(item.path) else { report.unsupported.append(item.path); continue }
            if !allowDuplicates, existing.contains(key(item.path)) { report.duplicates.append(item.path); continue }
            existing.insert(key(item.path))
            accepted.append(item)
        }
        let at = max(0, min(index ?? p.items.count, p.items.count))
        p.items.insert(contentsOf: accepted, at: at)
        if !p.excludedPaths.isEmpty { let back = Set(accepted.map { key($0.path) }); p.excludedPaths.removeAll { back.contains($0) } }
        report.added = accepted.map(\.id)
        if !accepted.isEmpty { p.modified = Date() }
        return report
    }

    /// `remembering`: a video that the person took out of a followed folder is not brought back by the next refresh. Off for videos whose
    /// files are gone from the disk: if the file returns, it should be picked up again.
    public static func remove(_ ids: Set<UUID>, from p: inout Playlist, remembering: Bool = true) {
        // A video that came from a folder the list follows would be added again at the next refresh: remember that it was taken out.
        let sources = Set(p.folderSources.map(\.id))
        var seen = Set(p.excludedPaths)
        for it in p.items where remembering && ids.contains(it.id) {
            guard let s = it.folderSourceID, sources.contains(s), seen.insert(key(it.path)).inserted else { continue }
            p.excludedPaths.append(key(it.path))
        }
        p.items.removeAll { ids.contains($0.id) }
        p.modified = Date()
    }

    /// The videos that came from one folder source.
    public static func itemIDs(ofSource sourceID: UUID, in p: Playlist) -> Set<UUID> {
        Set(p.items.filter { $0.folderSourceID == sourceID }.map(\.id))
    }

    /// Stops using a folder: it is no longer followed or refreshed, and what was taken out of the list from it is forgotten.
    /// The videos already in the list stay unless the caller removes them (`itemIDs(ofSource:in:)`).
    public static func removeFolderSource(_ sourceID: UUID, from p: inout Playlist) {
        guard let src = p.folderSources.first(where: { $0.id == sourceID }) else { return }
        let prefix = key(src.path).hasSuffix("/") ? key(src.path) : key(src.path) + "/"
        p.folderSources.removeAll { $0.id == sourceID }
        p.excludedPaths.removeAll { $0.hasPrefix(prefix) }
        p.modified = Date()
    }

    /// Drag-and-drop reorder; `toOffset` follows the SwiftUI/NSTableView convention (insert before that index).
    public static func move(fromOffsets: IndexSet, toOffset: Int, in p: inout Playlist) {
        let moving = fromOffsets.sorted().map { p.items[$0] }
        for i in fromOffsets.sorted(by: >) { p.items.remove(at: i) }
        let dest = toOffset - fromOffsets.filter { $0 < toOffset }.count
        p.items.insert(contentsOf: moving, at: max(0, min(dest, p.items.count)))
        p.modified = Date()
    }

    /// The items in `order`. Ties keep their current order, a video without a date or length goes last in either direction.
    public static func sorted(_ items: [PlaylistItem], by order: PlaylistOrder) -> [PlaylistItem] {
        guard order.key != .manual else { return items }
        func number(_ i: PlaylistItem) -> Double? {
            switch order.key {
            case .modified: return i.modified?.timeIntervalSinceReferenceDate
            case .created: return i.created?.timeIntervalSinceReferenceDate
            case .size: return i.fileSize.map(Double.init)
            case .duration: return i.duration.map { $0.seconds }
            default: return nil
            }
        }
        func before(_ a: (offset: Int, element: PlaylistItem), _ b: (offset: Int, element: PlaylistItem)) -> Bool {
            if order.key == .folder {
                let f = FolderTree.compareFolders(PathUtil.directory(of: a.element.path), PathUtil.directory(of: b.element.path))
                if f != .orderedSame { return order.descending ? f == .orderedDescending : f == .orderedAscending }
                let r = NaturalSort.compare(a.element.title, b.element.title)
                if r != .orderedSame { return order.descending ? r == .orderedDescending : r == .orderedAscending }
                return a.offset < b.offset
            }
            if order.key == .naturalName {
                let r = NaturalSort.compare(a.element.title, b.element.title)
                if r != .orderedSame { return order.descending ? r == .orderedDescending : r == .orderedAscending }
                return a.offset < b.offset
            }
            switch (number(a.element), number(b.element)) {
            case let (x?, y?):
                if x != y { return order.descending ? x > y : x < y }
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): break
            }
            let r = NaturalSort.compare(a.element.title, b.element.title)
            return r == .orderedSame ? a.offset < b.offset : r == .orderedAscending
        }
        return items.enumerated().sorted(by: before).map(\.element)
    }

    public static func sorted(_ items: [PlaylistItem], by sort: PlaylistSort) -> [PlaylistItem] {
        sorted(items, by: PlaylistOrder(key: sort))
    }

    public static func duplicate(_ p: Playlist, newName: String) -> Playlist {
        var c = p
        c.id = UUID(); c.name = newName
        c.items = p.items.map { var i = $0; i.id = UUID(); return i }
        // Item ids changed, so the copy starts from the top instead of pointing at an id it does not have.
        c.currentItemID = nil; c.resumePosition = nil
        c.created = Date(); c.modified = c.created
        return c
    }

    /// Search by name; ignores case and accents so "bai giang" finds "Bài giảng".
    public static func search(_ items: [PlaylistItem], query: String) -> [PlaylistItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            || PathUtil.fileName(of: $0.path).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum NaturalSort {
    public static func less(_ a: String, _ b: String) -> Bool { compare(a, b) == .orderedAscending }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let r = a.compare(b, options: [.numeric, .caseInsensitive], range: nil, locale: Locale(identifier: "vi_VN"))
        if r != .orderedSame { return r }
        return a.compare(b) // deterministic tie-break
    }
}
