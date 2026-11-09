import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Localised string: the key is the English text; Vietnamese lives in Resources/vi.lproj/Localizable.strings.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }

final class DefaultsStore: PreferenceStoring {
    private let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }
    func object(forKey key: String) -> Any? { d.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) { d.set(value, forKey: key) }
}

/// Everything the app shares: where data lives and the services built on it.
@MainActor
final class AppEnvironment {
    static var shared: AppEnvironment!

    let fs = RealFileSystem()
    let support: URL
    let prefs: AppPreferences
    let saver: SafeSaver
    let projectStore: ProjectStore
    let playlistStore: PlaylistStore
    let positions: PositionStore
    let exports: ExportController
    let isSandbox: Bool

    /// `sandbox`: a throwaway data folder (used by `--sandbox <dir>` for testing), so nothing touches the user's real settings.
    init(sandbox: URL?) {
        isSandbox = sandbox != nil
        let base = sandbox ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPlayer", isDirectory: true)
        support = base
        if sandbox == nil { LegacyMigration.run(newSupport: base) }
        Stabilizer.cacheFolder = base.appendingPathComponent("Stabilization", isDirectory: true)
        NoiseReducer.cacheFolder = base.appendingPathComponent("Denoised", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        prefs = AppPreferences(store: sandbox == nil ? DefaultsStore() : MemoryStore())
        // Development aid (sandbox only): start with a given layout, as if it had been chosen in an earlier run.
        if sandbox != nil, let l = ProcessInfo.processInfo.environment["MACPLAYER_LAYOUT"].flatMap(PlaylistLayout.init(rawValue:)) { prefs.playlistLayout = l }
        if sandbox != nil, let v = ProcessInfo.processInfo.environment["MACPLAYER_PREVIEW_SCALE"].flatMap(Double.init) { prefs.previewScale = v }
        if sandbox != nil, let t = ProcessInfo.processInfo.environment["MACPLAYER_TREE_FILES"].flatMap(TreeFiles.init(rawValue:)) { prefs.treeFiles = t }
        saver = SafeSaver(fs: fs, journalFolder: base.appendingPathComponent("Journals").path)
        projectStore = ProjectStore(fs: fs, recoveryFolder: base.appendingPathComponent("Recovery").path)
        playlistStore = PlaylistStore(fs: fs, folder: base.appendingPathComponent("Playlists").path)
        positions = PositionStore(fs: fs, path: base.appendingPathComponent("positions.json").path)
        exports = ExportController(fs: fs, saver: saver, queuePath: base.appendingPathComponent("queue.json").path, prefs: prefs)
    }

    /// Set by the self-test so its stand-in window can reach the playlist model.
    weak var playlistsForSelfTest: PlaylistModel?

    var backupsFolderDefault: String { support.appendingPathComponent("Backups").path }
}

final class MemoryStore: PreferenceStoring {
    private var d: [String: Any] = [:]
    func object(forKey key: String) -> Any? { d[key] }
    func set(_ value: Any?, forKey key: String) { d[key] = value }
}

enum Bookmarks {
    static func make(_ url: URL) -> Data? { try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    /// The file's current location if it was moved or renamed since the bookmark was made.
    static func resolve(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// Whether the drive a path sits on is connected right now (an unplugged disk leaves an empty folder behind in /Volumes at times).
enum Drives {
    static func isConnected(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return true }        // the start-up disk and its folders
        let root = URL(fileURLWithPath: "/Volumes/\(parts[1])").resolvingSymlinksInPath().path
        if root == "/" { return true }                                            // "/Volumes/Macintosh HD" points at the start-up disk
        let mounted = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map { $0.resolvingSymlinksInPath().path }
        return mounted.contains(root)
    }
}

/// Export failure text in the person's language. The lower layers write English; this recognises the shapes they use.
enum ErrorText {
    static func localized(_ raw: String) -> String {
        var text = raw, head = "", tail = ""
        let untouched = " The original is untouched."
        if text.hasSuffix(untouched) { text.removeLast(untouched.count); tail = " " + L("The original is untouched.") }
        if text.hasPrefix("Export failed: ") { text.removeFirst("Export failed: ".count); head = L("Export failed: ") }
        if let d = SourceDamage.parse(text) {
            text = LF("The video file is damaged: its picture or sound cannot be decoded after %1$@ (the file says it is %2$@ long). It may be an incomplete download. A fast cut copies the data as it is; an exact export has to decode everything, so end it at %1$@ to export the part that can be read.", d.readable, d.declared)
        } else if head.isEmpty && tail.isEmpty { return raw }
        return head + text + tail
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func duration(_ t: MediaTime) -> String {
        let s = Int(t.seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
