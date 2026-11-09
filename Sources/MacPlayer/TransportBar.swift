import SwiftUI
import AppKit
import MacPlayerCore

extension EditorSession {
    /// A SwiftUI binding onto the project: each change is one undo step; changes with the same key (a slider drag) merge.
    func binding<T>(_ label: String, coalesce: String? = nil, get: @escaping (Project) -> T, set: @escaping (inout Project, T) -> Void) -> Binding<T> {
        Binding(get: { get(self.project) }, set: { v in self.edit(label, coalesce: coalesce) { set(&$0, v) } })
    }
}

/// Local view state lives in a small ObservableObject: `@State` is a macro and this toolchain has no SwiftUI macro plugin.
final class TimecodeEdit: ObservableObject {
    @Published var editing = false
    @Published var text = ""
}

struct TransportBar: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var player: PlayerController
    @StateObject private var edit = TimecodeEdit()
    private var editingTime: Bool { edit.editing }

    private var fr: FrameRate { session.frameRate }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                btn("backward.end.fill", L("Go to start")) { Task { await player.seek(to: .zero) } }
                btn("gobackward.5", L("Back 5 seconds")) { player.skip(seconds: -session.env.prefs.skipSeconds) }
                btn("backward.frame.fill", L("Previous frame")) { player.step(frames: -1) }
                btn(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? L("Pause") : L("Play"), big: true) { player.togglePlay() }
                btn("forward.frame.fill", L("Next frame")) { player.step(frames: 1) }
                btn("goforward.5", L("Forward 5 seconds")) { player.skip(seconds: session.env.prefs.skipSeconds) }
                btn("forward.end.fill", L("Go to end")) { Task { await player.seek(to: session.duration) } }
            }

            Group {
                if editingTime {
                    TextField(L("Timecode"), text: $edit.text, onCommit: goToTyped)
                        .textFieldStyle(.roundedBorder).frame(width: 110).font(.system(.body, design: .monospaced))
                } else {
                    Text(Timecode.format(player.currentTime, frameRate: fr))
                        .font(.system(.body, design: .monospaced)).frame(width: 110)
                        .onTapGesture { edit.text = Timecode.format(player.currentTime); edit.editing = true }
                        .accessibilityLabel(LF("Time %@", Timecode.format(player.currentTime, frameRate: fr)))
                        .accessibilityHint(L("Click to type a time"))
                        .help(L("Click to type a time"))
                }
                Text("/ " + Timecode.format(session.duration)).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { s in
                    Button((player.speed == s ? "✓ " : "") + speedLabel(s)) { player.setSpeed(s) }
                }
            } label: { Text(speedLabel(player.speed)) }
            .frame(width: 64).help(L("Playback speed")).accessibilityLabel(L("Playback speed"))

            Menu {
                Button((player.loop == .off ? "✓ " : "") + L("No repeat")) { player.loop = .off }
                Button((player.loop == .whole ? "✓ " : "") + L("Repeat video")) { player.loop = .whole }
                Button(L("Repeat In–Out")) {
                    let a = session.inPoint ?? .zero, b = session.outPoint ?? session.duration
                    if b > a { player.loop = .range(TimeSpan(start: a, end: b)) }
                }
            } label: { Image(systemName: loopIcon) }
            .frame(width: 44).help(L("Repeat")).accessibilityLabel(L("Repeat"))

            Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .onTapGesture { player.isMuted.toggle() }.accessibilityLabel(L("Mute")).accessibilityAddTraits(.isButton)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1).frame(width: 70).accessibilityLabel(L("Volume"))

            Divider().frame(height: 18)
            if session.isProject {
                Button { session.splitAtPlayhead() } label: { Image(systemName: "scissors") }.help(L("Split at the playhead (S)")).accessibilityLabel(L("Split at playhead"))
                Button { (NSApp.delegate as? AppDelegate)?.addVideoToProject(nil) } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .help(L("Add a video to the timeline")).accessibilityLabel(L("Add video"))
            } else {
                Button { session.markIn() } label: { Text("I").font(.system(.body, design: .monospaced).bold()).frame(minWidth: 16) }.help(L("Set In point (I)")).accessibilityLabel(L("Set In point"))
                Button { session.markOut() } label: { Text("O").font(.system(.body, design: .monospaced).bold()).frame(minWidth: 16) }.help(L("Set Out point (O)")).accessibilityLabel(L("Set Out point"))
                Button { session.addClipFromInOut() } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .help(L("Add clip from In to Out (Return)")).accessibilityLabel(L("Add clip"))
            }
            Button { session.addMarker() } label: { Image(systemName: "flag") }.help(L("Add marker (M)")).accessibilityLabel(L("Add marker"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var loopIcon: String {
        switch player.loop { case .off: return "repeat"; case .whole: return "repeat.1"; case .range: return "repeat.circle" }
    }

    private func speedLabel(_ s: Float) -> String { s == floor(s) ? "\(Int(s))×" : String(format: "%g×", s) }

    private func btn(_ symbol: String, _ label: String, big: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: big ? 17 : 13)).frame(width: big ? 28 : 22, height: 24) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }

    private func goToTyped() {
        edit.editing = false
        if let t = Timecode.parse(edit.text, frameRate: fr) { Task { await player.seek(to: t) } }
        else { session.flash(L("That is not a valid time. Use 1:23.5 or 00:01:23:15."), error: true) }
    }
}
