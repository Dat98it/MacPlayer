import Foundation

/// The app used to be called MacVideo. The first time MacPlayer starts it brings that app's data over: playlists, remembered positions, recovery
/// copies, recordings and the settings (including the size and place of the window). It only copies: the old folder and settings are left where
/// they are, and nothing that MacPlayer already has is overwritten.
enum LegacyMigration {
    static let oldFolderName = "MacVideo"
    static let newFolderName = "MacPlayer"
    static let oldBundleID = "local.macvideo.app"
    static let doneKey = "migratedFromMacVideo"

    @discardableResult
    static func run(newSupport: URL, defaults: UserDefaults = .standard, oldBundleID: String = LegacyMigration.oldBundleID, fileManager fm: FileManager = .default) -> (files: Int, settings: Int) {
        guard !defaults.bool(forKey: doneKey) else { return (0, 0) }
        var files = 0, settings = 0
        let old = newSupport.deletingLastPathComponent().appendingPathComponent(oldFolderName, isDirectory: true)
        if fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: newSupport, withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
                let target = newSupport.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                if (try? fm.copyItem(at: old.appendingPathComponent(name), to: target)) != nil { files += 1 }
            }
        }
        if let domain = defaults.persistentDomain(forName: oldBundleID) {
            for (key, value) in domain {
                // Settings the system keeps under a name made from the app's (the window's size and place, the panel widths) follow the new name.
                let newKey = key.replacingOccurrences(of: oldFolderName, with: newFolderName)
                if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey); settings += 1 }
            }
        }
        defaults.set(true, forKey: doneKey)
        return (files, settings)
    }
}
