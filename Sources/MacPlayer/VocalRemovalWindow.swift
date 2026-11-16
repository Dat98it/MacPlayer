import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacPlayerCore
import MacPlayerMedia

/// A file-to-file tool: no project or source is edited, including if selection changes while it runs.
@MainActor
final class VocalRemovalWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = VocalRemovalWindow()
    @Published var source: URL?
    @Published private(set) var progress = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var cancelling = false
    @Published private(set) var result: URL?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var closeWhenStopped = false
    private var window: NSWindow?

    func show(source: URL? = nil) {
        if !isRunning, let source { self.source = source; result = nil; error = nil }
        if window == nil {
            let view = NSHostingController(rootView: VocalRemovalView(model: self))
            let w = NSWindow(contentViewController: view)
            w.title = L("Remove vocals")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 420)); w.contentMinSize = NSSize(width: 560, height: 390)
            w.isReleasedWhenClosed = false; w.delegate = self; w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func chooseSource() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .video]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = L("Choose a song or video to save its instrumental audio.")
        if panel.runModal() == .OK, let url = panel.url { source = url; result = nil; error = nil }
    }

    func chooseDestination() {
        guard !isRunning, let source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " - " + L("Instrumental") + ".m4a"
        panel.message = L("Save the music without vocals as a new file. The original stays unchanged.")
        panel.directoryURL = source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let output = panel.url else { return }
        start(to: output)
    }

    /// The same entry point is used by the save button and the in-app self-test.
    func start(to output: URL) {
        guard !isRunning, let source else { return }
        result = nil; error = nil
        if let why = OriginalGuard.problem(writing: output.path) { error = why; return }
        isRunning = true; cancelling = false; progress = 0; result = nil; error = nil; closeWhenStopped = false
        let saver = AppEnvironment.shared.saver
        task = Task { [self] in
            defer {
                task = nil; isRunning = false; cancelling = false
                if closeWhenStopped { window?.orderOut(nil); closeWhenStopped = false }
            }
            do {
                let duration = try await VocalRemover.audioDuration(of: source)
                let model = try VocalRemover.modelLocation()
                let outcome = try await saver.saveCopy(sourcePath: source.path, destination: output.path, overwrite: false,
                    estimatedBytes: Int64(min(duration * 36_000, Double(Int64.max / 2))) + 100_000,
                    produce: { temp in
                        try await VocalRemover.writeInstrumental(source: source, to: URL(fileURLWithPath: temp), modelURL: model) { [weak self] value in
                            Task { @MainActor in
                                guard let self, self.isRunning, !self.cancelling else { return }
                                self.progress = max(self.progress, value * 0.97)
                            }
                        }
                    },
                    verify: { temp in
                        let url = URL(fileURLWithPath: temp)
                        let made = try await MediaProbe.probe(url: url)
                        try Task.checkCancellation()
                        guard made.hasAudio, !made.hasVideo, abs(made.duration.seconds - duration) < 0.15 else { throw SaveError.verificationFailed("audio duration") }
                    })
                progress = 1; result = URL(fileURLWithPath: outcome.finalPath)
            } catch is CancellationError { error = nil }
            catch SaveError.cancelled { error = nil }
            catch { self.error = Task.isCancelled ? nil : Self.message(error) }
        }
    }

    func cancel() { guard isRunning else { return }; cancelling = true; task?.cancel() }

    func cancelAndWait() async {
        let running = task
        cancel()
        await running?.value
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isRunning { closeWhenStopped = true; cancel(); return false }
        return true
    }

    /// Captures just this tool for layout checks, without reading the desktop or moving the mouse.
    func snapshot(to url: URL) {
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? VocalRemover.Failure {
            switch error {
            case .noAudio: return L("This file has no sound to separate.")
            case .invalidDuration: return L("This file's audio duration could not be read.")
            case .destinationExists: return L("A file already exists at this name. Choose another name.")
            case .model: return L("The vocal separation model could not be loaded. Reinstall MacPlayer and try again.")
            default: return L("The sound could not be separated. Try another audio file.")
            }
        }
        if case SaveError.destinationExists = error { return L("A file already exists at this name. Choose another name.") }
        if case SaveError.destinationIsSource = error { return L("Choose a new file name. The original is never overwritten.") }
        return LF("Vocal removal failed: %@", String(describing: error))
    }
}

private struct VocalRemovalView: View {
    @ObservedObject var model: VocalRemovalWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.minus").font(.system(size: 30)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Keep only the music")).font(.title2.weight(.semibold))
                    Text(L("Separate the vocals from a song or video's audio, on this Mac.")).font(.callout).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.source?.lastPathComponent ?? L("No song selected")).lineLimit(2).truncationMode(.middle)
                        .help(model.source?.path ?? "")
                    Spacer()
                    Button(L("Choose File…")) { model.chooseSource() }.disabled(model.isRunning)
                }
                Text(L("The original stays unchanged. Nothing is uploaded.")).font(.caption).foregroundColor(.secondary)
                Text(L("Some vocals or backing instruments may remain or be reduced, depending on the mix.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.isRunning {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.cancelling ? L("Cancelling…") : L("Separating vocals…")).font(.callout)
                    Spacer()
                    Text("\(Int(model.progress * 100))%").font(.callout.monospacedDigit()).foregroundColor(.secondary)
                }
            } else if let result = model.result {
                Label(LF("Saved %@", result.lastPathComponent), systemImage: "checkmark.circle.fill").foregroundColor(.green).lineLimit(2)
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                if let result = model.result, !model.isRunning {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    Button(L("Open")) { (NSApp.delegate as? AppDelegate)?.open(urls: [result]) }
                }
                Spacer()
                if model.isRunning {
                    Button(L("Cancel")) { model.cancel() }.disabled(model.cancelling)
                } else {
                    Button(L("Separate and Save Instrumental…")) { model.chooseDestination() }
                        .buttonStyle(.borderedProminent).disabled(model.source == nil)
                }
            }
        }
        .padding(22).frame(minWidth: 516, minHeight: 346)
    }
}

extension EditorSession {
    var vocalRemovalSource: URL? {
        if let sound = selectedSound, let resolved = resolvedSounds().first(where: { $0.id == sound.id }) { return URL(fileURLWithPath: resolved.path) }
        if isProject, let clip = timingClip, let ref = project.source(clip.sourceID) {
            if let sound = ref.soundOf {
                if FileManager.default.fileExists(atPath: sound) { return URL(fileURLWithPath: sound) }
                if let moved = Bookmarks.resolve(ref.bookmark) { return moved }
            }
            return sourceURLs[clip.sourceID] ?? URL(fileURLWithPath: ref.path)
        }
        return remote == nil ? localFileURL : nil
    }
}

extension AppDelegate {
    @objc func removeVocals(_ sender: Any?) { VocalRemovalWindow.shared.show(source: activeSession?.vocalRemovalSource) }
}
