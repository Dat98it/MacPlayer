import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

struct ExportPane: View {
    @ObservedObject var session: EditorSession

    private var d: ExportDraft { session.draft }
    private func set(_ f: (inout ExportDraft) -> Void) { var x = session.draft; f(&x); session.draft = x }
    private func opt<T>(_ get: @escaping (ExportOptions) -> T, _ put: @escaping (inout ExportOptions, T) -> Void) -> Binding<T> {
        Binding(get: { get(d.options) }, set: { v in set { put(&$0.options, v) } })
    }

    /// Closes the export window (when shown in one).
    var onDone: () -> Void = {}
    @StateObject private var advanced = Box(false)

    var body: some View {
        // The choices scroll; the buttons stay at the bottom, always in sight.
        VStack(spacing: 0) {
            ScrollView { choices.padding(18) }.groupBoxStyle(CardGroupBoxStyle())
            Divider()
            buttons.padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private var buttons: some View {
        HStack {
            if let est = estimate() { Text(est).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            Button(L("Cancel")) { onDone() }.keyboardShortcut(.cancelAction)
            Button { if run() { onDone() } } label: { Label(L("Export Video"), systemImage: "square.and.arrow.up").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(session.project.timeline.isEmpty)
        }
    }

    private var choices: some View {
        let hasVideo = session.info?.hasVideo == true
        return VStack(alignment: .leading, spacing: 14) {
            if hasVideo { frameCard; qualityCard }
            GroupBox(L("Save")) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L("File name"), text: Binding(get: { d.name }, set: { v in set { $0.name = v } }), prompt: Text(session.project.name))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text(folderPath()).font(.caption).lineLimit(1).truncationMode(.head).foregroundColor(.secondary)
                        Spacer()
                        Button(L("Choose Folder…")) { chooseFolder() }
                    }
                    Text(L("A new file is made: the original videos are never changed, and an existing file is never overwritten.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(4)
            }
            if hasVideo {
                DisclosureGroup(L("Advanced"), isExpanded: $advanced.value) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(L("Format"), selection: opt({ $0.container }, { $0.container = $1 })) { ForEach(OutputContainer.allCases, id: \.self) { Text(".\($0.rawValue)").tag($0) } }
                        Picker(L("Codec"), selection: opt({ $0.codec }, { $0.codec = $1 })) { Text("H.264").tag(VideoCodecChoice.h264); Text("HEVC (H.265)").tag(VideoCodecChoice.hevc) }
                        Toggle(L("Include sound"), isOn: opt({ $0.includeAudio }, { $0.includeAudio = $1 })).disabled(session.info?.hasAudio != true)
                    }.padding(.top, 6)
                }
            }
            ForEach(warnings(), id: \.self) { w in Label(w, systemImage: "info.circle").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: Frame (the shape of the finished video, for each social network)

    private struct FrameChoice: Identifiable { let shape: CanvasPreset; let title: String; let detail: String; var id: String { shape.rawValue } }
    private var frames: [FrameChoice] {
        [FrameChoice(shape: .source, title: L("Original"), detail: L("As the video")),
         FrameChoice(shape: .landscape16x9, title: "16:9", detail: L("YouTube · landscape")),
         FrameChoice(shape: .portrait9x16, title: "9:16", detail: L("TikTok · Reels · Shorts")),
         FrameChoice(shape: .square1x1, title: "1:1", detail: L("Instagram · Facebook")),
         FrameChoice(shape: .portrait4x5, title: "4:5", detail: L("Instagram portrait")),
         FrameChoice(shape: .standard4x3, title: "4:3", detail: L("Classic"))]
    }

    private var frameCard: some View {
        let p = session.project
        let shape = p.frameShape, fill = p.frameFill
        return GroupBox(L("Frame")) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(frames) { f in
                        let selected = f.shape == shape
                        Button { session.edit("Frame shape") { $0.setFrame(f.shape, fill: fill) } } label: {
                            VStack(spacing: 4) {
                                frameGlyph(f.shape).frame(height: 34)
                                Text(f.title).font(.system(size: 12, weight: .semibold))
                                Text(f.detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("\(f.title), \(f.detail)").accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                if shape != .source {
                    Picker(L("Picture in the frame"), selection: Binding(get: { fill }, set: { v in session.edit("Frame fill") { $0.setFrame(shape, fill: v) } })) {
                        Text(L("Whole, black bars")).tag(FrameFill.fit); Text(L("Fill, cut the edges")).tag(FrameFill.fill); Text(L("Whole, blurred bars")).tag(FrameFill.blurredBars)
                    }.pickerStyle(.segmented)
                }
                if let v = session.info?.primaryVideo, let first = p.timeline.first {
                    let out = RenderGeometry.outputSize(source: PixelSize(width: v.width, height: v.height), look: first.look, maxHeight: d.options.resolution.maxHeight, limitsShortSide: true)
                    Text(LF("The video will be %d × %d. The picture behind shows the new frame.", out.width, out.height)).font(.caption).foregroundColor(.secondary)
                }
            }.padding(4)
        }
    }

    /// A small outline of the frame's shape.
    private func frameGlyph(_ c: CanvasPreset) -> some View {
        let a = c.aspect ?? (session.info?.primaryVideo.map { Double($0.width) / Double(max(1, $0.height)) } ?? 16.0 / 9)
        let h: CGFloat = 30, w = min(52, h * CGFloat(a))
        return RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.7), lineWidth: 1.5).frame(width: w, height: w / CGFloat(a))
    }

    // MARK: Quality (one choice: how big and how good)

    private var qualityCard: some View {
        GroupBox(L("Quality")) {
            VStack(alignment: .leading, spacing: 4) {
                let current = ExportPreset(options: d.options)
                ForEach(ExportPreset.allCases, id: \.self) { p in
                    Button { set { p.apply(to: &$0.options) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: current == p ? "largecircle.fill.circle" : "circle").foregroundColor(current == p ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(Self.presetTitle(p)).font(.callout.weight(current == p ? .semibold : .regular))
                                Text(Self.presetDetail(p)).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(current == p ? [.isButton, .isSelected] : .isButton)
                }
            }.padding(4)
        }
    }

    static func presetTitle(_ p: ExportPreset) -> String {
        switch p {
        case .original: return L("Best: as the original"); case .uhd2160: return "4K · 2160p"; case .fullHD1080: return L("Full HD · 1080p (recommended)")
        case .hd720: return "HD · 720p"; case .small480: return L("Light · 480p")
        }
    }
    static func presetDetail(_ p: ExportPreset) -> String {
        switch p {
        case .original: return L("The size of your video, the most detail; the biggest file.")
        case .uhd2160: return L("For big screens. Videos smaller than this are not enlarged.")
        case .fullHD1080: return L("Sharp on every phone and social network.")
        case .hd720: return L("A smaller file that still looks good on a phone.")
        case .small480: return L("The smallest file: quick to send in a message.")
        }
    }

    private func folderPath() -> String { d.folder ?? session.env.prefs.lastExportFolder ?? (session.sourceURL.map { PathUtil.directory(of: $0.path) } ?? NSHomeDirectory()) }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { set { $0.folder = u.path }; session.env.prefs.lastExportFolder = u.path }
    }

    private func estimate() -> String? {
        guard let info = session.info else { return nil }
        let secs = session.project.timelineDuration.seconds
        guard secs > 0 else { return nil }
        let bytes = Int64(d.options.estimatedBytesPerSecond(source: info) * secs)
        return LF("About %@ for %@ of video (an estimate: the real size varies).", Format.bytes(bytes), Format.duration(MediaTime(seconds: secs)))
    }

    private func warnings() -> [String] {
        guard let info = session.info else { return [] }
        _ = info
        let all = session.project.sources.compactMap(\.info)
        return d.options.warnings(sources: all).map { w -> String in
            switch w {
            case .reencode: return L("The video is re-encoded: it is decoded and written again, so a small amount of quality is lost.")
            case .fastCutKeepsLeadIn: return L("Fast cut copies the picture without re-encoding.")
            case .containerChange(let a, let b): return LF("Changing .%@ to .%@ may not work without re-encoding.", a, b)
            case .noUpscale: return L("The video is smaller than the chosen size, so it is not enlarged.")
            case .hdrKept: return L("This video is HDR. It stays HDR: the exported file is 10-bit HEVC, even if H.264 is chosen.")
            case .hdrMixedToSDR: return L("Some of these videos are HDR and some are not. The joined file is SDR, and the HDR ones are converted to it.")
            case .dolbyVisionMayBeLost: return L("This video has Dolby Vision. A fast cut keeps it. Re-encoding keeps the HDR picture, but the Dolby Vision data may not survive (it depends on the video): check the result.")
            case .variableFrameRate: return L("This video has a variable frame rate; it is written at a steady rate.")
            }
        }
    }

    /// Starts the export; true when it started.
    @discardableResult
    private func run() -> Bool {
        var req = ExportRequest(options: d.options, folder: folderPath(), baseName: d.name.isEmpty ? nil : d.name)
        req.options.mode = .exact
        do {
            let (jobs, batch) = try session.planExport(req)
            session.env.exports.enqueue(jobs)
            if !batch.renamedForConflict.isEmpty { session.flash(L("Some names were already taken, so numbers were added.")) }
            else { session.flash(jobs.count == 1 ? L("Export started.") : LF("%d exports started.", jobs.count)) }
            QueueWindow.shared.show()
            return true
        } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true); return false }
    }
}
