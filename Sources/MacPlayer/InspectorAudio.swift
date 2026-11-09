import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// The Audio tab: the video's own sound, music and other sounds laid on the timeline, and the microphone for a voice-over.
struct AudioPane: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var player: PlayerController
    @ObservedObject var recorder: VoiceRecorder
    init(session: EditorSession) { self.session = session; player = session.player; recorder = session.recorder }

    private var needsClip: Bool { session.isProject && session.project.activeClipID == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ownSoundCard
            if session.canHaveSounds {
                soundsCard
                voiceCard
            }
            if !session.isProject, session.info?.hasAudio == true {
                ToolCard(title: L("Save the sound alone"), icon: "square.and.arrow.down") {
                    Button(L("Export Audio Only (.m4a)…")) { exportAudio() }
                }
            }
        }
    }

    // MARK: The video's own sound

    private func aud(_ title: String, _ key: String, range: ClosedRange<Double>, fmt: String = "%.1f", _ kp: WritableKeyPath<AudioSettings, Double>) -> some View {
        SliderRow(title: title, value: session.binding(title, coalesce: key, get: { $0.activeAudio[keyPath: kp] }, set: { $0.activeAudio[keyPath: kp] = $1 }), range: range, format: fmt, onDone: { session.endCoalescing() })
    }

    @ViewBuilder private var ownSoundCard: some View {
        ToolCard(title: L("Sound of the video"), icon: "speaker.wave.2", onReset: needsClip || session.info?.hasAudio != true ? nil : { session.edit("Reset audio") { $0.activeAudio = AudioSettings() } }) {
            if needsClip {
                Text(L("Select a clip on the timeline to edit its sound.")).font(.callout).foregroundColor(.secondary)
            } else if session.info?.hasAudio != true && !session.isProject {
                Text(L("This file has no audio.")).font(.callout).foregroundColor(.secondary)
            } else {
                if player.audioOptions.count > 1 {
                    Picker(L("Audio track"), selection: Binding<Int>(get: { 0 }, set: { i in if player.audioOptions.indices.contains(i) { Task { await player.selectAudio(player.audioOptions[i]) } } })) {
                        ForEach(Array(player.audioOptions.enumerated()), id: \.offset) { i, o in Text(o.displayName).tag(i) }
                    }
                }
                Toggle(L("Mute"), isOn: session.binding("Mute", get: { $0.activeAudio.muted }, set: { $0.activeAudio.muted = $1 }))
                aud(L("Gain (dB)"), "gain", range: -24...24, \.gainDB)
                HStack {
                    Button { session.normalizeMainVolume() } label: { Label(L("Match volume"), systemImage: "waveform.badge.magnifyingglass") }
                        .help(L("Measures the sound and sets the gain so that it is neither too quiet nor too loud."))
                    Spacer()
                }.font(.caption)
                aud(L("Fade in (s)"), "fi", range: 0...5, \.fadeIn)
                aud(L("Fade out (s)"), "fo", range: 0...5, \.fadeOut)
                aud(L("Delay the sound (s)"), "off", range: -1...1, fmt: "%.2f", \.offsetSeconds)
                Text(L("A positive value plays the sound later than the picture; a negative one plays it earlier.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                NoiseControl(strength: session.project.activeAudio.denoise, progress: session.denoiseProgress[.main]) { session.setDenoise($0, for: .main) }
                Divider()
                SoundFXControl(fx: session.project.activeAudio.fx, progress: session.fxProgress[.main]) { session.setSoundFX($0, for: .main) }
                if !session.isProject {
                    Divider()
                    HStack {
                        Text(session.project.activeAudio.replacementPath.map { PathUtil.fileName(of: $0) } ?? L("Using the video's own sound")).font(.callout).lineLimit(1)
                        Spacer()
                        Button(L("Replace…")) {
                            let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = false
                            if p.runModal() == .OK, let u = p.url { session.edit("Replace sound") { $0.activeAudio.replacementPath = u.path } }
                        }
                        if session.project.activeAudio.replacementPath != nil { Button(L("Remove")) { session.edit("Restore sound") { $0.activeAudio.replacementPath = nil } } }
                    }.font(.caption)
                }
            }
        }
    }

    // MARK: Music and other sounds

    @ViewBuilder private var soundsCard: some View {
        let sounds = session.sounds
        ToolCard(title: L("Music and sounds"), icon: "music.note.list") {
            LazyVGrid(columns: panelColumns(90), spacing: 4) {
                PanelButton(title: L("Add music"), icon: "music.note", help: L("Add a song or other sound that plays under the video, from the playhead")) { session.chooseSounds(kind: .music) }
                PanelButton(title: L("Add effect"), icon: "waveform", help: L("Add a short sound effect at the playhead")) { session.chooseSounds(kind: .effect) }
            }
            if sounds.isEmpty {
                Text(L("Nothing here yet. Music and sounds start at the playhead and play alongside the video's own sound.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                SoundBar(session: session)
                ForEach(sounds) { c in row(c) }
                if let c = session.selectedSound { editor(c) }
            }
        }
    }

    private func icon(_ k: SoundKind) -> String { k == .music ? "music.note" : (k == .voice ? "mic" : "waveform") }

    private func row(_ c: SoundClip) -> some View {
        let selected = session.selectedSoundID == c.id
        let missing = session.isMissing(c)
        return HStack(spacing: 6) {
            Image(systemName: icon(c.kind)).foregroundColor(missing ? .red : SoundBar.color(c.kind)).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).lineLimit(1).font(.callout.weight(.medium))
                Text("\(Timecode.format(c.start)) – \(Timecode.format(c.end))" + (missing ? " · " + L("Missing") : "") + (c.muted ? " · " + L("Muted") : "")).font(.caption2.monospacedDigit()).foregroundColor(missing ? .red : .secondary)
            }
            Spacer()
            if c.ducking { Image(systemName: "arrow.down.right.and.arrow.up.left").font(.caption2).foregroundColor(.secondary).help(L("Turns down while someone speaks")).accessibilityLabel(L("Turns down while someone speaks")) }
            Button { session.deleteSound(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete sound"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedSoundID = c.id; Task { await session.player.seek(to: c.start) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LF("Sound %@, from %@ to %@", c.name, Timecode.format(c.start), Timecode.format(c.end)))
        .contextMenu {
            Button(L("Duplicate")) { session.duplicateSound(c.id) }
            Button(L("Delete")) { session.deleteSound(c.id) }
        }
    }

    @ViewBuilder private func editor(_ c: SoundClip) -> some View {
        let id = c.id
        let fileLength = (c.fileDuration ?? c.sourceStart + c.duration).seconds
        Divider()
        TextField(L("Name"), text: Binding(get: { c.name }, set: { n in session.updateSound(id, "Rename sound", coalesce: "name") { $0.name = n } })).textFieldStyle(.roundedBorder)
        HStack {
            Text(LF("Starts at %@", Timecode.format(c.start))).font(.caption.monospacedDigit())
            Spacer()
            Button(L("Start here")) { session.updateSound(id, "Move sound") { $0.start = session.player.currentTime } }.font(.caption)
        }
        SliderRow(title: L("Length (s)"), value: Binding(get: { c.duration.seconds }, set: { v in session.updateSound(id, "Trim sound", coalesce: "len") { $0.duration = MediaTime(seconds: v, timescale: 600) } }),
                  range: 0.2...max(0.5, fileLength - c.sourceStart.seconds), format: "%.1f", onDone: { session.endCoalescing() })
        SliderRow(title: L("Skip the start of the file (s)"), value: Binding(get: { c.sourceStart.seconds }, set: { v in session.updateSound(id, "Trim sound", coalesce: "skip") { $0.sourceStart = MediaTime(seconds: v, timescale: 600); $0.duration = min($0.duration, MediaTime(seconds: max(0.2, fileLength - v), timescale: 600)) } }),
                  range: 0...max(0.5, fileLength - 0.5), format: "%.1f", onDone: { session.endCoalescing() })
        Toggle(L("Mute"), isOn: Binding(get: { c.muted }, set: { m in session.updateSound(id, "Mute sound") { $0.muted = m } }))
        SliderRow(title: L("Gain (dB)"), value: Binding(get: { c.gainDB }, set: { v in session.updateSound(id, "Sound gain", coalesce: "gain") { $0.gainDB = v } }), range: -30...12, format: "%.1f", onDone: { session.endCoalescing() })
        HStack {
            Button { session.normalizeSoundVolume(id) } label: { Label(L("Match volume"), systemImage: "waveform.badge.magnifyingglass") }
                .help(L("Measures the sound and sets the gain so that it is neither too quiet nor too loud."))
            Spacer()
        }.font(.caption)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Volume over time")).font(.caption)
                Spacer()
                if c.volumeCurve != nil { Button(L("Straighten")) { session.updateSound(id, "Clear volume curve") { $0.volumeCurve = nil } }.buttonStyle(.borderless).font(.caption) }
            }
            VolumeCurveEditor(points: c.volumeCurve ?? [], length: max(0.1, c.duration.seconds),
                              onChange: { pts in session.updateSound(id, "Volume curve", coalesce: "vc-\(id)") { $0.volumeCurve = pts.isEmpty ? nil : pts } },
                              onDone: { session.endCoalescing() })
                .frame(height: 70)
            Text(L("Click the line to add a point, drag a point up or down to make the sound louder or quieter there, double-click a point to remove it.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        SliderRow(title: L("Fade in (s)"), value: Binding(get: { c.fadeIn }, set: { v in session.updateSound(id, "Sound fade", coalesce: "fi") { $0.fadeIn = v } }), range: 0...10, format: "%.1f", onDone: { session.endCoalescing() })
        SliderRow(title: L("Fade out (s)"), value: Binding(get: { c.fadeOut }, set: { v in session.updateSound(id, "Sound fade", coalesce: "fo") { $0.fadeOut = v } }), range: 0...10, format: "%.1f", onDone: { session.endCoalescing() })
        if c.kind != .voice {
            Divider()
            Toggle(L("Turn down while someone speaks"), isOn: Binding(get: { c.ducking }, set: { on in session.updateSound(id, "Ducking") { $0.ducking = on } }))
                .help(L("Finds when the video's own sound or a voice-over has speech and lowers this sound under it."))
            if c.ducking {
                SliderRow(title: L("How far it goes down (dB)"), value: Binding(get: { -c.duckDepthDB }, set: { v in session.updateSound(id, "Ducking depth", coalesce: "duck") { $0.duckDepthDB = -v } }), range: 3...30, format: "%.0f", onDone: { session.endCoalescing() })
                Text(L("It goes down just before speech starts and comes back up after it ends.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Divider()
        NoiseControl(strength: c.denoise, progress: session.denoiseProgress[.sound(id)]) { session.setDenoise($0, for: .sound(id)) }
        Divider()
        SoundFXControl(fx: c.fx, progress: session.fxProgress[.sound(id)]) { session.setSoundFX($0, for: .sound(id)) }
        HStack {
            Button(L("Duplicate")) { session.duplicateSound(id) }
            Button(L("Delete")) { session.deleteSound(id) }
            Spacer()
        }.font(.caption)
    }

    // MARK: Voice-over

    @ViewBuilder private var voiceCard: some View {
        ToolCard(title: L("Voice-over"), icon: "mic") {
            Button { session.toggleVoiceRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle").font(.title3).foregroundColor(.red)
                    Text(recorder.isRecording ? L("Stop recording") : L("Record a voice-over")).font(.callout.weight(.medium))
                    Spacer()
                    if recorder.isRecording { Text(Format.duration(MediaTime(seconds: recorder.seconds))).font(.callout.monospacedDigit()).foregroundColor(.red) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(recorder.isRecording ? 0.18 : 0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? L("Stop recording") : L("Record a voice-over"))
            if recorder.isRecording {
                ProgressView(value: Double(recorder.level)).tint(.red).accessibilityLabel(L("Microphone level"))
            }
            Toggle(L("Play the video while recording"), isOn: $session.recordWithPlayback).disabled(recorder.isRecording)
            Text(L("The voice-over starts at the playhead and is added as a sound on the timeline. Use headphones so the video's sound is not recorded too. The recording stays on this Mac.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Export audio alone

    private func exportAudio() {
        guard let src = session.sourceURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Audio]; panel.nameFieldStringValue = session.project.name + ".m4a"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let span = TimeSpan(start: session.inPoint ?? .zero, end: session.outPoint ?? session.duration)
        let audio = session.project.activeAudio, env = session.env
        session.flash(L("Exporting audio…"))
        Task {
            do {
                _ = try await env.saver.saveCopy(sourcePath: src.path, destination: url.path, overwrite: true, estimatedBytes: Int64(span.duration.seconds * 24_000),
                    produce: { temp in try await AudioExporter.export(source: src, span: span, audio: audio, to: URL(fileURLWithPath: temp)) },
                    verify: { temp in
                        let info = try await MediaProbe.probe(url: URL(fileURLWithPath: temp))
                        guard info.hasAudio else { throw SaveError.verificationFailed("no audio track") }
                    })
                session.flash(LF("Saved %@", url.lastPathComponent))
            } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
        }
    }
}

/// Switch and strength for background-noise removal.
struct NoiseControl: View {
    var strength: Double?
    var progress: Double?
    var onChange: (Double?) -> Void

    private var level: Int { guard let s = strength else { return 1 }; return s < 0.45 ? 0 : (s < 0.75 ? 1 : 2) }
    private let values = [0.3, 0.6, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Reduce background noise"), isOn: Binding(get: { strength != nil }, set: { on in onChange(on ? values[1] : nil) })).disabled(progress != nil)
                .help(L("Takes out steady noise such as a fan, a hiss or the hum of a room. The original file is not changed."))
            if strength != nil || progress != nil {
                Picker(L("Strength"), selection: Binding(get: { level }, set: { onChange(values[$0]) })) {
                    Text(L("Light")).tag(0); Text(L("Medium")).tag(1); Text(L("Strong")).tag(2)
                }.pickerStyle(.segmented).disabled(progress != nil)
            }
            if let progress {
                ProgressView(value: progress) { Text(L("Cleaning the sound…")).font(.caption) }
            } else if strength != nil {
                Text(L("A stronger setting removes more noise but can make a voice sound thinner.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The sounds drawn against the length of the video: where each one starts and ends. Drag one to move it.
struct SoundBar: View {
    @ObservedObject var session: EditorSession
    @StateObject private var origin = Box<MediaTime?>(nil)

    static func color(_ k: SoundKind) -> Color { k == .music ? .blue : (k == .voice ? .red : .orange) }

    /// The row each sound sits in, so that sounds at the same time do not cover each other.
    static func lanes(_ clips: [SoundClip]) -> [UUID: Int] {
        var ends: [Double] = [], out: [UUID: Int] = [:]
        for c in clips.sorted(by: { $0.start < $1.start }) {
            let lane = ends.firstIndex { $0 <= c.start.seconds + 0.001 } ?? ends.count
            if lane == ends.count { ends.append(0) }
            ends[lane] = c.end.seconds; out[c.id] = lane
        }
        return out
    }

    var body: some View {
        let total = max(0.1, session.duration.seconds)
        let clips = session.sounds
        let lanes = Self.lanes(clips)
        let rows = (lanes.values.max() ?? 0) + 1
        let laneHeight: CGFloat = 18
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12))
                ForEach(clips) { c in
                    let x = CGFloat(c.start.seconds / total) * w
                    let width = max(6, CGFloat(min(c.duration.seconds, max(0, total - c.start.seconds)) / total) * w)
                    let selected = session.selectedSoundID == c.id
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.color(c.kind).opacity(c.muted ? 0.25 : (selected ? 0.9 : 0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.primary : Color.clear, lineWidth: 1.5))
                        .frame(width: width, height: laneHeight - 3)
                        .offset(x: x, y: CGFloat(lanes[c.id] ?? 0) * laneHeight + 4)
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { v in
                                session.selectedSoundID = c.id
                                if origin.value == nil { origin.value = c.start }
                                let o = origin.value ?? c.start
                                let t = max(0, o.seconds + Double(v.translation.width / max(1, w)) * total)
                                session.updateSound(c.id, "Move sound", coalesce: "move") { $0.start = MediaTime(seconds: t, timescale: 600) }
                            }
                            .onEnded { _ in origin.value = nil; session.endCoalescing() })
                        .onTapGesture { session.selectedSoundID = c.id }
                        .help(c.name)
                        .accessibilityHidden(true)
                }
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: CGFloat(rows) * laneHeight + 8)
                    .offset(x: CGFloat(min(1, max(0, session.player.currentTime.seconds / total))) * w)
            }
        }
        .frame(height: CGFloat(rows) * laneHeight + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LF("%d sounds on the timeline", clips.count))
    }
}


/// Voice and sound effects: a row of ready-made looks (deeper, higher, telephone, hall, echo...), and the values behind them to set by hand.
/// A change is worked into a copy of the sound first, so it is applied with a button, not while a slider moves.
struct SoundFXControl: View {
    var fx: SoundFX?
    var progress: Double?
    var onChange: (SoundFX?) -> Void
    @StateObject private var draft = Box<SoundFX>(SoundFX())
    @StateObject private var open = Box<Bool>(false)

    static func name(_ p: SoundFX.Preset) -> String {
        switch p {
        case .clearVoice: return L("Clear voice"); case .warm: return L("Warm"); case .deep: return L("Deep voice"); case .high: return L("High voice")
        case .chipmunk: return L("Chipmunk"); case .telephone: return L("Telephone"); case .hall: return L("Hall"); case .echo: return L("Echo")
        }
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<SoundFX, Double>, _ range: ClosedRange<Double>, _ format: String) -> some View {
        SliderRow(title: title, value: Binding(get: { draft.value[keyPath: kp] }, set: { draft.value[keyPath: kp] = $0 }), range: range, format: format)
    }

    var body: some View {
        let busy = progress != nil
        let current = fx ?? SoundFX()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Voice and sound effects")).font(.caption.weight(.semibold))
                Spacer()
                if fx != nil { Button(L("Take off")) { onChange(nil) }.buttonStyle(.borderless).font(.caption).disabled(busy) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 5)], spacing: 5) {
                ForEach(SoundFX.Preset.allCases, id: \.self) { p in
                    let selected = fx?.preset == p
                    Button { draft.value = p.fx; onChange(p.fx) } label: {
                        Text(Self.name(p)).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: selected ? 2 : 0))
                    }.buttonStyle(.plain).disabled(busy).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            DisclosureGroup(L("Set by hand"), isExpanded: $open.value) {
                VStack(alignment: .leading, spacing: 4) {
                    slider(L("Bass (dB)"), \.bass, -12...12, "%+.0f")
                    slider(L("Middle (dB)"), \.mid, -12...12, "%+.0f")
                    slider(L("Treble (dB)"), \.treble, -12...12, "%+.0f")
                    slider(L("Pitch (semitones)"), \.pitch, -12...12, "%+.0f")
                    slider(L("Room"), \.reverb, 0...1, "%.2f")
                    slider(L("Echo"), \.echo, 0...1, "%.2f")
                    HStack {
                        Button(L("Apply")) { onChange(draft.value.isNeutral ? nil : draft.value) }.disabled(busy || draft.value == current)
                        Button(L("Reset values")) { draft.value = SoundFX() }.disabled(draft.value.isNeutral)
                    }.font(.caption)
                }.padding(.top, 4)
            }.font(.caption)
            if let progress { ProgressView(value: progress) { Text(L("Changing the sound…")).font(.caption) } }
            else { Text(L("Makes a voice deeper or higher, adds bass or treble, a room or an echo. The original file is not changed.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { draft.value = current }
    }
}


/// The volume of a sound drawn over its length: click the line to add a point, drag to make it louder or quieter, double-click to remove.
struct VolumeCurveEditor: View {
    var points: [VolumePoint]
    var length: Double
    var onChange: ([VolumePoint]) -> Void
    var onDone: () -> Void
    @StateObject private var dragState = Box<Int?>(nil)
    @StateObject private var lastTapState = Box<(index: Int, time: Date)?>(nil)

    private let range = VolumeCurve.range

    private func point(_ p: VolumePoint, in s: CGSize) -> CGPoint {
        CGPoint(x: s.width * p.time / max(length, 0.01), y: s.height * (1 - (p.gainDB - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    private func value(_ loc: CGPoint, in s: CGSize) -> VolumePoint {
        let t = min(max(loc.x / s.width, 0), 1) * length
        let g = range.lowerBound + (1 - min(max(loc.y / s.height, 0), 1)) * (range.upperBound - range.lowerBound)
        return VolumePoint(time: t, gainDB: (g * 2).rounded() / 2)
    }
    private func nearest(_ loc: CGPoint, in s: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in points.enumerated() {
            let d = hypot(point(p, in: s).x - loc.x, point(p, in: s).y - loc.y)
            if d < 12, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.3)))
                let zeroY = size.height * (1 - (0 - range.lowerBound) / (range.upperBound - range.lowerBound))
                var zero = Path(); zero.move(to: CGPoint(x: 0, y: zeroY)); zero.addLine(to: CGPoint(x: size.width, y: zeroY))
                ctx.stroke(zero, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                var line = Path()
                if points.isEmpty { line.move(to: CGPoint(x: 0, y: zeroY)); line.addLine(to: CGPoint(x: size.width, y: zeroY)) }
                else {
                    let first = point(points[0], in: size)
                    line.move(to: CGPoint(x: 0, y: first.y)); line.addLine(to: first)
                    for p in points.dropFirst() { line.addLine(to: point(p, in: size)) }
                    line.addLine(to: CGPoint(x: size.width, y: point(points[points.count - 1], in: size).y))
                }
                ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.8)
                for p in points {
                    let c = point(p, in: size)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)), with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragState.value == nil {
                        if let i = nearest(v.startLocation, in: s) { dragState.value = i }
                        else {
                            let new = value(v.startLocation, in: s)
                            let next = VolumeCurve.cleaned(points + [new], length: length)
                            onChange(next)
                            dragState.value = next.firstIndex { abs($0.time - new.time) < 0.06 }
                        }
                    }
                    guard let i = dragState.value, i < points.count else { return }
                    var next = points
                    let moved = value(v.location, in: s)
                    let lo = i > 0 ? next[i - 1].time + 0.06 : 0, hi = i < next.count - 1 ? next[i + 1].time - 0.06 : length
                    next[i] = VolumePoint(time: min(max(moved.time, lo), max(lo, hi)), gainDB: moved.gainDB)
                    onChange(next)
                }
                .onEnded { v in
                    defer { dragState.value = nil; onDone() }
                    guard let i = dragState.value, i < points.count else { return }
                    if hypot(v.translation.width, v.translation.height) < 3 {
                        if let last = lastTapState.value, last.index == i, Date().timeIntervalSince(last.time) < 0.4 {
                            var next = points; next.remove(at: i); onChange(next); lastTapState.value = nil
                        } else { lastTapState.value = (i, Date()) }
                    } else { lastTapState.value = nil }
                })
        }
        .accessibilityElement().accessibilityLabel(L("Volume over time")).accessibilityHint(L("Click to add a point, drag to change the volume there."))
    }
}
