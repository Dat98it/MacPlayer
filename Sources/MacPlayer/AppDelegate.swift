import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacPlayerCore
import MacPlayerMedia

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    let env = AppEnvironment.shared!
    lazy var playlists = PlaylistModel()
    var controllers: [MainWindowController] = []
    private var settingsWindow: NSWindow?
    private let recentMenu = NSMenu(title: "Open Recent")

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchArgs = CommandLine.arguments
        if launchArgs.contains("--recover-check") { runRecoverCheck(); return }
        if let i = launchArgs.firstIndex(of: "--crash-export"), i + 3 < launchArgs.count { runCrashExport(source: launchArgs[i + 1], outDir: launchArgs[i + 2], mode: launchArgs[i + 3]); return }
        NSApp.mainMenu = buildMenu()
        env.exports.onJobFinished = { [weak self] job in self?.jobFinished(job) }

        // Undo whatever a crash left half-done before anything else touches files.
        let reports = env.saver.recoverInterrupted()
        if !reports.isEmpty { showRecovery(reports) }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            env.playlistsForSelfTest = playlists
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { await SelfTest.run(mediaDir: dir, app: self) }
            return
        }
        if controllers.isEmpty { newWindow() }
        if args.contains("--fullscreen-check") { Task { await SelfTest.fullScreenCheck(app: self) } }
        if args.contains("--effects-check") { Task { await SelfTest.effectsCheck(app: self) } }
        if args.contains("--switch-check") { Task { await SelfTest.switchCheck(app: self) } }
        if let i = args.firstIndex(of: "--report-session"), i + 1 < args.count { startSessionReport(to: args[i + 1]) }
        offerProjectRecovery()
        if !env.exports.restoredJobs.isEmpty { QueueWindow.shared.show() }
        NSApp.activate(ignoringOtherApps: true)
        // Files named on the command line, except the values of the development flags.
        let flagValues = Set(["--sandbox", "--snapshot", "--project-demo", "--selftest", "--report-session"].compactMap { f in args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } })
        for arg in args.dropFirst() where !arg.hasPrefix("--") && !flagValues.contains(arg) && FileManager.default.fileExists(atPath: arg) { open(urls: [URL(fileURLWithPath: arg)]) }
        if let i = args.firstIndex(of: "--project-demo"), i + 1 < args.count {
            // Development aid for screenshots: turns the first file into a project and adds a second video.
            let second = URL(fileURLWithPath: args[i + 1])
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let s = self.activeSession else { return }
                s.makeProject(fromClips: false)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await s.player.seek(to: MediaTime(seconds: 6))
                s.splitAtPlayhead()
                try? await Task.sleep(nanoseconds: 800_000_000)
                await s.addVideos([second])
                await s.player.seek(to: MediaTime(seconds: 2))
                await s.addOverlayVideos([second])
                await s.player.seek(to: MediaTime(seconds: 9))
                await s.addOverlayVideos([second])
                if let c = s.project.overlayClips.first { s.selectedOverlayID = c.id; s.activeTool = .layers; await s.player.seek(to: MediaTime(seconds: 4)) }
            }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { scheduleSnapshot(to: args[i + 1]) }
    }

    /// `--snapshot <png>`: after a few seconds, writes the main window's own contents to a PNG and quits.
    /// Draws the app's own views, so no screen-recording permission is involved and nothing else on screen is captured.
    private func scheduleSnapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--project-demo") ? 12 : 4)) {
            MainActor.assumeIsolated {
                guard let v = self.active?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }

    /// The self-test shows and closes real windows and must not quit when the last one goes.
    var quitWhenLastWindowCloses = true
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { quitWhenLastWindowCloses }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) { open(urls: urls) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CommandLine.arguments.contains("--selftest") { print("(terminate requested; windows: \(NSApp.windows.map { "\($0.title.isEmpty ? "?" : $0.title) visible=\($0.isVisible)" }))") }
        if env.exports.queue.running.count + env.exports.queue.pending.count > 0 {
            let a = NSAlert(); a.messageText = L("Exports are still running.")
            a.informativeText = L("If you quit now they stop, and MacPlayer offers to run them again next time. Files already finished are kept.")
            a.addButton(withTitle: L("Quit")); a.addButton(withTitle: L("Cancel"))
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    private func showRecovery(_ reports: [RecoveryReport]) {
        var lines: [String] = []
        for r in reports {
            switch r.action {
            case .restoredOriginal: lines.append(LF("The original “%@” was restored after an interrupted save.", PathUtil.fileName(of: r.path)))
            case .discardedPartialExport: lines.append(LF("An unfinished export next to “%@” was removed. The original was not changed.", PathUtil.fileName(of: r.path)))
            case .finishedCleanup: break
            case .needsAttention(let m): lines.append(LF("“%@” needs attention: %@", PathUtil.fileName(of: r.path), m))
            }
        }
        guard !lines.isEmpty else { return }
        let a = NSAlert(); a.messageText = L("MacPlayer recovered from an interrupted save."); a.informativeText = lines.joined(separator: "\n"); a.runModal()
    }

    private func offerProjectRecovery() {
        for c in env.projectStore.recoverable() {
            let a = NSAlert()
            a.messageText = LF("Recover “%@”?", c.name)
            a.informativeText = LF("MacPlayer closed unexpectedly. A copy of your edits was autosaved at %@.", DateFormatter.localizedString(from: c.autosavedAt, dateStyle: .medium, timeStyle: .short))
                + (c.savedPath != nil ? "\n" + L("You can also open the last saved version instead.") : "")
            a.addButton(withTitle: L("Recover Autosave"))
            if c.savedPath != nil { a.addButton(withTitle: L("Open Saved Version")) }
            a.addButton(withTitle: L("Discard"))
            let r = a.runModal()
            if r == .alertFirstButtonReturn {
                Task {
                    guard let p = try? env.projectStore.loadAutosave(c) else { return }
                    let s = await EditorSession.restore(project: p, savedPath: c.savedPath)
                    let target: MainWindowController = (active?.session == nil ? active : nil) ?? newWindow()
                    target.setSession(s, fromPlaylist: false)
                }
            } else if c.savedPath != nil, r == .alertSecondButtonReturn, let sp = c.savedPath {
                env.projectStore.clearAutosave(projectID: c.projectID); open(urls: [URL(fileURLWithPath: sp)])
            } else { env.projectStore.clearAutosave(projectID: c.projectID) }
        }
    }

    // MARK: Windows

    @discardableResult
    func newWindow() -> MainWindowController {
        let c = MainWindowController(playlists: playlists)
        controllers.append(c)
        c.showWindow(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self, weak c] _ in
            MainActor.assumeIsolated { self?.controllers.removeAll { $0 === c } }
        }
        return c
    }

    /// For the self-test: registers a window controller that was made without showing it.
    func adopt(_ c: MainWindowController) { controllers.append(c) }
    var allMenuItems: [NSMenuItem] {
        func walk(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(walk) ?? []) } }
        return NSApp.mainMenu.map(walk) ?? []
    }

    var active: MainWindowController? { (NSApp.keyWindow?.windowController as? MainWindowController) ?? controllers.last(where: { $0.session != nil }) ?? controllers.last }
    var activeSession: EditorSession? { active?.session }

    /// Development aid (`--report-session <json>`): writes what the windows hold twice a second, so a script can check
    /// that Finder's "Open With" and double-clicking a file really arrive. Reads only; never part of normal use.
    private func startSessionReport(to path: String) {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let windows: [[String: Any]] = self.controllers.map { c in
                    guard let s = c.session else { return ["hasVideo": false] }
                    return ["hasVideo": true, "isProject": s.isProject, "path": s.sourceURL?.path ?? "", "projectPath": s.projectPath ?? "",
                            "name": s.project.name, "duration": s.info?.duration.seconds ?? 0, "clips": s.project.timeline.count,
                            "playlistItems": self.playlists.playlists.map { $0.items.count }.reduce(0, +)]
                }
                let obj: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "windows": windows, "playlists": self.playlists.playlists.count]
                if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func applyFloating() { controllers.forEach { $0.applyFloating() } }

    // MARK: Opening

    func open(urls: [URL]) {
        let fs = env.fs
        let folders = urls.filter { fs.isDirectory($0.path) }
        let files = urls.filter { !fs.isDirectory($0.path) }
        if !folders.isEmpty || files.filter({ !ProjectFile.isProject($0) }).count > 1 {
            // Several videos or a folder: make them a playlist and play it.
            let pid = playlists.create(name: folders.first?.lastPathComponent)
            playlists.add(urls: folders + files.filter { !ProjectFile.isProject($0) }, to: pid)
            let target = active ?? newWindow()
            playlists.host = target
            playlists.playSelected(pid)
            return
        }
        guard let url = files.first else { return }
        // An empty window is reused; otherwise a new window opens so nothing is lost.
        let target: MainWindowController
        if let a = active, a.session == nil { target = a } else { target = newWindow() }
        Task { await target.open(url: url) }
    }

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .image, UTType(filenameExtension: "macplayer"), UTType(filenameExtension: "macvideo")].compactMap { $0 }
        if p.runModal() == .OK { open(urls: p.urls) }
    }

    @objc func openFolderAsPlaylist(_ sender: Any?) {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true
        p.message = L("Choose a folder of videos. You will see what was found before anything is added.")
        guard p.runModal() == .OK, let u = p.url else { return }
        playlists.host = active ?? newWindow()
        playlists.create(name: u.lastPathComponent)
        playlists.beginAddFolder(u)
    }

    @objc func newPlaylist(_ sender: Any?) { playlists.host = active ?? newWindow(); playlists.create() }
    @objc func newWindowAction(_ sender: Any?) { newWindow() }

    // MARK: Project files

    @discardableResult
    func saveProject(session s: EditorSession, forceDialog: Bool) -> Bool {
        if let p = s.projectPath, !forceDialog { s.saveProject(to: p); return true }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "macplayer")!]
        panel.nameFieldStringValue = s.project.name + ".macplayer"
        panel.message = (activeSession?.isPhoto == true) ? L("Saves your edits. The photo file is not changed.") : L("Saves your edits. The video file is not changed.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        s.saveProject(to: url.path)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    @objc func saveDocument(_ sender: Any?) { if let s = activeSession { saveProject(session: s, forceDialog: false) } }
    @objc func saveDocumentAs(_ sender: Any?) { if let s = activeSession { saveProject(session: s, forceDialog: true) } }

    @objc func saveVideo(_ sender: Any?) {
        guard let s = activeSession else { return }
        s.activeTool = .export
        active?.window?.makeKeyAndOrderFront(nil)
        if let c = active, let item = (c.window?.contentViewController as? NSSplitViewController)?.splitViewItems.last, item.isCollapsed { c.toggleInspector() }
    }

    @objc func relinkVideo(_ sender: Any?) {
        guard let s = activeSession else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie, .video, .audio]
        if s.isProject, let id = s.project.sources.first(where: { s.missingSourceIDs.contains($0.id) })?.id {
            p.message = LF("Choose the video to use for “%@”.", PathUtil.fileName(of: s.project.source(id)?.path ?? ""))
            guard p.runModal() == .OK, let u = p.url else { return }
            Task { await s.relinkSource(id, to: u) }
            return
        }
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await s.relink(to: u) }
    }

    @objc func addVideoToProject(_ sender: Any?) {
        guard let s = activeSession else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.message = L("Choose videos to add to the timeline.")
        if p.runModal() == .OK { Task { await s.addVideos(p.urls) } }
    }

    @objc func addOverlayVideo(_ sender: Any?) {
        guard let s = activeSession else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.message = L("Choose a video to lay over the main picture.")
        if p.runModal() == .OK { Task { await s.addOverlayVideos(p.urls) } }
    }

    @objc func addOverlayPicture(_ sender: Any?) {
        guard let s = activeSession else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false; p.allowedContentTypes = [.image]
        p.message = L("Choose a picture (a logo or watermark) to lay over the main picture.")
        if p.runModal() == .OK, let u = p.url { Task { await s.addOverlayPicture(u) } }
    }

    @objc func splitClip(_ sender: Any?) { activeSession?.splitAtPlayhead() }

    /// Files dropped on a window: added to the timeline when a project is open, otherwise opened as usual.
    func dropped(urls: [URL]) {
        let fs = env.fs
        if let s = activeSession, s.isProject, urls.allSatisfy({ !fs.isDirectory($0.path) && !ProjectFile.isProject($0) }) {
            Task { await s.addVideos(urls) }; return
        }
        open(urls: urls)
    }

    // MARK: Menu actions (Edit, Playback, Clips, View)

    @objc func undo(_ sender: Any?) { activeSession?.undo() }
    @objc func redo(_ sender: Any?) { activeSession?.redo() }
    @objc func playPause(_ sender: Any?) { activeSession?.player.togglePlay() }
    @objc func stepBack(_ sender: Any?) { activeSession?.player.step(frames: -1) }
    @objc func stepForward(_ sender: Any?) { activeSession?.player.step(frames: 1) }
    @objc func skipBack(_ sender: Any?) { activeSession?.player.skip(seconds: -env.prefs.skipSeconds) }
    @objc func skipForward(_ sender: Any?) { activeSession?.player.skip(seconds: env.prefs.skipSeconds) }
    @objc func markIn(_ sender: Any?) { activeSession?.markIn() }
    @objc func markOut(_ sender: Any?) { activeSession?.markOut() }
    @objc func addClip(_ sender: Any?) { activeSession?.addClipFromInOut() }
    @objc func addMarker(_ sender: Any?) { activeSession?.addMarker() }
    @objc func previewClips(_ sender: Any?) { activeSession?.previewClips() }
    @objc func nextVideo(_ sender: Any?) { playlists.advance(auto: false) }
    @objc func previousVideo(_ sender: Any?) { playlists.previous() }
    @objc func toggleFullScreen(_ sender: Any?) { active?.window?.toggleFullScreen(nil) }
    @objc func toggleSidebar(_ sender: Any?) { active?.toggleSidebar() }
    @objc func toggleInspector(_ sender: Any?) { active?.toggleInspector() }
    @objc func zoomTimelineIn(_ sender: Any?) { active?.window?.contentView.flatMap { findTimeline($0) }?.zoomIn() }
    @objc func zoomTimelineOut(_ sender: Any?) { active?.window?.contentView.flatMap { findTimeline($0) }?.zoomOut() }
    @objc func showQueue(_ sender: Any?) { QueueWindow.shared.show() }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(env: env)))
            w.title = L("Settings"); w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showShortcuts(_ sender: Any?) { showSettings(nil) }

    private func findTimeline(_ v: NSView) -> TimelineView? {
        if let t = v as? TimelineView { return t }
        for s in v.subviews { if let t = findTimeline(s) { return t } }
        return nil
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = activeSession
        switch item.action {
        case #selector(renameCurrentFile(_:)), #selector(trashCurrentFile(_:)): return s?.sourceURL != nil && s?.isProject == false
        case #selector(undo(_:)): item.title = s?.undoTitle ?? L("Undo"); return s?.history.canUndo ?? false
        case #selector(redo(_:)): item.title = s?.redoTitle ?? L("Redo"); return s?.history.canRedo ?? false
        case #selector(playPause(_:)), #selector(stepBack(_:)), #selector(stepForward(_:)), #selector(skipBack(_:)), #selector(skipForward(_:)),
             #selector(markIn(_:)), #selector(markOut(_:)), #selector(addClip(_:)), #selector(addMarker(_:)), #selector(previewClips(_:)), #selector(splitClip(_:)),
             #selector(addVideoToProject(_:)), #selector(addOverlayVideo(_:)), #selector(addOverlayPicture(_:)), #selector(zoomTimelineIn(_:)), #selector(zoomTimelineOut(_:)):
            return s != nil && s?.isPhoto != true      // a photo has no playback, clips or timeline
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(saveVideo(_:)), #selector(relinkVideo(_:)), #selector(addVideoToProject(_:)), #selector(addOverlayVideo(_:)), #selector(addOverlayPicture(_:)), #selector(splitClip(_:)),
             #selector(playPause(_:)), #selector(stepBack(_:)), #selector(stepForward(_:)), #selector(skipBack(_:)), #selector(skipForward(_:)),
             #selector(markIn(_:)), #selector(markOut(_:)), #selector(addClip(_:)), #selector(addMarker(_:)), #selector(previewClips(_:)),
             #selector(zoomTimelineIn(_:)), #selector(zoomTimelineOut(_:)), #selector(closeVideo(_:)):
            return s != nil
        default: return true
        }
    }

    private func jobFinished(_ job: ExportJob) {
        guard job.state != .queued else { return }
        for c in controllers {
            guard let s = c.session, s.pendingReplaceJobs.contains(job.id) else { continue }
            s.pendingReplaceJobs.remove(job.id)
            if case .succeeded = job.state { let backup = env.exports.results[job.id]?.outcome.backupPath; Task { await s.afterReplace(backupPath: backup) } }
            else if case .failed(let m) = job.state { s.flash(ErrorText.localized(m), error: true) }
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            if !key.isEmpty { i.keyEquivalentModifierMask = mods }
            i.target = target ?? (sel == nil ? nil : self)
        }
        func top(_ title: String) -> NSMenu {
            let m = NSMenu(title: title); let i = main.addItem(withTitle: title, action: nil, keyEquivalent: ""); main.setSubmenu(m, for: i); return m
        }
        let app = top("MacPlayer")
        add(app, L("About MacPlayer"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, L("Settings…"), #selector(showSettings(_:)), ",")
        app.addItem(.separator())
        add(app, L("Hide MacPlayer"), #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, L("Quit MacPlayer"), #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = top(L("File"))
        add(file, L("Open…"), #selector(openDocument(_:)), "o")
        let recent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: ""); recentMenu.delegate = self; file.addItem(recent); file.setSubmenu(recentMenu, for: recent)
        add(file, L("Open Folder as Playlist…"), #selector(openFolderAsPlaylist(_:)), "o", [.command, .shift])
        add(file, L("New Playlist"), #selector(newPlaylist(_:)), "n", [.command, .shift])
        add(file, L("New Window"), #selector(newWindowAction(_:)), "n")
        file.addItem(.separator())
        add(file, L("Save Project"), #selector(saveDocument(_:)), "s")
        add(file, L("Save Project As…"), #selector(saveDocumentAs(_:)), "s", [.command, .shift])
        add(file, L("Save Video…"), #selector(saveVideo(_:)), "s", [.command, .option])
        add(file, L("Rename File…"), #selector(renameCurrentFile(_:)))
        add(file, L("Move File to Trash…"), #selector(trashCurrentFile(_:)))
        add(file, L("Add Video to Project…"), #selector(addVideoToProject(_:)), "a", [.command, .option])
        add(file, L("Add Overlay Video…"), #selector(addOverlayVideo(_:)), "v", [.command, .option])
        add(file, L("Add Overlay Picture…"), #selector(addOverlayPicture(_:)), "p", [.command, .option])
        add(file, L("Relink Video…"), #selector(relinkVideo(_:)))
        file.addItem(.separator())
        add(file, L("Show Export Queue"), #selector(showQueue(_:)), "e", [.command, .option])
        add(file, L("Close Video"), #selector(closeVideo(_:)), "w", [.command, .shift])
        add(file, L("Close"), #selector(NSWindow.performClose(_:)), "w", target: nil)

        let edit = top(L("Edit"))
        add(edit, L("Undo"), #selector(undo(_:)), "z")
        add(edit, L("Redo"), #selector(redo(_:)), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, L("Cut"), #selector(NSText.cut(_:)), "x", target: nil)
        add(edit, L("Copy"), #selector(NSText.copy(_:)), "c", target: nil)
        add(edit, L("Paste"), #selector(NSText.paste(_:)), "v", target: nil)
        add(edit, L("Select All"), #selector(NSText.selectAll(_:)), "a", target: nil)

        let play = top(L("Playback"))
        add(play, L("Play / Pause   Space"), #selector(playPause(_:)))
        add(play, L("Back   ←"), #selector(skipBack(_:)))
        add(play, L("Forward   →"), #selector(skipForward(_:)))
        add(play, L("Previous Frame   ,"), #selector(stepBack(_:)))
        add(play, L("Next Frame   ."), #selector(stepForward(_:)))
        play.addItem(.separator())
        add(play, L("Previous Video"), #selector(previousVideo(_:)), "[", [.command])
        add(play, L("Next Video"), #selector(nextVideo(_:)), "]", [.command])

        let clips = top(L("Clips"))
        add(clips, L("Set In Point   I"), #selector(markIn(_:)))
        add(clips, L("Set Out Point   O"), #selector(markOut(_:)))
        add(clips, L("Add Clip   Return"), #selector(addClip(_:)))
        add(clips, L("Add Marker   M"), #selector(addMarker(_:)))
        add(clips, L("Split Clip at Playhead   S"), #selector(splitClip(_:)))
        clips.addItem(.separator())
        add(clips, L("Preview Clips"), #selector(previewClips(_:)), "p", [.command, .shift])

        let view = top(L("View"))
        add(view, L("Show / Hide Playlists"), #selector(toggleSidebar(_:)), "1", [.command, .control])
        add(view, L("Show / Hide Tools"), #selector(toggleInspector(_:)), "2", [.command, .control])
        add(view, L("Zoom Timeline In"), #selector(zoomTimelineIn(_:)), "+", [.command])
        add(view, L("Zoom Timeline Out"), #selector(zoomTimelineOut(_:)), "-", [.command])
        view.addItem(.separator())
        add(view, L("Enter Full Screen   F"), #selector(toggleFullScreen(_:)), "f", [.command, .control])

        let window = top(L("Window"))
        add(window, L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        NSApp.windowsMenu = window
        let help = top(L("Help"))
        add(help, L("Keyboard Shortcuts"), #selector(showShortcuts(_:)))
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for u in NSDocumentController.shared.recentDocumentURLs {
            let i = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: ""); i.target = self; i.representedObject = u; menu.addItem(i)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: L("No recent files"), action: nil, keyEquivalent: "") }
        else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: L("Clear Recent Files…"), action: #selector(clearRecentFiles(_:)), keyEquivalent: ""); clear.target = self; menu.addItem(clear)
        }
    }

    /// Empties the list of recent files, after asking. Only the list: the video files are never touched.
    @objc func clearRecentFiles(_ sender: Any?) {
        guard !NSDocumentController.shared.recentDocumentURLs.isEmpty else { return }
        let a = NSAlert(); a.messageText = L("Clear the list of recent files?"); a.informativeText = L("Only the list is cleared. The video files are not deleted.")
        a.addButton(withTitle: L("Clear All")); a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn { clearRecentList() }
    }

    func clearRecentList() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }

    /// File ▸ Close Video: closes the video of the active window and returns it to the start screen.
    @objc func closeVideo(_ sender: Any?) { active?.closeVideo() }

    @objc func openRecent(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { open(urls: [u]) } }
}
