import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

final class ThumbStrip: ObservableObject {
    @Published var frames: [(MediaTime, NSImage)] = []
    private var loadedFor: URL?

    @MainActor func load(_ s: EditorSession) async {
        guard let url = s.sourceURL, loadedFor != url, s.info?.hasVideo == true else { return }
        loadedFor = url
        frames = []
        let n = 10, d = s.duration.seconds
        for i in 0..<n {
            let t = MediaTime(seconds: d * (Double(i) + 0.5) / Double(n), timescale: 600)
            if let img = try? await FrameGrabber.image(url: url, at: t, accuracy: .nearest, maxSize: CGSize(width: 220, height: 124)) {
                frames.append((t, NSImage(cgImage: img, size: .zero)))
            }
        }
    }
}

struct ThumbnailPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var strip = ThumbStrip()
    @StateObject private var preview = Box<[String: NSImage]>([:])
    @StateObject private var aspect = Box<CanvasPreset>(.source)
    @StateObject private var useJPEG = Box<Bool>(false)

    var body: some View {
        let th = session.project.thumbnails
        VStack(alignment: .leading, spacing: 12) {
            if session.isProject { Text(L("Thumbnails and cover art work on a single video. Switch to a single video to use them.")).foregroundColor(.secondary) }
            else if session.info?.hasVideo != true { Text(L("This file has no picture.")).foregroundColor(.secondary) } else {
                Text(L("Suggested frames")).font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(strip.frames.enumerated()), id: \.offset) { _, f in
                            Image(nsImage: f.1).resizable().aspectRatio(contentMode: .fit).frame(height: 54).cornerRadius(3)
                                .onTapGesture { Task { await session.player.seek(to: f.0) } }
                                .accessibilityLabel(LF("Frame at %@", Timecode.format(f.0))).accessibilityAddTraits(.isButton)
                        }
                    }
                }.task { await strip.load(session) }
                Text(L("These are only suggestions to help you choose. Click one to go there, then pick a frame below.")).font(.caption).foregroundColor(.secondary)

                section(title: L("1. Picture in MacPlayer"), note: L("Changes how this video looks inside MacPlayer only. Nothing outside the app changes."), key: "lib", time: th.libraryTime,
                        set: { t in session.edit("Library thumbnail", refreshPreview: false) { $0.thumbnails.libraryTime = t } }) { EmptyView() }

                section(title: L("2. Export a thumbnail image"), note: L("Saves a PNG or JPEG file. You upload it wherever you publish the video."), key: "exp", time: th.exportTime,
                        set: { t in session.edit("Export thumbnail frame", refreshPreview: false) { $0.thumbnails.exportTime = t } }) {
                    HStack {
                        Picker(L("Shape"), selection: $aspect.value) { Text(L("Same as video")).tag(CanvasPreset.source); Text("16:9").tag(CanvasPreset.landscape16x9); Text("9:16").tag(CanvasPreset.portrait9x16); Text("1:1").tag(CanvasPreset.square1x1) }
                        Picker(L("Format"), selection: $useJPEG.value) { Text("PNG").tag(false); Text("JPEG").tag(true) }.frame(width: 110)
                    }
                    Button(L("Save Image…")) { saveImage(at: th.exportTime ?? session.player.currentTime) }
                }

                section(title: L("3. Cover art inside the file"), note: session.project.export.container == .mov
                            ? L("MOV files are not given cover art by MacPlayer, because it could not be confirmed to read back. Use MP4 or M4V.")
                            : L("Embeds the frame in the exported MP4/M4V. Finder, players and websites may ignore it: MacPlayer cannot change a thumbnail on a website."),
                        key: "emb", time: th.embedTime, enabled: session.project.export.container != .mov,
                        set: { t in session.edit("Embedded artwork frame", refreshPreview: false) { $0.thumbnails.embedTime = t } }) { EmptyView() }
            }
        }
    }

    @ViewBuilder private func section<Extra: View>(title: String, note: String, key: String, time: MediaTime?, enabled: Bool = true,
                                                   set: @escaping (MediaTime?) -> Void, @ViewBuilder extra: () -> Extra) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                Text(note).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Use Current Frame")) { Task { let t = await session.currentFrameTime(); set(t); await refresh(key, t) } }.disabled(!enabled)
                    if time != nil { Button(L("Clear")) { set(nil); preview.value[key] = nil } }
                    Spacer()
                    if let t = time { Text(Timecode.format(t)).font(.caption.monospacedDigit()) } else { Text(L("Not set")).font(.caption).foregroundColor(.secondary) }
                }
                if let img = preview.value[key] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 90).cornerRadius(4) }
                extra()
            }.padding(4).task { if let t = time, preview.value[key] == nil { await refresh(key, t) } }
        }
    }

    private func refresh(_ key: String, _ t: MediaTime) async {
        if let cg = await session.stillImage(at: t, maxSize: CGSize(width: 320, height: 180)) { preview.value[key] = NSImage(cgImage: cg, size: .zero) }
    }

    private func saveImage(at t: MediaTime) {
        guard let src = session.sourceURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [useJPEG.value ? .jpeg : .png]
        panel.nameFieldStringValue = session.project.name + (useJPEG.value ? ".jpg" : ".png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fmt: ImageWriter.Format = useJPEG.value ? .jpeg(quality: 0.92) : .png, shape = aspect.value
        Task {
            do {
                try await StillExporter.export(source: src, at: t, aspect: shape, format: fmt, to: url)
                session.flash(LF("Saved %@", url.lastPathComponent))
            } catch { session.flash(error.localizedDescription, error: true) }
        }
    }
}

struct ExportPane: View {
    @ObservedObject var session: EditorSession

    private var d: ExportDraft { session.draft }
    private func set(_ f: (inout ExportDraft) -> Void) { var x = session.draft; f(&x); session.draft = x }
    private func opt<T>(_ get: @escaping (ExportOptions) -> T, _ put: @escaping (inout ExportOptions, T) -> Void) -> Binding<T> {
        Binding(get: { get(d.options) }, set: { v in set { put(&$0.options, v) } })
    }

    var body: some View {
        let p = session.project
        let hasVideo = session.info?.hasVideo == true
        VStack(alignment: .leading, spacing: 10) {
            if session.isProject {
                Label(L("The whole timeline is exported as one new file. Pieces from different videos are decoded and written again, so the exact mode is used."), systemImage: "film.stack").font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !session.isProject { GroupBox(L("What to export")) {
                Picker("", selection: Binding(get: { d.scope }, set: { v in set { $0.scope = v } })) {
                    Text(L("The whole video")).tag(ExportScope.whole)
                    Text(L("From In to Out")).tag(ExportScope.inOut)
                    Text(LF("Each clip as its own file (%d)", p.selections.items.count)).tag(ExportScope.allClips)
                    Text(LF("Selected clips as separate files (%d)", session.selectedClipIDs.count)).tag(ExportScope.selectedClips)
                    Text(L("All clips joined into one file")).tag(ExportScope.clipsJoined)
                }.pickerStyle(.radioGroup).labelsHidden().padding(4)
            } }

            GroupBox(L("Save")) {
                VStack(alignment: .leading, spacing: 6) {
                    if !session.isProject { Picker("", selection: Binding(get: { d.saveKind }, set: { v in set { $0.saveKind = v } })) {
                        Text(L("Save as a new copy (original untouched)")).tag(SaveKind.newCopy)
                        Text(L("Apply changes to the original…")).tag(SaveKind.replaceOriginal)
                    }.pickerStyle(.radioGroup).labelsHidden() }
                    if d.saveKind == .replaceOriginal, !session.isProject {
                        Label(replaceHint(), systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                    }
                    if d.saveKind == .newCopy || session.isProject {
                        TextField(L("File name"), text: Binding(get: { d.name }, set: { v in set { $0.name = v } }), prompt: Text(session.isProject ? session.project.name : (session.sourceURL?.deletingPathExtension().lastPathComponent ?? "") + session.env.prefs.copySuffix))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Text(folderPath()).font(.caption).lineLimit(1).truncationMode(.head).foregroundColor(.secondary)
                            Spacer()
                            Button(L("Choose Folder…")) { chooseFolder() }
                        }
                        Text(L("An existing file is never overwritten: a number is added to the name instead.")).font(.caption).foregroundColor(.secondary)
                    }
                }.padding(4)
            }

            if hasVideo {
                GroupBox(L("Quality")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !session.isProject { Picker(L("Cut"), selection: opt({ $0.mode }, { $0.mode = $1 })) {
                            Text(L("Exact (re-encodes)")).tag(CutMode.exact)
                            Text(L("Fast (copies the video)")).tag(CutMode.fast)
                        }.pickerStyle(.segmented) }
                        if d.options.mode == .fast, !session.isProject {
                            Text(session.canUseFastCut()
                                 ? L("Fast cut keeps the original picture quality, but the file also holds the frames from the keyframe before each cut, hidden by an edit list. Some players may show them.")
                                 : L("Fast cut is not available while the picture, sound, text or burned-in subtitles are edited."))
                                .font(.caption).foregroundColor(session.canUseFastCut() ? .secondary : .orange).fixedSize(horizontal: false, vertical: true)
                        }
                        Picker(L("Format"), selection: opt({ $0.container }, { $0.container = $1 })) { ForEach(OutputContainer.allCases, id: \.self) { Text(".\($0.rawValue)").tag($0) } }
                        if d.options.mode == .exact || session.isProject {
                            Picker(L("Codec"), selection: opt({ $0.codec }, { $0.codec = $1 })) { Text("H.264").tag(VideoCodecChoice.h264); Text("HEVC (H.265)").tag(VideoCodecChoice.hevc) }
                            Picker(L("Quality"), selection: opt({ $0.quality }, { $0.quality = $1 })) { Text(L("High")).tag(QualityLevel.high); Text(L("Medium")).tag(QualityLevel.medium); Text(L("Small file")).tag(QualityLevel.small) }
                            Picker(L("Size"), selection: opt({ $0.resolution }, { $0.resolution = $1 })) {
                                Text(L("Same as source")).tag(ResolutionLimit.source); Text("2160p").tag(ResolutionLimit.p2160); Text("1080p").tag(ResolutionLimit.p1080); Text("720p").tag(ResolutionLimit.p720); Text("480p").tag(ResolutionLimit.p480)
                            }
                        }
                        Toggle(L("Include sound"), isOn: opt({ $0.includeAudio }, { $0.includeAudio = $1 })).disabled(session.info?.hasAudio != true)
                    }.padding(4)
                }
            }

            ForEach(warnings(), id: \.self) { w in Label(w, systemImage: "info.circle").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let est = estimate() { Text(est).font(.caption).foregroundColor(.secondary) }

            HStack {
                Button(L("Export")) { run() }.keyboardShortcut(.defaultAction).controlSize(.large)
                Button(L("Show Queue")) { QueueWindow.shared.show() }
            }
        }
    }

    private func folderPath() -> String { d.folder ?? session.env.prefs.lastExportFolder ?? (session.sourceURL.map { PathUtil.directory(of: $0.path) } ?? NSHomeDirectory()) }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { set { $0.folder = u.path }; session.env.prefs.lastExportFolder = u.path }
    }

    private func replaceHint() -> String {
        if !session.project.canReplaceOriginal { return L("A project with several videos must be saved as a new file.") }
        if session.sourceChangedExternally { return L("The original was changed by another app, so it cannot be replaced.") }
        let backup = session.env.prefs.backupBeforeReplace
        return backup ? L("The original will be replaced after the new file is checked. A backup copy is kept first (change this in Settings).")
                      : L("The original will be replaced and NO backup will be kept (Settings).")
    }

    private func estimate() -> String? {
        guard let info = session.info else { return nil }
        let secs = session.spans(for: d.scope).reduce(0.0) { $0 + $1.duration.seconds }
        guard secs > 0 else { return nil }
        let bytes = Int64(d.options.estimatedBytesPerSecond(source: info) * secs)
        return LF("About %@ for %@ of video (an estimate: the real size varies).", Format.bytes(bytes), Format.duration(MediaTime(seconds: secs)))
    }

    private func warnings() -> [String] {
        guard let info = session.info else { return [] }
        let all = session.isProject ? session.project.sources.compactMap(\.info) : [info]
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

    private func run() {
        var req = ExportRequest(scope: d.scope, saveKind: d.saveKind, options: d.options, folder: folderPath(), baseName: d.name.isEmpty ? nil : d.name)
        if session.isProject { req.saveKind = .newCopy; req.options.mode = .exact }
        if !session.isProject, d.scope == .inOut, session.inPoint == nil, session.outPoint == nil { session.flash(L("Set In and Out first, or export the whole video."), error: true); return }
        if req.saveKind == .replaceOriginal, !confirmReplace(&req) { return }
        do {
            let (jobs, batch) = try session.planExport(req)
            if req.saveKind == .replaceOriginal { jobs.forEach { session.pendingReplaceJobs.insert($0.id) } }
            session.env.exports.enqueue(jobs)
            if !batch.renamedForConflict.isEmpty { session.flash(L("Some names were already taken, so numbers were added.")) }
            else { session.flash(jobs.count == 1 ? L("Export started.") : LF("%d exports started.", jobs.count)) }
            QueueWindow.shared.show()
        } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
    }

    /// The explicit confirmation required before an original can be replaced (design section 6).
    private func confirmReplace(_ req: inout ExportRequest) -> Bool {
        guard let url = session.sourceURL else { return false }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = LF("Replace “%@” with the edited video?", url.lastPathComponent)
        let backup = session.backupFolder()
        a.informativeText = LF("File: %@\n\nThe original will be replaced only after the new video is exported and checked. If anything goes wrong the original stays as it is.", url.path)
            + "\n\n" + (backup.map { LF("A backup copy of the original is saved first in:\n%@\n(about %@)", $0, Format.bytes(session.info?.fileSize ?? 0)) } ?? L("No backup will be kept."))
            + "\n\n" + L("Undo does not bring back the old file after it is replaced. Use the backup for that.")
        a.addButton(withTitle: L("Save a Copy Instead"))
        a.addButton(withTitle: L("Replace Original"))
        a.addButton(withTitle: L("Cancel"))
        a.buttons[1].hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn: req.saveKind = .newCopy; set { $0.saveKind = .newCopy }; return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}
