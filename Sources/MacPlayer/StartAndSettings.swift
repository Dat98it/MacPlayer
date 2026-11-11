import SwiftUI
import AppKit
import MacPlayerCore

extension Notification.Name {
    /// The list of recent files was cleared.
    static let recentsChanged = Notification.Name("MacPlayerRecentsChanged")
}

/// A slim bar above the picture while watching: which file is open, rename / Trash, "Edit", and the button that closes it again.
struct VideoHeader: View {
    @ObservedObject var session: EditorSession
    var onClose: () -> Void
    var onRename: () -> Void = {}
    var onTrash: () -> Void = {}
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isPhoto ? "photo" : "film").foregroundColor(.secondary).accessibilityHidden(true)
            Text(session.sourceURL?.lastPathComponent ?? session.project.name)
                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if session.sourceURL != nil {
                Button(action: onRename) { Image(systemName: "pencil") }.buttonStyle(.borderless).help(L("Rename the file")).accessibilityLabel(L("Rename the file"))
                Button(action: onTrash) { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("Move the file to the Trash")).accessibilityLabel(L("Move the file to the Trash"))
            }
            Spacer(minLength: 8)
            if session.sourceURL != nil {
                Button(action: onEdit) { Label(L("Edit"), systemImage: "slider.horizontal.below.rectangle") }
                    .controlSize(.small)
                    .help(L("Make a project from this file and edit it (⌘E). The file itself is never changed."))
            }
            Button(action: onClose) { Label(L("Close"), systemImage: "xmark.circle") }
                .controlSize(.small)
                .help(L("Close this file and go back to the playlists (⇧⌘W)"))
                .accessibilityLabel(L("Close"))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct NoticeBar: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if let n = session.notice {
            HStack {
                Image(systemName: n.isError ? "exclamationmark.triangle.fill" : "info.circle.fill").foregroundColor(n.isError ? .orange : .accentColor)
                // Two lines at most (the whole text on hover): a long message asked for its height at the narrowest width and pushed the
                // picture out of the window (0.11).
                Text(n.text).font(.callout).lineLimit(2).truncationMode(.tail).help(n.text)
                Spacer()
                Button { session.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(L("Dismiss"))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            .background(n.isError ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.12))
            .accessibilityElement(children: .combine)
        }
    }
}

final class SettingsRefresh: ObservableObject { func bump() { objectWillChange.send() } }

struct SettingsView: View {
    let env: AppEnvironment
    @StateObject private var r = SettingsRefresh()
    private var p: AppPreferences { env.prefs }

    var body: some View {
        let _ = r.objectWillChange
        TabView {
            Form {
                Stepper(value: Binding(get: { p.skipSeconds }, set: { p.skipSeconds = $0; r.bump() }), in: 1...60, step: 1) { Text(LF("Arrow key skips %d seconds", Int(p.skipSeconds))) }
                Stepper(value: Binding(get: { p.bigSkipSeconds }, set: { p.bigSkipSeconds = $0; r.bump() }), in: 5...300, step: 5) { Text(LF("Shift+arrow skips %d seconds", Int(p.bigSkipSeconds))) }
                Stepper(value: Binding(get: { p.photoSlideSeconds }, set: { p.photoSlideSeconds = $0; r.bump() }), in: 1...60, step: 1) { Text(LF("A photo stays %d seconds in a slideshow", Int(p.photoSlideSeconds))) }
                Toggle(L("Keep the voice pitch when changing speed"), isOn: Binding(get: { p.preserveVoicePitch }, set: { p.preserveVoicePitch = $0; r.bump() }))
                Toggle(L("Keep the window above other windows"), isOn: Binding(get: { p.keepWindowOnTop }, set: { p.keepWindowOnTop = $0; (NSApp.delegate as? AppDelegate)?.applyFloating(); r.bump() }))
                Divider()
                Toggle(L("Remember where I stopped in each video"), isOn: Binding(get: { p.rememberPositions }, set: { p.rememberPositions = $0; r.bump() }))
                Picker(L("When reopening"), selection: Binding(get: { p.resumeBehavior }, set: { p.resumeBehavior = $0; r.bump() })) {
                    Text(L("Ask me")).tag(ResumeBehavior.ask); Text(L("Always continue")).tag(ResumeBehavior.always); Text(L("Always start over")).tag(ResumeBehavior.never)
                }
                HStack { Text(LF("%d positions remembered", env.positions.count)); Spacer(); Button(L("Clear History")) { env.positions.clear(); r.bump() } }
            }.tabItem { Text(L("Playback")) }.padding(16)

            Form {
                Label(L("MacPlayer never changes your original videos and photos. Every export is a new file."), systemImage: "lock.shield")
                TextField(L("Added to copy names"), text: Binding(get: { p.copySuffix }, set: { p.copySuffix = $0; r.bump() }))
                Divider()
                Text(L("Projects are saved into their own file as you work. A recovery copy is also kept on this Mac, in case the app stops.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }.tabItem { Text(L("Saving")) }.padding(16)

            Form {
                Stepper(value: Binding(get: { p.maxConcurrentExports }, set: { p.maxConcurrentExports = $0; r.bump() }), in: 1...4) { Text(LF("Exports at the same time: %d", p.maxConcurrentExports)) }
                Text(L("Higher is faster for many small clips but uses more memory and heat.")).font(.caption).foregroundColor(.secondary)
                Divider()
                HStack {
                    Text(LF("Recovery data: %@", Format.bytes(env.projectStore.recoveryBytes())))
                    Spacer()
                    Button(L("Clear Recovery Data")) {
                        let a = NSAlert(); a.messageText = L("Clear recovery data?"); a.informativeText = L("This removes autosaved copies and restore points of projects. Video files are never touched.")
                        a.addButton(withTitle: L("Clear")); a.addButton(withTitle: L("Cancel"))
                        if a.runModal() == .alertFirstButtonReturn { try? FileManager.default.removeItem(atPath: env.support.appendingPathComponent("Recovery").path); r.bump() }
                    }
                }
            }.tabItem { Text(L("Storage")) }.padding(16)

            VStack(alignment: .leading, spacing: 10) {
                Label(L("MacPlayer works on your Mac. Your videos, audio, subtitles and thumbnails are never uploaded."), systemImage: "lock.shield")
                Text(L("There is no account, no telemetry and no online feature in this version, so there is nothing to switch on or off.")).foregroundColor(.secondary)
                Text(L("Logs contain no video content or file paths.")).foregroundColor(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).tabItem { Text(L("Privacy")) }.padding(16)

            Form {
                shortcut("⌘1  ⌘2  ⇧⌘H", L("Playlists / projects / home")); shortcut("⌘N", L("New project (in Editing)")); shortcut("⌘E", L("Edit the file you are watching"))
                shortcut("Space", L("Play / pause")); shortcut("← →", L("Skip back / forward")); shortcut("⇧← ⇧→", L("Big skip"))
                shortcut(", .", L("Previous / next frame")); shortcut("S", L("Split clip at playhead")); shortcut("M", L("Add marker"))
                shortcut("{   }", L("Previous / next marker")); shortcut("- =", L("Slower / faster")); shortcut("F", L("Full screen"))
                shortcut("Delete", L("Delete selected clip")); shortcut("⌘Z  ⇧⌘Z", L("Undo / redo")); shortcut("⌘S", L("Save now")); shortcut("⌥⌘S", L("Export video…"))
                Text(L("These shortcuts cannot be changed in this version.")).font(.caption).foregroundColor(.secondary)
            }.tabItem { Text(L("Shortcuts")) }.padding(16)
        }
        .frame(width: 560, height: 400)
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        HStack { Text(keys).font(.system(.body, design: .monospaced)).frame(width: 110, alignment: .leading); Text(what); Spacer() }
    }
}
