import AVFoundation
import AppKit
import Combine
import MacPlayerCore
import MacPlayerMedia

struct Notice: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isError: Bool
}

enum ExportScope: Equatable { case whole, inOut, allClips, selectedClips, clipsJoined }
enum SaveKind: Equatable { case newCopy, replaceOriginal }

struct ExportDraft {
    var scope: ExportScope = .whole
    var saveKind: SaveKind = .newCopy
    var options = ExportOptions(mode: .exact)
    var name = ""
    var folder: String?
}

struct ExportRequest {
    var scope: ExportScope
    var saveKind: SaveKind
    var options: ExportOptions
    var folder: String
    /// File name without extension for one-file exports. nil = source name + the copy suffix.
    var baseName: String?
    var overwrite = false
}

enum PlanError: Error, CustomStringConvertible {
    case noSource, nothingToExport, replaceNotPossible(String), fastNotPossible, projectNeedsExact, missingMedia([String]), issues([BatchIssue])
    var description: String {
        switch self {
        case .noSource: return L("No video is open.")
        case .nothingToExport: return L("There is nothing to export. Add clips with I and O first.")
        case .replaceNotPossible(let why): return why
        case .fastNotPossible: return L("Fast cut cannot be used with picture, sound, text or subtitle edits. Choose the exact mode.")
        case .projectNeedsExact: return L("Joining clips from a timeline needs the exact mode, because the pieces are decoded and written again.")
        case .missingMedia(let names): return LF("These videos are missing: %@. Relink them first (File ▸ Relink Video…).", names.joined(separator: ", "))
        case .issues(let i):
            return i.map { issue -> String in
                switch issue.kind {
                case .folderMissing: return L("The destination folder does not exist.")
                case .folderNotWritable: return L("MacPlayer cannot write to the destination folder.")
                case .notEnoughSpace(let n, let a): return LF("Not enough free space: about %@ needed, %@ available.", Format.bytes(n), Format.bytes(a))
                case .destinationIsSource: return L("The destination is the original file.")
                case .emptySelection: return L("There is nothing to export.")
                }
            }.joined(separator: "\n")
        }
    }
}

/// One open video (or project): its edit state, the player, undo history, autosave and every action on them.
@MainActor
final class EditorSession: NSObject, ObservableObject {
    let env = AppEnvironment.shared!
    let player = PlayerController()

    @Published var history: History<Project>
    @Published var info: MediaInfo?
    @Published var sourceURL: URL?
    @Published var inPoint: MediaTime?
    @Published var outPoint: MediaTime?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var notice: Notice?
    @Published var isDirty = false
    @Published private(set) var projectPath: String?
    @Published var peaks: [Float] = []
    @Published var sourceChangedExternally = false
    /// Every source of the project (project mode has several): where it is now, and what is known about it.
    @Published var sourceURLs: [UUID: URL] = [:]
    @Published var infos: [UUID: MediaInfo] = [:]
    @Published var peaksBySource: [UUID: [Float]] = [:]
    /// The layer (video or picture over the main timeline) being edited.
    @Published var selectedOverlayID: UUID?
    /// The sound (music, voice-over, effect) being edited, and the microphone recorder that makes voice-overs.
    @Published var selectedSoundID: UUID?
    @Published var denoiseProgress: [DenoiseTarget: Double] = [:]
    @Published var fxProgress: [DenoiseTarget: Double] = [:]
    let recorder = VoiceRecorder()
    var voiceStart = MediaTime.zero
    /// True when the preview that is playing is drawn by the compositor, which can take new filter settings without being built again.
    var previewHasCompositor = false
    @Published var recordWithPlayback = true
    /// A photo instead of a video: the picture as drawn now (screen size), the copy it is drawn from, and how it is being looked at.
    @Published var photoImage: CGImage?
    /// Colour tool: the picture is shown without its colour changes, for as long as a button is held.
    @Published var colorCompare = false
    var photoBase: PhotoLoader.Loaded?
    var photoRenderGeneration = 0
    /// 1 = the whole picture fits the window; larger zooms in.
    @Published var photoZoom: CGFloat = 1
    @Published var photoOffset = CGSize.zero
    @Published var photoDraft = PhotoSaveDraft()
    /// The Picture tool of a photo shows a frame to drag. While it does, the picture is drawn whole (turned and flipped, but not cut), so the frame
    /// can be seen on all of it; `photoCropRatio` is the shape the frame is kept in (width / height in pixels), nil for free.
    @Published var photoCropAdjusting = true
    @Published var photoCropEditing = false
    @Published var photoCropRatio: Double?
    /// An animated picture (GIF, animated PNG or WebP): when its frames change, the frames as drawn now (with the edit), and whether they are playing.
    var photoAnimation: PhotoLoader.Animation?
    var photoFrameBases: [CIImage] = []
    @Published var photoFrames: [CGImage] = []
    @Published var photoPlaying = true
    /// Text the user typed in the "clip name" field before pressing add (kept with the session).
    /// MACPLAYER_START_TAB=effects opens the editing panel on that tool (a development aid for looking at a panel).
    @Published var activeTool: InspectorTab = ProcessInfo.processInfo.environment["MACPLAYER_START_TAB"].flatMap(InspectorTab.init(rawValue:)) ?? .clips
    /// What the Export tab is set to; kept here so it survives switching tabs.
    @Published var draft = ExportDraft()
    /// Jobs that replace this session's original; when one succeeds the project starts again from the new file.
    var pendingReplaceJobs = Set<UUID>()

    var project: Project { history.present }
    var frameRate: FrameRate { info?.frameRateForStepping ?? FrameRate(numerator: 30, denominator: 1) }
    var isProject: Bool { project.mode == .project }
    var duration: MediaTime { isProject ? project.timelineDuration : (info?.duration ?? player.duration) }
    /// Sources whose file cannot be found. Their clips are skipped in the preview and block the export.
    var missingSourceIDs: Set<UUID> { Set(project.sources.map(\.id)).subtracting(sourceURLs.keys) }

    private var autosave = AutosaveSchedule()
    private var autosaveTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var positionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Opening

    static func open(url: URL) async throws -> EditorSession {
        if ImageFiles.isCandidate(url.path) { return try await openPhoto(url: url) }
        let info = try await MediaProbe.probe(url: url)
        guard info.isPlayable || info.isExportable else { throw MediaProbeError.unreadable(L("This format is not supported on this Mac.")) }
        let fs = AppEnvironment.shared.fs
        let src = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? fs.fingerprint(url.path), info: info)
        let project = Project(name: url.deletingPathExtension().lastPathComponent, mode: .quick, sources: [src])
        let s = EditorSession(project: project, projectPath: nil)
        await s.attach(url: url, info: info, restorePosition: true)
        return s
    }

    static func openProject(path: String) async throws -> EditorSession {
        let env = AppEnvironment.shared!
        let project = try env.projectStore.load(path: path)
        let s = EditorSession(project: project, projectPath: path)
        guard let src = project.sources.first else { throw ProjectError.corrupted(L("The project has no video.")) }
        if project.mode == .project {
            await s.resolveSources()
            await s.loadPlayer(at: project.playhead)
            s.player.pause()
            s.selectedClipIDs = project.activeClipID.map { [$0] } ?? []
            return s
        }
        var url = URL(fileURLWithPath: src.path)
        if !env.fs.exists(url.path), let moved = Bookmarks.resolve(src.bookmark) { url = moved }
        if !env.fs.exists(url.path) {
            s.notice = Notice(text: LF(ImageFiles.isCandidate(url.path) ? "The photo “%@” was not found. Use File ▸ Relink Video… to point to it." : "The video “%@” was not found. Use File ▸ Relink Video… to point to it.", url.lastPathComponent), isError: true)
            s.isDirty = false
            return s
        }
        if ImageFiles.isCandidate(url.path) {
            try await s.attachPhoto(url: url, info: try PhotoLoader.info(url: url))
            return s
        }
        let info = try await MediaProbe.probe(url: url)
        await s.attach(url: url, info: info, restorePosition: false)
        s.player.pause()
        await s.player.seek(to: project.playhead)
        return s
    }

    /// A project rebuilt from its crash copy: the edits are back, and it counts as unsaved until the user saves.
    static func restore(project: Project, savedPath: String?) async -> EditorSession {
        let env = AppEnvironment.shared!
        let s = EditorSession(project: project, projectPath: savedPath)
        guard let src = project.sources.first else { return s }
        if project.mode == .project {
            await s.resolveSources(); await s.loadPlayer(at: project.playhead); s.player.pause(); s.isDirty = true
            return s
        }
        var url = URL(fileURLWithPath: src.path)
        if !env.fs.exists(url.path), let moved = Bookmarks.resolve(src.bookmark) { url = moved }
        if env.fs.exists(url.path), ImageFiles.isCandidate(url.path), let info = try? PhotoLoader.info(url: url) {
            try? await s.attachPhoto(url: url, info: info)
        } else if env.fs.exists(url.path), let info = try? await MediaProbe.probe(url: url) {
            await s.attach(url: url, info: info, restorePosition: false)
            s.player.pause()
            await s.player.seek(to: project.playhead)
        } else {
            s.notice = Notice(text: LF(ImageFiles.isCandidate(url.path) ? "The photo “%@” was not found. Use File ▸ Relink Video… to point to it." : "The video “%@” was not found. Use File ▸ Relink Video… to point to it.", url.lastPathComponent), isError: true)
        }
        s.isDirty = true
        return s
    }

    /// Points the project at a different file for its video (moved, renamed or replaced). Clips keep their times.
    func relink(to url: URL) async {
        do {
            let isPicture = ImageFiles.isCandidate(url.path)
            let new = isPicture ? try PhotoLoader.info(url: url) : try await MediaProbe.probe(url: url)
            edit("Relink video", refreshPreview: false) { p in
                guard !p.sources.isEmpty else { return }
                p.sources[0].path = url.path; p.sources[0].bookmark = Bookmarks.make(url)
                p.sources[0].fingerprint = try? env.fs.fingerprint(url.path); p.sources[0].info = new
            }
            if isPicture { try await attachPhoto(url: url, info: new) } else { await attach(url: url, info: new, restorePosition: false) }
            sourceChangedExternally = false
            flash(isPicture ? L("Photo relinked.") : L("Video relinked. Check that the timing of your clips is still right."))
        } catch { flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
    }

    init(project: Project, projectPath: String?) {
        history = History(project)
        self.projectPath = projectPath
        super.init()
        player.preservePitch = env.prefs.preserveVoicePitch
        player.$currentTime.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        $selectedClipIDs.dropFirst().sink { [weak self] ids in self?.syncActiveClip(ids) }.store(in: &cancellables)
        $activeTool.dropFirst().sink { [weak self] tool in self?.updateCropEditing(tool: tool) }.store(in: &cancellables)
        $photoCropAdjusting.dropFirst().sink { [weak self] on in self?.updateCropEditing(adjusting: on) }.store(in: &cancellables)
        startTimers()
    }

    func attach(url: URL, info: MediaInfo, restorePosition: Bool) async {
        sourceURL = url
        self.info = info
        player.frameStepper = FrameStepper(url: url)
        if let id = project.sources.first?.id { sourceURLs[id] = url; infos[id] = info }
        if project.sources.first?.info != info {
            mutateQuietly { $0.sources[0].info = info }
        }
        var start: MediaTime?
        if restorePosition, env.prefs.rememberPositions, env.prefs.resumeBehavior != .never,
           let s = env.positions.position(for: PositionStore.key(path: url.path, size: info.fileSize)) { start = MediaTime(seconds: s) }
        await loadPlayer(at: start)
        loadWaveform()
        if !info.hasVideo { notice = Notice(text: L("This file has audio only."), isError: false) }
    }

    /// Changes the model without making an undo step or marking the project as edited.
    func mutateQuietly(_ f: (inout Project) -> Void) { var p = project; f(&p); history.reset(p) }

    // MARK: Preview

    /// The preview is the edited composition, built by the same code as the export, so what is seen is what is written.
    private func previewNeeded(_ p: Project) -> Bool {
        p.look.changesPicture || !p.overlays.isEmpty || !p.subtitles.cues.isEmpty || !p.soundClips.isEmpty || p.audio.denoise != nil || p.audio.fx != nil
    }

    /// The preview plays the video's own volume through the player; only noise reduction has to be in the sound itself.
    private func audioOnlyDenoise(_ a: AudioSettings) -> AudioSettings { var n = AudioSettings(); n.denoise = a.denoise; n.fx = a.fx; return n }

    /// The preview is drawn no taller than this. A 4K video drawn at full size with a filter on it played at about 0.6x speed; the export is not limited.
    static let previewMaxHeight = 1080

    func loadPlayer(at start: MediaTime?) async {
        if isPhoto { renderPhoto(); return }
        let generation = player.seekGeneration
        EffectsLive.clear(); ColorLive.clear(); colorCompare = false
        if isProject { await loadProjectPreview(at: start, since: generation); return }
        guard let url = sourceURL, let info else { return }
        var built: BuiltRender?
        if previewNeeded(project), info.hasVideo {
            var look = project.look; look.speed = 1 // speed is applied by the export, not the preview
            built = try? await CompositionBuilder.build(
                pieces: [RenderPiece(sourceURL: url, span: TimeSpan(start: .zero, end: info.duration), look: look, audio: audioOnlyDenoise(project.audio), liveKey: project.id)],
                overlays: project.overlays, cues: project.subtitles.cues, subtitleStyle: project.subtitles.style,
                maxHeight: Self.previewMaxHeight, includeAudio: true, soundClips: resolvedSounds(), frameAccurate: false)
        }
        previewHasCompositor = built?.videoComposition != nil
        await player.load(url: url, preview: built, at: start, since: generation)
    }

    /// Rebuilds the preview shortly after an edit, keeping the playhead and play state.
    func schedulePreviewRefresh() {
        if isPhoto { renderPhoto(); return }          // a picture is drawn again at once
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            let was = player.isPlaying, at = player.effectiveTime
            await loadPlayer(at: at)
            if was { player.play() }
        }
    }

    func loadWaveform() {
        waveformTask?.cancel()
        peaks = []
        guard let url = sourceURL, info?.hasAudio == true else { return }
        waveformTask = Task {
            let p = try? await Waveform.peaks(url: url)
            if !Task.isCancelled { peaks = p ?? [] }
        }
    }

    // MARK: Editing

    /// All changes go through here: one undo step each, autosave scheduled, preview refreshed when it shows the change.
    func edit(_ label: String, coalesce: String? = nil, refreshPreview: Bool = true, _ change: (inout Project) -> Void) {
        var p = project
        change(&p)
        guard p != project else { return }
        history.commit(p, label: label, coalesce: coalesce)
        markChanged()
        if refreshPreview { schedulePreviewRefresh() }
    }

    func endCoalescing() { var h = history; h.endCoalescing(); history = h }

    func undo() { LayerLive.clear(); var h = history; if let l = h.undo() { history = h; markChanged(); schedulePreviewRefresh(); flash(LF("Undid “%@”", L(l))) } }
    func redo() { LayerLive.clear(); var h = history; if let l = h.redo() { history = h; markChanged(); schedulePreviewRefresh(); flash(LF("Redid “%@”", L(l))) } }
    var undoTitle: String { history.undoLabel.map { LF("Undo %@", L($0)) } ?? L("Undo") }
    var redoTitle: String { history.redoLabel.map { LF("Redo %@", L($0)) } ?? L("Redo") }

    private func markChanged() {
        isDirty = true
        if env.prefs.autosaveEnabled { autosave.noteChange(at: Date()) }
        objectWillChange.send()
    }

    /// A short message under the picture. Plain messages fade after a few seconds; errors stay until dismissed.
    func flash(_ text: String, error: Bool = false) {
        let n = Notice(text: text, isError: error)
        notice = n
        guard !error else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.notice?.id == n.id { self?.notice = nil }
        }
    }

    // MARK: In / Out, clips, markers

    /// The time of the frame under the playhead (the real presentation time of that frame).
    func currentFrameTime() async -> MediaTime {
        guard !isProject, let url = sourceURL else { return player.currentTime }
        let t = player.currentTime
        if let f = try? await FrameLocator.frame(url: url, at: t + MediaTime(value: 1, timescale: 6000)) { return f.time }
        return t
    }

    func markIn() { Task { let t = await currentFrameTime(); inPoint = t; if let o = outPoint, o <= t { outPoint = nil } } }
    func markOut() { Task { let t = await currentFrameTime(); outPoint = t; if let i = inPoint, i >= t { inPoint = nil } } }
    func clearInOut() { inPoint = nil; outPoint = nil }

    /// Turns In/Out into a named clip and clears them, ready for the next one.
    func addClipFromInOut(name: String? = nil) {
        let a = inPoint ?? .zero, b = outPoint ?? duration
        var new: ClipSelection?
        edit("Add clip", refreshPreview: false) { p in new = p.selections.add(start: a, end: b, name: name, duration: info?.duration) }
        if let c = new { selectedClipIDs = [c.id]; inPoint = nil; outPoint = nil; activeTool = .clips } else { flash(L("Set In and Out first (I and O)."), error: true) }
    }

    func addMarker() {
        Task {
            let t = await currentFrameTime()
            edit("Add marker", refreshPreview: false) { $0.markers.append(Marker(time: t, name: LF("Marker %d", $0.markers.count + 1))) }
        }
    }

    func jumpToMarker(forward: Bool) {
        let times = project.markers.map(\.time).sorted()
        let now = player.currentTime
        let target = forward ? times.first { $0 > now + MediaTime(value: 1, timescale: 30) } : times.last { $0 < now - MediaTime(value: 1, timescale: 30) }
        if let t = target { Task { await player.seek(to: t) } }
    }

    func removeClips(_ ids: Set<UUID>) {
        if isProject { deleteTimelineClips(ids); return }
        edit("Delete clip", refreshPreview: false) { $0.selections.remove(ids) }; selectedClipIDs.subtract(ids)
    }

    func previewClips() {
        let spans = project.selections.effective().filter { selectedClipIDs.isEmpty || selectedClipIDs.contains($0.id) }.map(\.span)
        if spans.isEmpty { flash(L("There are no clips to preview."), error: true) } else { player.playSequence(spans) }
    }

    func seekToClip(_ id: UUID) {
        if let c = project.selections.items.first(where: { $0.id == id }) { Task { await player.seek(to: c.start) } }
    }

    // MARK: Source state

    /// Called when the window comes to the front: has another app changed or removed the video?
    func refreshSourceState() {
        for src in project.sources {
            guard let stored = src.fingerprint, let url = sourceURLs[src.id] else { continue }
            guard let now = try? env.fs.fingerprint(url.path) else {
                sourceChangedExternally = true
                flash(LF("“%@” is no longer at its location.", url.lastPathComponent), error: true); return
            }
            if now != stored, !sourceChangedExternally {
                sourceChangedExternally = true
                flash(L("Another app changed this video after it was opened. Saving a copy is safe; replacing the original is blocked."), error: true)
            }
        }
    }

    // MARK: Project files

    func saveProject(to path: String) {
        var p = project
        p.playhead = player.currentTime
        do {
            try env.projectStore.save(p, to: path)
            projectPath = path
            isDirty = false
            autosave.didSave()
            flash(isPhoto ? L("Project saved. The photo file was not changed.") : L("Project saved. The video file was not changed."))
        } catch { flash(LF("The project could not be saved: %@", error.localizedDescription), error: true) }
    }

    // MARK: Autosave, position memory

    private func startTimers() {
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveTick() }
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
    }

    private func autosaveTick() {
        guard env.prefs.autosaveEnabled, autosave.isDue(at: Date()) else { return }
        autosave.didSave()
        var p = project
        p.playhead = player.currentTime
        let store = env.projectStore, saved = projectPath
        // Off the main thread, on a copy: editing is never blocked by a save.
        Task.detached(priority: .utility) { try? store.autosave(p, savedPath: saved); try? store.takeSnapshot(p) }
    }

    func rememberPosition() {
        guard env.prefs.rememberPositions, !isProject, !isPhoto, let url = sourceURL, let info else { return }
        env.positions.remember(PositionStore.key(path: url.path, size: info.fileSize), seconds: player.currentTime.seconds, duration: info.duration.seconds)
        env.positions.flush()
    }

    /// Window closing: stop timers, remember where the viewer stopped. A clean close removes the crash copy.
    func close(discardRecovery: Bool) {
        autosaveTimer?.invalidate(); positionTimer?.invalidate()
        previewTask?.cancel(); waveformTask?.cancel()
        rememberPosition()
        player.pause()
        if discardRecovery { env.projectStore.clearAutosave(projectID: project.id) }
    }

    // MARK: Exporting

    var estimatedDuration: MediaTime { info?.duration ?? .zero }

    func spans(for scope: ExportScope) -> [ClipSelection] {
        if isProject { return [ClipSelection(name: project.name, start: .zero, end: project.timelineDuration)] }
        let whole = TimeSpan(start: .zero, end: duration)
        switch scope {
        case .whole: return [ClipSelection(name: project.name, start: whole.start, end: whole.end)]
        case .inOut: return [ClipSelection(name: project.name, start: inPoint ?? .zero, end: outPoint ?? duration)]
        case .allClips, .clipsJoined: return project.selections.effective()
        case .selectedClips: return project.selections.effective().filter { selectedClipIDs.contains($0.id) }
        }
    }

    func canUseFastCut() -> Bool { project.allowsFastCut }

    func backupFolder() -> String? {
        guard env.prefs.backupBeforeReplace, let s = sourceURL else { return nil }
        return PathUtil.join(PathUtil.directory(of: s.path), "MacPlayer Backups")
    }

    func planExport(_ r: ExportRequest) throws -> (jobs: [ExportJob], batch: BatchPlan) {
        if isProject { return try planProjectExport(r) }
        guard let url = sourceURL, let info else { throw PlanError.noSource }
        let clips = spans(for: r.scope)
        guard !clips.isEmpty, clips.allSatisfy({ !$0.span.isEmpty }) else { throw PlanError.nothingToExport }
        let missingSounds = project.soundClips.filter { isMissing($0) }.map(\.name)
        if !missingSounds.isEmpty { throw PlanError.missingMedia(missingSounds) }
        var options = r.options
        let p = project
        if options.mode == .fast, !p.allowsFastCut { throw PlanError.fastNotPossible }
        if info.primaryVideo == nil { options.mode = .exact }

        let ext = options.container.fileExtension
        let separate = r.scope == .allClips || r.scope == .selectedClips
        var target: (String) -> SaveTarget = { .newCopy(path: $0, overwrite: r.overwrite) }
        var folder = r.folder

        if r.saveKind == .replaceOriginal {
            guard p.canReplaceOriginal else { throw PlanError.replaceNotPossible(L("A project with several videos must be saved as a new file.")) }
            guard r.scope == .whole || r.scope == .inOut else { throw PlanError.replaceNotPossible(L("Replacing the original works on one video at a time. Save the clips as copies instead.")) }
            guard !sourceChangedExternally else { throw PlanError.replaceNotPossible(L("The original was changed by another app. Replacing it is blocked; save a copy instead.")) }
            guard let fp = p.sources.first?.fingerprint else { throw PlanError.replaceNotPossible(L("The original cannot be checked, so it will not be replaced.")) }
            guard ext == info.fileExtension || (ext == "mp4" && info.fileExtension == "mp4") else {
                throw PlanError.replaceNotPossible(LF("Replacing the original would change “.%@” to “.%@”. Save a copy instead.", info.fileExtension, ext))
            }
            folder = PathUtil.directory(of: url.path)
            let backup = backupFolder()
            target = { _ in .replaceOriginal(path: url.path, expected: fp, backupFolder: backup) }
        }

        let template: NamingTemplate
        var selections = clips
        if separate {
            template = p.namingTemplate
        } else {
            let base = r.baseName ?? (url.deletingPathExtension().lastPathComponent + env.prefs.copySuffix)
            template = NamingTemplate(pattern: "{name}")
            selections = [ClipSelection(name: base, start: clips[0].start, end: clips.last!.end)]
        }
        var batch = BatchPlan.make(selections: selections, sourcePath: url.path, folder: folder, fileExtension: ext, template: template, fs: env.fs,
                                   estimatedBytesPerSecond: options.estimatedBytesPerSecond(source: info))
        if r.saveKind == .replaceOriginal {
            // The replace target is the source itself; the plan's name/conflict logic does not apply.
            batch.issues.removeAll { if case .destinationIsSource = $0.kind { return true }; return false }
        }
        guard batch.canRun else { throw PlanError.issues(batch.issues) }

        let artworkOK = options.container != .mov
        var jobs: [ExportJob] = []
        func recipe(for spans: [TimeSpan]) -> RenderRecipe {
            spans.count == 1
                ? RecipeBuilder.recipe(look: p.look, audio: p.audio, overlays: p.overlays, subtitles: p.subtitles, burnIn: p.subtitles.burnIn, span: spans[0], soundClips: resolvedSounds())
                : RecipeBuilder.joinedRecipe(look: p.look, audio: p.audio, overlays: p.overlays, subtitles: p.subtitles, burnIn: p.subtitles.burnIn, spans: spans, soundClips: resolvedSounds())
        }
        func sidecar(for spans: [TimeSpan]) -> [SubtitleCue] {
            guard !p.subtitles.burnIn else { return [] }
            if spans.count == 1 { return p.subtitles.cues(in: spans[0]) }
            var out: [SubtitleCue] = []; var offset = MediaTime.zero
            for s in spans { for var c in p.subtitles.cues(in: s) { c.start = c.start + offset; c.end = c.end + offset; out.append(c) }; offset = offset + s.duration }
            return out
        }
        func make(label: String, spans: [TimeSpan], path: String, stillTime: MediaTime?, embedTime: MediaTime?) -> ExportJob {
            var rec = recipe(for: spans)
            if p.subtitles.syncOffset != 0 { for i in rec.burnedInCues.indices { rec.burnedInCues[i].start = rec.burnedInCues[i].start + MediaTime(seconds: p.subtitles.syncOffset); rec.burnedInCues[i].end = rec.burnedInCues[i].end + MediaTime(seconds: p.subtitles.syncOffset) } }
            var side = sidecar(for: spans)
            if p.subtitles.syncOffset != 0 { for i in side.indices { side[i].start = side[i].start + MediaTime(seconds: p.subtitles.syncOffset); side[i].end = side[i].end + MediaTime(seconds: p.subtitles.syncOffset) } }
            // A zoom and move animation counts from the start of the video; an exported part starts later, so the animation is shifted to match.
            let pieces = spans.map { s -> JobPiece in
                guard !p.look.motion.isEmpty else { return JobPiece(sourcePath: url.path, span: s) }
                var l = p.look; l.motion = Motion.shifted(l.motion, by: -s.start.seconds)
                return JobPiece(sourcePath: url.path, span: s, look: l)
            }
            return ExportJob(label: label, pieces: pieces, recipe: rec, options: options, target: target(path),
                             thumbnailTime: stillTime, embedArtworkTime: artworkOK ? embedTime : nil, sidecarSubtitles: side)
        }

        if separate {
            for (c, out) in zip(clips, batch.outputs) {
                jobs.append(make(label: c.name, spans: [c.span], path: out.path, stillTime: c.thumbnailTime, embedTime: c.thumbnailTime))
            }
        } else {
            jobs.append(make(label: batch.outputs[0].name, spans: r.scope == .clipsJoined ? clips.map(\.span) : [clips[0].span], path: batch.outputs[0].path,
                             stillTime: p.thumbnails.exportTime, embedTime: p.thumbnails.embedTime))
        }
        return (jobs, batch)
    }

    /// After a successful replace: the file on disk is new, so the project starts again from it. Undo does not
    /// pretend to bring the old file back (design section 6); the backup is the way back.
    func afterReplace(backupPath: String?) async {
        guard let url = sourceURL else { return }
        guard let newInfo = try? await MediaProbe.probe(url: url) else { return }
        let fp = try? env.fs.fingerprint(url.path)
        var p = Project(name: project.name, mode: .quick, sources: [SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: fp, info: newInfo, changedAfterReplace: true)])
        p.id = project.id
        history = History(p)
        info = newInfo
        inPoint = nil; outPoint = nil; selectedClipIDs = []
        sourceChangedExternally = false
        isDirty = false
        await loadPlayer(at: nil)
        loadWaveform()
        flash(backupPath.map { LF("Original replaced. Undo does not restore the old file; the backup is at %@", $0) } ?? L("Original replaced. No backup was kept."))
    }

    // MARK: Thumbnails

    func stillImage(at t: MediaTime, maxSize: CGSize? = nil) async -> CGImage? {
        guard let url = sourceURL else { return nil }
        if isPhoto { return PhotoLoader.thumbnail(url: url, maxSize: maxSize ?? CGSize(width: 720, height: 720)) }
        return try? await FrameGrabber.image(url: url, at: t, accuracy: .exact, maxSize: maxSize)
    }
}

enum InspectorTab: String, CaseIterable { case clips, picture, color, mask, effects, timing, transitions, layers, audio, text, subtitles, thumbnail, export
    /// The tools that make sense for what is open: a photo has no timeline, sound or subtitles.
    static func tabs(forPhoto photo: Bool) -> [InspectorTab] { photo ? [.picture, .color, .mask, .effects, .text, .export] : allCases }
    var title: String {
        switch self {
        case .clips: return L("Clips")
        case .layers: return L("Layers")
        case .picture: return L("Picture")
        case .color: return L("Colour")
        case .mask: return L("Cut-out")
        case .effects: return L("Effects")
        case .timing: return L("Speed")
        case .transitions: return L("Transitions")
        case .audio: return L("Audio")
        case .text: return L("Text")
        case .subtitles: return L("Subtitles")
        case .thumbnail: return L("Thumbnail")
        case .export: return L("Export")
        }
    }
}
