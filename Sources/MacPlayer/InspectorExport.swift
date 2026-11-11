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

    var body: some View {
        let p = session.project
        let hasVideo = session.info?.hasVideo == true
        VStack(alignment: .leading, spacing: 10) {
            Label(L("The whole timeline is exported as one new video file. The original videos are never changed."), systemImage: "film.stack").font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox(L("Save")) {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        TextField(L("File name"), text: Binding(get: { d.name }, set: { v in set { $0.name = v } }), prompt: Text(session.project.name))
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
                        Picker(L("Format"), selection: opt({ $0.container }, { $0.container = $1 })) { ForEach(OutputContainer.allCases, id: \.self) { Text(".\($0.rawValue)").tag($0) } }
                        Group {
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

    private func run() {
        var req = ExportRequest(options: d.options, folder: folderPath(), baseName: d.name.isEmpty ? nil : d.name)
        req.options.mode = .exact
        do {
            let (jobs, batch) = try session.planExport(req)
            session.env.exports.enqueue(jobs)
            if !batch.renamedForConflict.isEmpty { session.flash(L("Some names were already taken, so numbers were added.")) }
            else { session.flash(jobs.count == 1 ? L("Export started.") : LF("%d exports started.", jobs.count)) }
            QueueWindow.shared.show()
        } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
    }
}
