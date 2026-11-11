import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

func color(_ hex: String) -> Color { Color(NSColor(cgColor: OverlayRendererBridge.color(hex)) ?? .white) }
enum OverlayRendererBridge {
    static func color(_ hex: String) -> CGColor {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

struct SubtitlesPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var language = Box<String>(Locale.current.identifier)
    @StateObject private var working = Box<Bool>(false)
    @StateObject private var locales = Box<[Locale]>([])
    @StateObject private var search = Box<String>("")
    @StateObject private var replace = Box<String>("")
    @StateObject private var selected = Box<Set<UUID>>([])

    /// Writes subtitles from the speech in the video, using the Mac's own recogniser, on this Mac only.
    private var autoCard: some View {
        ToolCard(title: L("Automatic subtitles"), icon: "waveform.and.mic") {
            Picker(L("Language"), selection: Binding(get: { language.value }, set: { language.value = $0 })) {
                ForEach(locales.value, id: \.identifier) { Text(Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier).tag($0.identifier) }
            }
            Button(working.value ? L("Listening…") : L("Create Subtitles from Speech")) { transcribe() }.disabled(working.value || locales.value.isEmpty || session.timingClip == nil)
            if working.value { ProgressView().controlSize(.small) }
            Text(session.timingClip == nil ? L("Add a video to the timeline first.")
                                           : L("Listens to the speech of the selected clip on this Mac only and writes timed subtitles you can then edit. Nothing is sent anywhere."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { locales.value = SpeechTranscriber.onDeviceLocales(); if !locales.value.contains(where: { $0.identifier == language.value }), let l = locales.value.first(where: { $0.identifier.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }) ?? locales.value.first { language.value = l.identifier } }
    }

    private func transcribe() {
        guard let clip = session.timingClip, let url = session.sourceURLs[clip.sourceID] else { return }
        let span: TimeSpan? = clip.sourceSpan
        let clipStart = TimelineEditor.starts(session.project.timeline)[clip.id] ?? .zero
        let speed = max(VideoLook.minimumSpeed, clip.look.speed)
        /// The recogniser counts in the video's own time; the subtitles live on the timeline.
        func onTimeline(_ t: MediaTime) -> MediaTime { clipStart + MediaTime(seconds: (t - clip.sourceStart).seconds / speed, timescale: 6000) }
        if !session.project.subtitles.cues.isEmpty {
            let a = NSAlert(); a.messageText = L("Replace the subtitles you have?"); a.informativeText = L("The new subtitles will be added to the existing ones. You can undo this.")
            a.addButton(withTitle: L("Add")); a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        working.value = true
        let locale = Locale(identifier: language.value)
        Task {
            do {
                let words = try await SpeechTranscriber.transcribe(source: url, span: span, locale: locale)
                let cues = SubtitleBuilder.cues(from: words).map { c -> SubtitleCue in var n = c; n.start = onTimeline(c.start); n.end = onTimeline(c.end); return n }
                session.edit("Automatic subtitles") { $0.subtitles.cues.append(contentsOf: cues) }
                session.flash(LF("%d subtitles were written.", cues.count))
            } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
            working.value = false
        }
    }

    var body: some View {
        let doc = session.project.subtitles
        let issues = doc.issues(videoDuration: session.info?.duration)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LF("%d subtitles", doc.cues.count)).font(.headline); Spacer()
                Button(L("Add at Playhead")) { addCue() }
            }
            HStack {
                Button(L("Import…")) { importFile() }
                Button(L("Export SRT…")) { exportFile(.srt) }.disabled(doc.cues.isEmpty)
                Button(L("Export VTT…")) { exportFile(.vtt) }.disabled(doc.cues.isEmpty)
            }.font(.caption)

            autoCard
            GroupBox(L("On export")) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: session.binding("Subtitle output", get: { $0.subtitles.burnIn }, set: { $0.subtitles.burnIn = $1 })) {
                        Text(L("Save as a separate .srt file")).tag(false)
                        Text(L("Burn into the picture")).tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    Text(L("Subtitles are not embedded as a selectable track. Burning in needs re-encoding.")).font(.caption).foregroundColor(.secondary)
                    SliderRow(title: L("Sync offset (s)"), value: session.binding("Subtitle sync", coalesce: "sync", get: { $0.subtitles.syncOffset }, set: { $0.subtitles.syncOffset = $1 }), range: -5...5, format: "%.2f", onDone: { session.endCoalescing() })
                    HStack { Button(L("Shift all by playhead…")) { shiftToPlayhead() }; Button(L("Reset")) { session.edit("Reset sync") { $0.subtitles.syncOffset = 0 } } }.font(.caption)
                }.padding(4)
            }
            GroupBox(L("Style")) {
                VStack(alignment: .leading, spacing: 4) {
                    SliderRow(title: L("Size"), value: session.binding("Subtitle size", coalesce: "ssz", get: { $0.subtitles.style.sizeFraction }, set: { $0.subtitles.style.sizeFraction = $1 }), range: 0.02...0.1, onDone: { session.endCoalescing() })
                    SliderRow(title: L("Distance from bottom"), value: session.binding("Subtitle position", coalesce: "smg", get: { $0.subtitles.style.bottomMargin }, set: { $0.subtitles.style.bottomMargin = $1 }), range: 0.02...0.4, onDone: { session.endCoalescing() })
                    HStack {
                        ColorPicker(L("Text"), selection: Binding(get: { color(doc.style.colorHex) }, set: { c in session.edit("Subtitle colour", coalesce: "scol") { $0.subtitles.style.colorHex = OverlayRendererBridge.hex(c) } }))
                        Toggle(L("Background"), isOn: Binding(get: { doc.style.backgroundHex != nil }, set: { on in session.edit("Subtitle background") { $0.subtitles.style.backgroundHex = on ? "#000000" : nil } }))
                    }
                    Button(L("Vertical video preset (9:16)")) { session.edit("Portrait subtitle style") { $0.subtitles.style = .portrait } }.font(.caption)
                }.padding(4)
            }
            if !issues.isEmpty { Label(LF("%d problems: overlaps, empty or outside the video.", issues.count), systemImage: "exclamationmark.triangle").font(.callout).foregroundColor(.orange) }

            HStack { TextField(L("Find"), text: $search.value).textFieldStyle(.roundedBorder); TextField(L("Replace with"), text: $replace.value).textFieldStyle(.roundedBorder)
                Button(L("Replace All")) { let f = search.value, r = replace.value; session.edit("Replace in subtitles") { _ = $0.subtitles.replace(f, with: r) } }.disabled(search.value.isEmpty) }.font(.caption)

            let matches = Set(doc.find(search.value))
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(doc.cues.sorted { $0.start < $1.start }) { c in
                    let bad = issues.contains { $0.cueID == c.id }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(Timecode.format(c.start)) → \(Timecode.format(c.end))").font(.caption.monospacedDigit()).foregroundColor(bad ? .orange : .secondary)
                            Spacer()
                            Button { Task { await session.player.seek(to: c.start) } } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).accessibilityLabel(L("Go to subtitle"))
                            Button { session.edit("Delete subtitle") { $0.subtitles.cues.removeAll { $0.id == c.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete subtitle"))
                        }
                        TextField(L("Text"), text: Binding(get: { c.text }, set: { t in session.edit("Edit subtitle", coalesce: "cue-\(c.id)") { p in if let i = p.subtitles.cues.firstIndex(where: { $0.id == c.id }) { p.subtitles.cues[i].text = t } } }), axis: .vertical).textFieldStyle(.roundedBorder)
                        HStack {
                            Button(L("Start here")) { setTime(c.id, start: true) }; Button(L("End here")) { setTime(c.id, start: false) }
                            Button(L("Split here")) { session.edit("Split subtitle") { _ = $0.subtitles.split(id: c.id, at: session.player.currentTime) } }
                            Button(selected.value.contains(c.id) ? L("Unselect") : L("Select to merge")) { if selected.value.contains(c.id) { selected.value.remove(c.id) } else { selected.value.insert(c.id) } }
                        }.font(.caption)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(matches.contains(c.id) ? Color.yellow.opacity(0.25) : (selected.value.contains(c.id) ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07))))
                }
            }
            if selected.value.count >= 2 { Button(L("Merge Selected")) { let ids = selected.value; session.edit("Merge subtitles") { _ = $0.subtitles.merge(ids: ids) }; selected.value = [] } }
        }
    }

    private func addCue() {
        let t = session.player.currentTime
        session.edit("Add subtitle") { $0.subtitles.cues.append(SubtitleCue(start: t, end: min(session.duration, t + MediaTime(seconds: 2)), text: L("New subtitle"))) }
    }

    private func setTime(_ id: UUID, start: Bool) {
        let t = session.player.currentTime
        session.edit("Subtitle time") { p in
            guard let i = p.subtitles.cues.firstIndex(where: { $0.id == id }) else { return }
            if start { p.subtitles.cues[i].start = t; if p.subtitles.cues[i].end <= t { p.subtitles.cues[i].end = t + MediaTime(seconds: 1) } }
            else if t > p.subtitles.cues[i].start { p.subtitles.cues[i].end = t }
        }
    }

    private func shiftToPlayhead() {
        guard let first = session.project.subtitles.cues.min(by: { $0.start < $1.start }) else { return }
        let d = (session.player.currentTime - first.start).seconds
        session.edit("Shift subtitles") { $0.subtitles.shiftAll(by: d) }
    }

    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "srt")!, .init(filenameExtension: "vtt")!, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var forced: String.Encoding?
        while true {
            guard let decoded = SubtitleCodec.decode(data, forcing: forced) else {
                session.flash(L("This encoding cannot read the file. Try another one."), error: true); if !chooseEncoding(&forced) { return }; continue
            }
            do {
                let r = try SubtitleCodec.parse(decoded.text, encoding: decoded.encoding)
                // Ask once if the result looks garbled (replacement characters) so the user can pick another encoding.
                if decoded.text.contains("\u{FFFD}"), forced == nil, chooseEncoding(&forced) { continue }
                session.edit("Import subtitles") { $0.subtitles.cues = r.cues; $0.subtitles.language = nil }
                session.flash(LF("Imported %d subtitles (%@).", r.cues.count, decoded.encoding) + (r.warnings.isEmpty ? "" : " " + LF("%d blocks were skipped.", r.warnings.count)))
                return
            } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true); return }
        }
    }

    private func chooseEncoding(_ forced: inout String.Encoding?) -> Bool {
        let alert = NSAlert(); alert.messageText = L("Choose the text encoding"); alert.informativeText = L("Vietnamese files from older tools often use Windows-1258.")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        SubtitleCodec.encodingChoices.forEach { pop.addItem(withTitle: $0.name) }
        alert.accessoryView = pop; alert.addButton(withTitle: L("Read")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        forced = SubtitleCodec.encodingChoices[pop.indexOfSelectedItem].encoding
        return true
    }

    private func exportFile(_ f: SubtitleCodec.Format) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.project.name + (f == .srt ? ".srt" : ".vtt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let why = OriginalGuard.problem(writing: url.path) { session.flash(why, error: true); return }
        let text = SubtitleCodec.serialize(session.project.subtitles.cues, format: f, offsetSeconds: session.project.subtitles.syncOffset)
        do { try Data(text.utf8).write(to: url, options: .atomic); session.flash(LF("Saved %@", url.lastPathComponent)) } catch { session.flash(error.localizedDescription, error: true) }
    }
}
