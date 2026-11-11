import AVFoundation
import AppKit
import CoreImage
import Combine
import MacPlayerCore
import MacPlayerMedia

struct Notice: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var isError: Bool
}

struct ExportDraft {
    var options = ExportOptions(mode: .exact)
    var name = ""
    var folder: String?
}

struct ExportRequest {
    var options: ExportOptions
    var folder: String
    /// File name without extension. nil = the project's name.
    var baseName: String?
    var overwrite = false
}

enum PlanError: Error, CustomStringConvertible {
    case noSource, nothingToExport, projectNeedsExact, missingMedia([String]), issues([BatchIssue])
    var description: String {
        switch self {
        case .noSource: return L("No video is open.")
        case .nothingToExport: return L("There is nothing to export. Add a video to the timeline first.")
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

/// Where the edits of a project stand on disk. A project in the editor is written into its file on its own (autosave).
enum SaveState: Equatable {
    case saved(Date?)
    case pending
    case saving
    /// The file could not be written; the edits are kept in the recovery copy and saving is tried again.
    case failed(String)
    /// The file was changed by someone else since MacPlayer last wrote it: it is left alone until the person decides.
    case externallyChanged
}

/// One open thing in a window. As a **viewer** (the playlist side): a video or photo that is only watched, never edited or saved.
/// As an **editor**: a project file (video or photo) with its undo history, every editing action, and autosave into the file.
@MainActor
final class EditorSession: NSObject, ObservableObject {
    enum Role { case viewer, editor }

    let env = AppEnvironment.shared!
    let player = PlayerController()
    let role: Role

    @Published var history: History<Project>
    @Published var info: MediaInfo?
    @Published var sourceURL: URL?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var notice: Notice?
    /// The edits are not in the project file yet (they will be, within seconds).
    @Published var isDirty = false
    @Published var saveState = SaveState.saved(nil)
    @Published private(set) var projectPath: String?
    /// Set when the project must not be written (it breaks the rules, e.g. a hand-edited file): it opens to look at only.
    @Published var readOnlyReason: String?
    @Published var peaks: [Float] = []
    /// Every source of the project (project mode has several): where it is now, and what is known about it.
    @Published var sourceURLs: [UUID: URL] = [:]
    @Published var infos: [UUID: MediaInfo] = [:]
    @Published var peaksBySource: [UUID: [Float]] = [:]
    /// The layer (video or picture over the main timeline) being edited.
    @Published var selectedOverlayID: UUID?
    /// The sound (music, voice-over, effect) being edited, and the microphone recorder that makes voice-overs.
    @Published var selectedSoundID: UUID?
    /// The text, shape or sticker (an element on the picture) being edited.
    @Published var selectedTextID: UUID?
    /// Everything selected on the picture (texts, shapes, stickers, layers, logos): one or more; a group comes whole (0.12).
    @Published var canvasSelection: Set<UUID> = []
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
    @Published var photoCropAdjusting = false
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
    /// Logos of a photo project, read once per file.
    var photoLogoCache: [String: CIImage] = [:]

    var project: Project { history.present }
    var frameRate: FrameRate { info?.frameRateForStepping ?? FrameRate(numerator: 30, denominator: 1) }
    var isEditor: Bool { role == .editor }
    /// The editor of a video project (timeline, layers, sounds…).
    var isProject: Bool { role == .editor && project.kind == .video }
    var canEdit: Bool { role == .editor && readOnlyReason == nil }
    var duration: MediaTime { isProject ? project.timelineDuration : (info?.duration ?? player.duration) }
    /// Sources whose file cannot be found. Their clips are skipped in the preview and block the export.
    var missingSourceIDs: Set<UUID> { Set(project.sources.map(\.id)).subtracting(sourceURLs.keys) }

    private var autosave = AutosaveSchedule()
    private var autosaveTimer: Timer?
    private lazy var writer = ProjectFileWriter(store: env.projectStore)
    /// When the next try after a failed save is due.
    private var retryAt: Date?
    private var retryDelay: TimeInterval = 5
    /// Set while the project file is being renamed or moved to the Trash: nothing is written meanwhile.
    var writingPaused = false
    /// Counts changes, so a save that finishes knows whether newer edits are still waiting.
    private var editGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var positionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// A drag on the picture in progress (see `showDraft`): not yet in the project.
    var canvasDraft: Project?
    var frameRefreshQueued = false
    var photoDraftQueued = false
    /// How many times a drag asked the player to draw the frame again (for the self-test).
    var frameRefreshes = 0
    /// How many drags lifted things off the preview (for the self-test).
    var liftRefreshes = 0
    /// The last photo drawing put on screen (a drop waits for the one that has the dropped thing in it).
    var photoShownGeneration = 0
    /// Pictures of logos, read once, for drawing a layer being dragged.
    var liftPictures: [String: CIImage] = [:]
    /// The last arrow-key move of things on the picture (a burst of presses is one undo step).
    var lastNudge = 0.0
    /// When the panels were last told that the playhead moved (see `init`).
    private var lastTimeTick = 0.0

    // MARK: Opening

    /// A video or photo opened to watch (the playlist side). Nothing about it is ever saved.
    static func open(url: URL) async throws -> EditorSession {
        if ImageFiles.isCandidate(url.path) { return try await openPhoto(url: url) }
        let info = try await MediaProbe.probe(url: url)
        guard info.isPlayable || info.isExportable else { throw MediaProbeError.unreadable(L("This format is not supported on this Mac.")) }
        let fs = AppEnvironment.shared.fs
        let src = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? fs.fingerprint(url.path), info: info)
        let project = Project(name: url.deletingPathExtension().lastPathComponent, kind: .video, sources: [src])
        let s = EditorSession(project: project, projectPath: nil, role: .viewer)
        await s.attach(url: url, info: info, restorePosition: true)
        return s
    }

    /// A project file opened in the editor. Old files are upgraded on reading; they are written in the new format at the first save,
    /// after a copy of the old file was kept in the recovery folder.
    static func openProject(path: String, prepared: Project? = nil, fileSchema: Int = Project.currentSchema) async throws -> EditorSession {
        let env = AppEnvironment.shared!
        var schema = fileSchema
        var project: Project
        if let prepared { project = prepared } else { (project, schema) = try env.projectStore.loadDetailed(path: path) }
        let s = EditorSession(project: project, projectPath: path, role: .editor)
        s.writer.begin(path: path, expected: try? env.fs.fingerprint(path), fileSchema: schema, projectID: project.id)
        let broken = ProjectRules.violations(project)
        if !broken.isEmpty { s.readOnlyReason = L("This project file does not follow the rules of a photo project (one photo). It is opened to look at only and is not changed.") }
        await s.loadSources(at: project.playhead)
        if schema < Project.currentSchema || project.pendingQuickUpgrade == true { s.noteUnsaved() }
        return s
    }

    /// Makes the file of a new project at `path` (never over an existing file), with the video or photo already in it when `media`
    /// is given, and opens it in the editor. The media file is only read.
    static func makeProjectFile(kind: ProjectKind, media: URL?, at path: String) async throws -> EditorSession {
        let env = AppEnvironment.shared!
        var p = Project(name: PathUtil.stem(of: path), kind: kind)
        if let url = media {
            if kind == .photo {
                let info = try PhotoLoader.info(url: url)
                p.sources = [SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? env.fs.fingerprint(url.path), info: info)]
            } else {
                let info = try await MediaProbe.probe(url: url)
                guard info.hasVideo else { throw MediaProbeError.unreadable(L("This file has no picture.")) }
                let ref = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? env.fs.fingerprint(url.path), info: info)
                p.sources = [ref]
                let clip = TimelineClip(sourceID: ref.id, sourceStart: .zero, sourceEnd: info.duration, name: url.deletingPathExtension().lastPathComponent)
                p.timeline = [clip]; p.activeClipID = clip.id
            }
        }
        try env.projectStore.create(p, at: path)
        env.projects.register(path: path, opened: true)
        return try await openProject(path: path)
    }

    /// A project rebuilt from its crash copy: the edits are back, and they are written into the project file at once.
    static func restore(project: Project, savedPath: String) async -> EditorSession {
        let env = AppEnvironment.shared!
        let s = EditorSession(project: project, projectPath: savedPath, role: .editor)
        // The file on disk is older than the crash copy, so it is overwritten by the copy (only the project file, never media).
        s.writer.begin(path: savedPath, expected: nil, fileSchema: Project.currentSchema, projectID: project.id, force: true)
        _ = env
        await s.loadSources(at: project.playhead)
        s.noteUnsaved()
        return s
    }

    /// Finds the media of an editor's project and gets the preview ready.
    func loadSources(at playhead: MediaTime) async {
        if project.kind == .video {
            await resolveSources()
            if project.pendingQuickUpgrade == true, let first = project.sources.first, let d = infos[first.id]?.duration {
                mutateQuietly { ProjectUpgrade.finishQuickVideo(&$0, duration: d) }
                noteUnsaved()
            }
            await loadPlayer(at: playhead)
            player.pause()
            selectedClipIDs = project.activeClipID.map { [$0] } ?? []
            return
        }
        // A photo project: none or one photo.
        guard let src = project.sources.first else { return }
        var url = URL(fileURLWithPath: src.path)
        if !env.fs.exists(url.path), let moved = Bookmarks.resolve(src.bookmark) { url = moved }
        guard env.fs.exists(url.path), let info = try? PhotoLoader.info(url: url) else {
            notice = Notice(text: LF("The photo “%@” was not found. Use File ▸ Relink… to point to it.", url.lastPathComponent), isError: true)
            return
        }
        try? await attachPhoto(url: url, info: info)
    }

    /// Points a photo project at the file of its photo again (it was moved or renamed outside MacPlayer).
    func relink(to url: URL) async {
        guard project.kind == .photo, ImageFiles.isCandidate(url.path) else { flash(L("Choose a photo."), error: true); return }
        do {
            let new = try PhotoLoader.info(url: url)
            edit("Relink photo", refreshPreview: false) { p in
                guard !p.sources.isEmpty else { return }
                p.sources[0].path = url.path; p.sources[0].bookmark = Bookmarks.make(url)
                p.sources[0].fingerprint = try? env.fs.fingerprint(url.path); p.sources[0].info = new
            }
            try await attachPhoto(url: url, info: new)
            notice = nil
            flash(L("Photo relinked."))
        } catch { flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
    }

    init(project: Project, projectPath: String?, role: Role) {
        history = History(project)
        self.role = role
        self.projectPath = projectPath
        super.init()
        player.preservePitch = env.prefs.preserveVoicePitch
        // The panels follow the playhead. While the video plays they are told four times a second, not at every frame: redrawing the library,
        // the properties and the bars 30 times a second kept the main thread busy about a third of the time and made the interface stutter
        // (0.12). The timeline and the frames on the picture follow every frame themselves (`player.$currentTime`). A seek or a step is passed on at once.
        player.$currentTime.sink { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.player.isPlaying, now - self.lastTimeTick < 0.25 { return }
            self.lastTimeTick = now
            self.objectWillChange.send()
        }.store(in: &cancellables)
        player.$isPlaying.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
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

    /// The preview is drawn no taller than this. A 4K video drawn at full size with a filter on it played at about 0.6x speed; the export is not limited.
    static let previewMaxHeight = 1080

    /// How many times the preview was built (the self-test checks that playing does not keep rebuilding it).
    private(set) var previewLoads = 0
    /// How long each rebuild of a project's preview took, in seconds (for the self-test).
    var previewBuildTimes: [Double] = []
    /// Why the preview was last asked to rebuild (the edit's label; "undo"/"redo"/"other"), for the self-test.
    var rebuildReasons: [String] = []

    func loadPlayer(at start: MediaTime?) async {
        if isPhoto { renderPhoto(); return }
        previewLoads += 1
        let generation = player.seekGeneration
        EffectsLive.clear(); ColorLive.clear(); TransitionLive.clear(); ElementLive.clear(); colorCompare = false
        if isProject {
            let t0 = Date()
            await loadProjectPreview(at: start, since: generation)
            previewBuildTimes.append(Date().timeIntervalSince(t0))
            return
        }
        // Watching: the file plays as it is.
        guard let url = sourceURL else { return }
        previewHasCompositor = false
        await player.load(url: url, preview: nil, at: start, since: generation)
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
        guard canEdit else { return }
        var p = project
        change(&p)
        guard p != project else { return }
        history.commit(p, label: label, coalesce: coalesce)
        markChanged()
        if refreshPreview { rebuildReasons.append(label); schedulePreviewRefresh() }
    }

    func endCoalescing() { var h = history; h.endCoalescing(); history = h }

    func undo() { guard canEdit else { return }; LayerLive.clear(); var h = history; if let l = h.undo() { history = h; markChanged(); schedulePreviewRefresh(); flash(LF("Undid “%@”", L(l))) } }
    func redo() { guard canEdit else { return }; LayerLive.clear(); var h = history; if let l = h.redo() { history = h; markChanged(); schedulePreviewRefresh(); flash(LF("Redid “%@”", L(l))) } }
    var undoTitle: String { history.undoLabel.map { LF("Undo %@", L($0)) } ?? L("Undo") }
    var redoTitle: String { history.redoLabel.map { LF("Redo %@", L($0)) } ?? L("Redo") }

    private func markChanged() {
        noteUnsaved()
        objectWillChange.send()
    }

    /// Something in the project is not in its file yet: autosave writes it within seconds.
    func noteUnsaved() {
        guard role == .editor, readOnlyReason == nil else { return }
        editGeneration += 1
        isDirty = true
        if case .externallyChanged = saveState {} else { saveState = .pending }
        autosave.noteChange(at: Date())
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

    // MARK: Markers

    func addMarker() {
        let t = player.currentTime
        edit("Add marker", refreshPreview: false) { $0.markers.append(Marker(time: t, name: LF("Marker %d", $0.markers.count + 1))) }
    }

    func jumpToMarker(forward: Bool) {
        let times = project.markers.map(\.time).sorted()
        let now = player.currentTime
        let target = forward ? times.first { $0 > now + MediaTime(value: 1, timescale: 30) } : times.last { $0 < now - MediaTime(value: 1, timescale: 30) }
        if let t = target { Task { await player.seek(to: t) } }
    }

    // MARK: Source state

    /// Called when the window comes to the front: is every file of the project still where it was?
    func refreshSourceState() {
        for src in project.sources {
            guard let url = sourceURLs[src.id] else { continue }
            if !env.fs.exists(url.path) {
                flash(LF("“%@” is no longer at its location.", url.lastPathComponent), error: true); return
            }
        }
    }

    // MARK: Autosave, position memory

    private func startTimers() {
        if role == .editor {
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveTick() }
            }
        }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        }
    }

    private func autosaveTick() {
        guard role == .editor, !writingPaused, readOnlyReason == nil else { return }
        if case .externallyChanged = saveState { return }
        let now = Date()
        if let r = retryAt { guard now >= r else { return }; retryAt = nil; save(); return }
        guard autosave.isDue(at: now) else { return }
        save()
    }

    /// The project as it should be written now.
    private var projectForSaving: Project { var p = project; p.playhead = player.currentTime; return p }

    /// Writes the project into its file in the background (a recovery copy first). Later edits are written by later saves; an older
    /// write never lands after a newer one.
    func save(force: Bool = false) {
        guard role == .editor, readOnlyReason == nil, !writingPaused, let path = projectPath else { return }
        autosave.didSave()
        saveState = .saving
        let p = projectForSaving, gen = editGeneration
        writer.write(p, force: force) { [weak self] result in
            MainActor.assumeIsolated { self?.finishedWrite(result, project: p, path: path, generation: gen) }
        }
    }

    /// Writes now and waits (closing the window, quitting, before the file is renamed or moved). True when the file is up to date.
    @discardableResult
    func saveNow(force: Bool = false) -> Bool {
        guard role == .editor, let path = projectPath else { return true }
        guard readOnlyReason == nil else { return true }
        if case .externallyChanged = saveState, !force { return false }
        autosave.didSave()
        let p = projectForSaving
        let result = writer.writeNow(p, force: force)
        finishedWrite(result, project: p, path: path, generation: editGeneration)
        if case .success = result { return true }
        return false
    }

    private func finishedWrite(_ result: Result<FileFingerprint, Error>, project p: Project, path: String, generation: Int) {
        switch result {
        case .success(let fp):
            retryDelay = 5; retryAt = nil
            if generation != editGeneration {
                saveState = .pending
            } else {
                isDirty = false
                saveState = .saved(Date())
            }
            env.projects.noteSaved(p, path: path, fingerprint: fp)
            // The card in the list gets its picture as soon as there is something to show.
            if !FileManager.default.fileExists(atPath: env.projects.thumbnailURL(p.id).path) { storeThumbnail() }
        case .failure(let error):
            if case ProjectSaveError.changedOnDisk = error {
                saveState = .externallyChanged
                flash(L("The project file was changed outside MacPlayer. Your edits are kept; choose what to do in the bar above the picture."), error: true)
                return
            }
            saveState = .failed(Self.saveErrorText(error, path: path))
            retryAt = Date().addingTimeInterval(retryDelay)
            retryDelay = min(60, retryDelay * 2)
        }
    }

    static func saveErrorText(_ error: Error, path: String) -> String {
        if !Drives.isConnected(path) { return L("The disk with the project is not connected.") }
        switch error {
        case ProjectSaveError.folderMissing: return L("The project's folder is not there any more.")
        case ProjectSaveError.folderNotWritable: return L("The project's folder cannot be written to.")
        case ProjectSaveError.readBackFailed: return L("The saved file could not be read back.")
        default: return (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }

    /// The file on disk was changed by someone else. `keepMine` writes these edits over it (only the project file); otherwise the
    /// project is read again from the disk and these edits are dropped.
    func resolveExternalChange(keepMine: Bool) async {
        guard let path = projectPath else { return }
        if keepMine { saveState = .pending; _ = saveNow(force: true); return }
        do {
            let (p, schema) = try env.projectStore.loadDetailed(path: path)
            history = History(p)
            writer.begin(path: path, expected: try? env.fs.fingerprint(path), fileSchema: schema, projectID: p.id)
            isDirty = false; saveState = .saved(Date()); notice = nil
            await loadSources(at: p.playhead)
        } catch { flash(LF("The project could not be read again: %@", (error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
    }

    /// A small picture of the project for its card in the list of projects (kept in MacPlayer's own folder).
    func storeThumbnail() {
        guard role == .editor else { return }
        let id = project.id, projects = env.projects
        if isPhoto { if let img = photoImage { projects.storeThumbnail(img, projectID: id) }; return }
        guard let clip = project.timeline.first, let url = sourceURLs[clip.sourceID] else { return }
        let t = clip.sourceStart + MediaTime(seconds: min(1, clip.sourceSpan.duration.seconds / 2), timescale: 600)
        Task {
            if let img = try? await FrameGrabber.image(url: url, at: t, accuracy: .nearest, maxSize: CGSize(width: 480, height: 480)) {
                projects.storeThumbnail(img, projectID: id)
            }
        }
    }

    /// The project file now lives at `path` (renamed or moved by MacPlayer).
    func projectFileMoved(to path: String) {
        projectPath = path
        writer.moved(to: path, expected: try? env.fs.fingerprint(path))
    }

    func rememberPosition() {
        guard role == .viewer, env.prefs.rememberPositions, !isPhoto, let url = sourceURL, let info else { return }
        env.positions.remember(PositionStore.key(path: url.path, size: info.fileSize), seconds: player.currentTime.seconds, duration: info.duration.seconds)
        env.positions.flush()
    }

    /// Window closing: stop timers, remember where the viewer stopped. An editor's last edits are written first by the caller
    /// (`saveNow`); the crash copy is removed only when the file is up to date.
    func close() {
        autosaveTimer?.invalidate(); positionTimer?.invalidate()
        previewTask?.cancel(); waveformTask?.cancel()
        rememberPosition()
        player.pause()
        if role == .editor, !isDirty { env.projectStore.clearAutosave(projectID: project.id) }
    }

    // MARK: Exporting

    func planExport(_ r: ExportRequest) throws -> (jobs: [ExportJob], batch: BatchPlan) {
        guard isProject else { throw PlanError.noSource }
        return try planProjectExport(r)
    }

    // MARK: Thumbnails

    func stillImage(at t: MediaTime, maxSize: CGSize? = nil) async -> CGImage? {
        guard let url = sourceURL else { return nil }
        if isPhoto { return PhotoLoader.thumbnail(url: url, maxSize: maxSize ?? CGSize(width: 720, height: 720)) }
        return try? await FrameGrabber.image(url: url, at: t, accuracy: .exact, maxSize: maxSize)
    }
}

enum InspectorTab: String, CaseIterable { case clips, picture, color, mask, effects, timing, transitions, layers, audio, text, subtitles, export
    /// The tools of each kind of project: a photo has no timeline, sound or subtitles (its layers are logos).
    static func tabs(for kind: ProjectKind) -> [InspectorTab] { kind == .photo ? [.picture, .color, .mask, .effects, .layers, .text, .export] : allCases }
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
        case .export: return L("Export")
        }
    }
}
