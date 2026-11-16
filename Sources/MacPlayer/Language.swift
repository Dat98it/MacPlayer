import AppKit
import Combine
import SwiftUI

/// The language of the app's own words (0.20.1): as the Mac is set, English, or Vietnamese — switched at once, without restarting.
/// Every caption goes through `L()`/`LF()`, which read the chosen language's strings; changing it rebuilds the menus and every window's
/// panels so all of them speak the new language.
enum AppLanguage: String, CaseIterable {
    case system, english = "en", vietnamese = "vi"

    static let key = "MacPlayerLanguage"

    static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); cache.reset() }
    }

    /// The strings used now: the chosen language's folder, or nil for the app's own choice from the Mac's languages. `L()` is called from
    /// background threads too (renderers, error texts): the cached bundle sits behind a lock (an unguarded one corrupted memory, 0.20.1).
    static var bundle: Bundle? { cache.bundle { load() } }
    private static let cache = BundleCache()

    private static func load() -> Bundle? {
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        guard lang != .system else { return nil }
        var b = Bundle.main.path(forResource: lang.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
        #if DEBUG
        // A debug build run from the build folder has no app bundle: the strings are read from the source folder.
        if b == nil {
            let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(lang.rawValue).lproj")
            b = Bundle(path: res.path)
        }
        #endif
        return b
    }

    /// The name of each choice, in its own language (so it can be found whatever the app is showing).
    var title: String {
        switch self {
        case .system: return L("Same as the Mac")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

func localized(_ key: String) -> String {
    if let b = AppLanguage.bundle { return b.localizedString(forKey: key, value: key, table: nil) }
    return NSLocalizedString(key, comment: "")
}

/// Tells open SwiftUI windows that the language changed; `LanguageRoot` rebuilds what it holds.
@MainActor
final class LanguageState: ObservableObject {
    static let shared = LanguageState()
    @Published private(set) var code = AppLanguage.current.rawValue

    func set(_ lang: AppLanguage) {
        guard lang != AppLanguage.current else { return }
        AppLanguage.current = lang
        code = lang.rawValue
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }
}

extension Notification.Name { static let appLanguageChanged = Notification.Name("MacPlayerAppLanguageChanged") }

/// Wraps a window's SwiftUI content so all of it is drawn again in the new language.
struct LanguageRoot<Content: View>: View {
    @ObservedObject private var lang = LanguageState.shared
    let content: Content
    init(_ content: Content) { self.content = content }
    var body: some View { content.id(lang.code) }
}

private final class BundleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var value: Bundle?
    func bundle(_ make: () -> Bundle?) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { value = make(); loaded = true }
        return value
    }
    func reset() { lock.lock(); loaded = false; value = nil; lock.unlock() }
}
