import Foundation

/// Where settings are kept: `UserDefaults` in the app, a dictionary in tests.
public protocol PreferenceStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

public enum ResumeBehavior: String, CaseIterable, Sendable { case ask, always, never }

/// The user's settings, with their defaults (design sections 4, 6, 13, 17).
public final class AppPreferences {
    let store: PreferenceStoring
    public init(store: PreferenceStoring) { self.store = store }

    private func bool(_ k: String, _ d: Bool) -> Bool { store.object(forKey: k) as? Bool ?? d }
    private func double(_ k: String, _ d: Double) -> Double { store.object(forKey: k) as? Double ?? d }
    private func string(_ k: String) -> String? { store.object(forKey: k) as? String }

    /// Arrow-key skip distances in seconds.
    public var skipSeconds: Double { get { double("skipSeconds", 5) } set { store.set(max(0.1, newValue), forKey: "skipSeconds") } }
    public var bigSkipSeconds: Double { get { double("bigSkipSeconds", 30) } set { store.set(max(0.1, newValue), forKey: "bigSkipSeconds") } }

    /// "Remember where I stopped" for each file. Off clears nothing by itself; "Clear history" does.
    public var rememberPositions: Bool { get { bool("rememberPositions", true) } set { store.set(newValue, forKey: "rememberPositions") } }
    public var resumeBehavior: ResumeBehavior {
        get { string("resumeBehavior").flatMap(ResumeBehavior.init) ?? .ask }
        set { store.set(newValue.rawValue, forKey: "resumeBehavior") }
    }

    /// What the window looked like when the app was last closed, so opening it again picks up where the person was.
    public var lastPlaylistID: UUID? {
        get { string("lastPlaylistID").flatMap(UUID.init) }
        set { store.set(newValue?.uuidString, forKey: "lastPlaylistID") }
    }
    /// The left panel shows "Recent" instead of the playlists.
    public var sidebarShowsRecent: Bool { get { bool("sidebarShowsRecent", false) } set { store.set(newValue, forKey: "sidebarShowsRecent") } }
    /// The person's own choice for the two side panels (a panel with nothing to show is closed whatever this says).
    public var playlistPanelHidden: Bool { get { bool("playlistPanelHidden", false) } set { store.set(newValue, forKey: "playlistPanelHidden") } }
    public var toolsPanelHidden: Bool { get { bool("toolsPanelHidden", false) } set { store.set(newValue, forKey: "toolsPanelHidden") } }

    /// Playlists as a list (default) or as a grid of pictures.
    public var playlistLayout: PlaylistLayout {
        get { string("playlistLayout").flatMap(PlaylistLayout.init) ?? .list }
        set { store.set(newValue.rawValue, forKey: "playlistLayout") }
    }

    /// How big the previews in the playlist are (see `PreviewSize`).
    public var previewScale: Double {
        get { PreviewSize.clamp(double("previewScale", PreviewSize.standard)) }
        set { store.set(PreviewSize.clamp(newValue), forKey: "previewScale") }
    }

    /// In the folder tree: the files of a folder as a list (default) or as a grid of pictures.
    public var treeFiles: TreeFiles {
        get { string("treeFiles").flatMap(TreeFiles.init) ?? .list }
        set { store.set(newValue.rawValue, forKey: "treeFiles") }
    }

    /// The folder the last project was saved in: the "where to save" question starts there (it is always asked).
    public var lastProjectFolder: String? { get { string("lastProjectFolder") } set { store.set(newValue, forKey: "lastProjectFolder") } }
    /// The folder the library's Import button last opened (0.9).
    public var lastMediaFolder: String? { get { string("lastMediaFolder") } set { store.set(newValue, forKey: "lastMediaFolder") } }
    /// How the list of projects is filtered and sorted.
    public var projectFilter: ProjectFilter {
        get { string("projectFilter").flatMap(ProjectFilter.init) ?? .all }
        set { store.set(newValue.rawValue, forKey: "projectFilter") }
    }
    public var projectSort: ProjectSort {
        get { string("projectSort").flatMap(ProjectSort.init) ?? .modified }
        set { store.set(newValue.rawValue, forKey: "projectSort") }
    }
    /// The projects already known from before the list of projects existed were looked for once.
    public var projectsImported: Bool { get { bool("projectsImported", false) } set { store.set(newValue, forKey: "projectsImported") } }
    public var copySuffix: String { get { string("copySuffix") ?? "-edited" } set { store.set(newValue, forKey: "copySuffix") } }

    public var autosaveEnabled: Bool { get { bool("autosaveEnabled", true) } set { store.set(newValue, forKey: "autosaveEnabled") } }
    public var maxSnapshotMegabytes: Double { get { double("maxSnapshotMB", 200) } set { store.set(newValue, forKey: "maxSnapshotMB") } }

    public var maxConcurrentExports: Int {
        get { max(1, min(4, Int(double("maxConcurrentExports", 1)))) }
        set { store.set(Double(max(1, min(4, newValue))), forKey: "maxConcurrentExports") }
    }

    /// Everything that leaves the Mac is off until the user turns it on (design section 17).
    public var telemetryEnabled: Bool { get { bool("telemetryEnabled", false) } set { store.set(newValue, forKey: "telemetryEnabled") } }

    public var keepWindowOnTop: Bool { get { bool("keepWindowOnTop", false) } set { store.set(newValue, forKey: "keepWindowOnTop") } }
    public var preserveVoicePitch: Bool { get { bool("preserveVoicePitch", true) } set { store.set(newValue, forKey: "preserveVoicePitch") } }
    /// How long a photo stays on screen when a playlist plays on by itself (seconds).
    public var photoSlideSeconds: Double { get { double("photoSlideSeconds", 5) } set { store.set(min(60, max(1, newValue)), forKey: "photoSlideSeconds") } }
    public var lastExportFolder: String? { get { string("lastExportFolder") } set { store.set(newValue, forKey: "lastExportFolder") } }
    /// Web links opened lately (0.15), newest first; kept on this Mac only and cleared with one button.
    public var recentLinks: [String] { get { store.object(forKey: "recentLinks") as? [String] ?? [] } set { store.set(Array(newValue.prefix(RecentLinks.limit)), forKey: "recentLinks") } }
}

/// Where the viewer stopped in each file (design section 4). Capped, can be switched off and cleared.
public final class PositionStore {
    struct Entry: Codable, Equatable { var key: String; var seconds: Double; var date: Date }

    private let fs: FileSystem
    private let path: String
    private var entries: [Entry]
    private let limit: Int

    public init(fs: FileSystem, path: String, limit: Int = 500) {
        self.fs = fs; self.path = path; self.limit = limit
        entries = ((try? fs.read(path)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
    }

    /// Path plus size: the same file moved or replaced by a different one does not resume at a wrong place.
    public static func key(path: String, size: Int64) -> String { "\((path as NSString).standardizingPath)|\(size)" }

    public func position(for key: String) -> Double? { entries.first { $0.key == key }?.seconds }

    public func remember(_ key: String, seconds: Double, duration: Double?, at: Date = Date()) {
        entries.removeAll { $0.key == key }
        // Not worth resuming at the very start or in the last seconds.
        if seconds < 3 { return }
        if let d = duration, seconds > d - 5 { return }
        entries.append(Entry(key: key, seconds: seconds, date: at))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public func flush() { try? fs.writeAtomically((try? JSONEncoder().encode(entries)) ?? Data("[]".utf8), to: path) }

    public func clear() { entries.removeAll(); flush() }
    public var count: Int { entries.count }
}
