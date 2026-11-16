import SwiftUI
import MacPlayerCore
import MacPlayerMedia

/// Turning the video to another shape with the frame following the people (0.21).
struct FollowPeopleCard: View {
    @ObservedObject var session: EditorSession
    @StateObject private var shape = Box<CanvasPreset>(.portrait9x16)
    @StateObject private var selectedOnly = Box<Bool>(false)

    var body: some View {
        ToolCard(title: L("Follow people"), icon: "person.crop.rectangle", onReset: session.hasReframe ? { session.clearReframe() } : nil) {
            Text(L("Turns the video to another shape and moves the frame with the people in each clip, so nobody is cut off. Clips that already have that shape are left as they are. Vision looks at the clips on this Mac only."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(L("New shape"), selection: Binding(get: { shape.value }, set: { shape.value = $0 })) {
                Text(L("9:16 (TikTok, Reels)")).tag(CanvasPreset.portrait9x16); Text("16:9 (YouTube)").tag(CanvasPreset.landscape16x9)
                Text("1:1").tag(CanvasPreset.square1x1); Text("4:5").tag(CanvasPreset.portrait4x5)
            }
            if session.selectedClipIDs.count > 1 {
                Toggle(LF("Only the %d selected clips", session.selectedClipIDs.count), isOn: Binding(get: { selectedOnly.value }, set: { selectedOnly.value = $0 }))
            }
            if let p = session.reframeProgress {
                HStack { ProgressView(value: p).frame(maxWidth: .infinity); Button(L("Stop")) { session.cancelReframe() }.controlSize(.small) }
                Text(LF("Looking for people… %d%%", Int(p * 100))).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: panelColumns(120), spacing: 4) {
                    PanelButton(title: L("Turn and follow"), icon: "person.crop.rectangle.badge.plus", help: L("Gives the video the new shape and makes the frame follow the people")) {
                        session.autoReframe(to: shape.value, only: selectedOnly.value && session.selectedClipIDs.count > 1 ? session.selectedClipIDs : nil)
                    }
                    if session.hasReframe {
                        PanelButton(title: L("Centre again"), icon: "dot.squareshape", help: L("Stops following: the frame stays in the middle")) { session.clearReframe() }
                    }
                }
            }
            let n = session.project.timeline.filter { $0.look.reframe != nil }.count
            if n > 0 { Text(LF("%d clips follow the people.", n)).font(.caption).foregroundColor(.secondary) }
        }
    }
}

/// Copying the look of one clip to others (0.21).
struct ClipStyleCard: View {
    @ObservedObject var session: EditorSession

    private func name(_ p: ClipStyle.Part) -> String {
        switch p {
        case .color: return L("Colour")
        case .effects: return L("Effects")
        case .frame: return L("Frame")
        case .speed: return L("Speed")
        case .transition: return L("Transition")
        case .motion: return L("Zoom and move")
        }
    }

    var body: some View {
        ToolCard(title: L("Copy style"), icon: "paintbrush") {
            Text(L("Copy this clip's look, then select other clips (⌘-click or ⇧-click on the timeline) and paste it, or paste it on every clip."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: panelColumns(96), spacing: 4) {
                PanelButton(title: L("Copy style"), icon: "doc.on.doc", help: L("Copy the look of this clip (⌥⇧⌘C)")) { session.copyStyle() }
                PanelButton(title: L("Paste"), icon: "doc.on.clipboard", help: L("Paste on the selected clips (⌥⇧⌘V)")) { session.pasteStyle() }
                    .disabled(EditorSession.copiedClipStyle == nil).opacity(EditorSession.copiedClipStyle == nil ? 0.4 : 1)
                PanelButton(title: L("Paste on all"), icon: "square.stack.3d.down.forward", help: L("Paste on every clip of the timeline")) { session.pasteStyle(toAll: true) }
                    .disabled(EditorSession.copiedClipStyle == nil).opacity(EditorSession.copiedClipStyle == nil ? 0.4 : 1)
            }
            if EditorSession.copiedClipStyle != nil {
                Text(L("Paste these parts:")).font(.caption).foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 2) {
                    ForEach(ClipStyle.Part.allCases, id: \.self) { p in
                        Toggle(name(p), isOn: Binding(get: { session.pasteParts.contains(p) }, set: { on in if on { session.pasteParts.insert(p) } else { session.pasteParts.remove(p) } }))
                    }
                }
                Text(session.selectedClipIDs.count > 1 ? LF("%d clips selected.", session.selectedClipIDs.count) : L("One clip selected: the one being edited."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// Copying the look of a text or shape to others (0.21).
struct TextStyleRow: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Style for other texts")).font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: panelColumns(80), spacing: 4) {
                PanelButton(title: L("Copy style"), icon: "doc.on.doc", help: L("Copy the font, colours and animations (⌥⇧⌘C)")) { session.copyStyle() }
                PanelButton(title: L("Paste"), icon: "doc.on.clipboard", help: L("Paste on the selected texts (⌥⇧⌘V)")) { session.pasteStyle() }
                    .disabled(EditorSession.copiedTextStyle == nil).opacity(EditorSession.copiedTextStyle == nil ? 0.4 : 1)
                PanelButton(title: L("Paste on all"), icon: "square.stack.3d.down.forward", help: L("Paste on every text (or every shape)")) { session.pasteStyle(toAll: true) }
                    .disabled(EditorSession.copiedTextStyle == nil).opacity(EditorSession.copiedTextStyle == nil ? 0.4 : 1)
            }
        }
    }
}

/// Finding the quiet stretches in the clips and cutting them out, after looking them over (0.21).
struct SilenceCard: View {
    @ObservedObject var session: EditorSession
    @StateObject private var minLength = Box<Double>(0.7)
    @StateObject private var sensitivity = Box<Double>(0.25)

    var body: some View {
        ToolCard(title: L("Cut silences"), icon: "waveform.path.badge.minus") {
            Text(L("Finds the quiet stretches in the clips (a talk, a lesson) and lists them. Uncheck the ones to keep, listen to any of them, then cut. Undo puts them back."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            SliderRow(title: L("Shortest silence (s)"), value: Binding(get: { minLength.value }, set: { minLength.value = $0 }), range: 0.3...3, format: "%.1f", onDone: {})
            SliderRow(title: L("How quiet (more = more is cut)"), value: Binding(get: { sensitivity.value }, set: { sensitivity.value = $0 }), range: 0.1...0.5, format: "%.2f", onDone: {})
            if let p = session.silenceProgress {
                ProgressView(value: p)
            } else {
                LazyVGrid(columns: panelColumns(120), spacing: 4) {
                    PanelButton(title: L("Find silences"), icon: "magnifyingglass") {
                        session.findSilences(minLength: minLength.value, sensitivity: sensitivity.value, only: session.selectedClipIDs.count > 1 ? session.selectedClipIDs : nil)
                    }
                    if !session.silences.isEmpty {
                        PanelButton(title: LF("Cut %d", session.silences.filter(\.chosen).count), icon: "scissors", tint: .red) { session.cutSilences() }
                            .disabled(!session.silences.contains(where: \.chosen))
                    }
                }
            }
            if !session.silences.isEmpty {
                let chosen = session.silences.filter(\.chosen)
                let total = chosen.reduce(0) { $0 + ($1.timeline.end - $1.timeline.start).seconds }
                Text(LF("%d of %d will be cut: %@ shorter.", chosen.count, session.silences.count, Format.duration(MediaTime(seconds: total))))
                    .font(.caption.weight(.medium))
                HStack {
                    Button(L("Check all")) { for i in session.silences.indices { session.silences[i].chosen = true } }
                    Button(L("Uncheck all")) { for i in session.silences.indices { session.silences[i].chosen = false } }
                }.font(.caption)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.silences) { s in
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { s.chosen }, set: { v in if let i = session.silences.firstIndex(where: { $0.id == s.id }) { session.silences[i].chosen = v } })).labelsHidden()
                            Text("\(Timecode.format(s.timeline.start)) – \(Timecode.format(s.timeline.end))").font(.caption.monospacedDigit())
                            Text(String(format: "%.1f s", (s.timeline.end - s.timeline.start).seconds)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            Spacer()
                            Button { session.previewSilence(s) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless).help(L("Listen from just before it")).accessibilityLabel(L("Listen from just before it"))
                        }
                    }
                }
            }
        }
    }
}
