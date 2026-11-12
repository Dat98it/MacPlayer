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
        if let i = launchArgs.firstIndex(of: "--crash-autosave"), i + 2 < launchArgs.count { runCrashAutosave(source: launchArgs[i + 1], dir: launchArgs[i + 2]); return }
        NSApp.mainMenu = buildMenu()

        // An older MacPlayer may have left a "replace the original" half done: the original is put back before anything else.
        let reports = env.saver.recoverLegacyReplaceJournals()
        if !reports.isEmpty { showRecovery(reports) }
        env.projects.importKnownProjectsOnce(store: env.projectStore, isSandbox: env.isSandbox)
        // Photos fetched from links were only kept while they were shown.
        LinkFetcher.clearCache()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            env.playlistsForSelfTest = playlists
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { await SelfTest.run(mediaDir: dir, app: self) }
            return
        }
        // Opened by Finder for a file (a double-click, Open With): the file's own window is the first one, without a start screen
        // shown first. Should no file arrive after all, the start screen comes a moment later.
        let launchedForFiles = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == false
        if launchedForFiles {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { if self.controllers.isEmpty { self.newWindow() } } }
        } else if controllers.isEmpty { newWindow() }
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
                guard let viewer = self.activeSession, let url = viewer.sourceURL, let w = self.active else { return }
                let path = (self.env.support.appendingPathComponent("demo-\(UUID().uuidString.prefix(4)).macplayer")).path
                guard let s = await self.createProject(kind: .video, from: url, at: path, in: w) else { return }
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
        // MACPLAYER_OPEN_EXPORT (test runs): the picture is of the export window instead.
        if env.isSandbox, ProcessInfo.processInfo.environment["MACPLAYER_OPEN_EXPORT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self.active?.contentController.showExport() } }
            // A sheet does not draw itself into an image: its window number is printed, for `screencapture -l` of that window alone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { if let n = self.active?.window?.attachedSheet?.windowNumber { print("SHEET_WINDOW \(n)"); fflush(stdout) } } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--project-demo") ? 12 : 4)) {
            MainActor.assumeIsolated {
                let w = self.active?.window
                guard let v = (w?.attachedSheet ?? w)?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
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
        // Every project being edited is written into its file first.
        for c in controllers { if let s = c.session, s.isEditor, !c.writeOrAsk(s) { return .terminateCancel } }
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

    /// Projects whose crash copy is newer than their file: offered back. The edits go into the project file; a copy from an older
    /// MacPlayer that never had a file gets one now (the person chooses where).
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
                guard var p = try? env.projectStore.loadAutosave(c) else { continue }
                var path = c.savedPath
                if let sp = path, !env.fs.isDirectory(PathUtil.directory(of: sp)) { path = nil }
                if path == nil {
                    // Never had a file (or its folder is gone): the person chooses where it goes now.
                    guard let chosen = askWhereToSave(name: p.name, kind: p.kind, near: nil) else { continue }
                    p.name = PathUtil.stem(of: chosen)
                    guard (try? env.projectStore.create(p, at: chosen)) != nil else { continue }
                    env.projectStore.clearAutosave(projectID: c.projectID)
                    env.projects.register(path: chosen, opened: true)
                    openProject(path: chosen)
                    continue
                }
                let target = editorTarget()
                let savedPath = path!
                Task {
                    let s = await EditorSession.restore(project: p, savedPath: savedPath)
                    env.projects.register(path: savedPath, opened: true)
                    target.setSession(s, fromPlaylist: false)
                    s.save()
                }
            } else if c.savedPath != nil, r == .alertSecondButtonReturn, let sp = c.savedPath {
                env.projectStore.clearAutosave(projectID: c.projectID); open(urls: [URL(fileURLWithPath: sp)])
            } else { env.projectStore.clearAutosave(projectID: c.projectID) }
        }
    }

    // MARK: Windows

    /// `show: false`: made now, shown once it holds something (a file on its own is shown at its own size, not first at the
    /// default size).
    @discardableResult
    func newWindow(show: Bool = true) -> MainWindowController {
        let c = MainWindowController(playlists: playlists)
        controllers.append(c)
        if show { c.showWindow(nil) }
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
    /// The project being edited in the active window.
    var activeEditor: EditorSession? { activeSession.flatMap { $0.isEditor ? $0 : nil } }

    /// Where a video or photo opens to be watched: the active window when it shows nothing yet; otherwise a new window, so what
    /// was open stays open.
    func viewerTarget() -> MainWindowController {
        if let a = active, a.session == nil { return a }
        return newWindow()
    }

    /// Where one file opened on its own plays (0.15): the window the app has just shown with nothing in it (the start screen,
    /// as when Finder launched the app for this file); otherwise a new window, so the playlists, projects and other files stay
    /// where they are.
    func soloTarget() -> MainWindowController {
        if let a = active, a.session == nil, a.route == .home, a.window?.isVisible == true { return a }
        return newWindow(show: false)
    }

    /// Where a project opens: the active window unless it is already editing another project.
    func editorTarget() -> MainWindowController {
        if let a = active, a.session?.isEditor != true { return a }
        return newWindow()
    }

    func window(editing path: String) -> MainWindowController? {
        controllers.first { ($0.session?.projectPath).map { PathUtil.same($0, path) } ?? false }
    }

    /// Development aid (`--report-session <json>`): writes what the windows hold twice a second, so a script can check
    /// that Finder's "Open With" and double-clicking a file really arrive. Reads only; never part of normal use.
    private func startSessionReport(to path: String) {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let windows: [[String: Any]] = self.controllers.map { c in
                    let route: String = { switch c.route { case .home: return "home"; case .playlist: return "playlist"; case .projects: return "projects"; case .editor: return "editor"; case .solo: return "solo" } }()
                    guard let s = c.session else { return ["hasVideo": false, "route": route] }
                    return ["hasVideo": true, "isProject": s.isEditor, "kind": s.project.kind.rawValue, "route": route, "path": s.sourceURL?.path ?? "", "projectPath": s.projectPath ?? "",
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

    /// Every way files arrive (Finder's Open With, a double-click, the command line, Open…, Open Recent, a drop on an empty
    /// screen) comes here. Project files open in the editor; videos and photos open to be watched; several files or a folder
    /// become a playlist.
    func open(urls: [URL]) {
        let fs = env.fs
        let projectFiles = urls.filter { ProjectFile.isProject($0) && !fs.isDirectory($0.path) }
        for p in projectFiles { openProject(path: p.path) }
        let media = urls.filter { !ProjectFile.isProject($0) }
        let folders = media.filter { fs.isDirectory($0.path) }
        let files = media.filter { !fs.isDirectory($0.path) }
        if !folders.isEmpty || files.count > 1 {
            // Several videos or a folder: make them a playlist and play it.
            let pid = playlists.create(name: folders.first?.lastPathComponent)
            playlists.add(urls: folders + files, to: pid)
            let target = viewerTarget()
            target.go(to: .playlist)
            playlists.host = target
            playlists.playSelected(pid)
            return
        }
        guard let url = files.first else { return }
        // One video or photo: a window of its own, without the playlists (0.15).
        let target = soloTarget()
        Task {
            let ok = await target.openSolo(url: url)
            // A window made only for this file (never shown) goes away when the file cannot be opened.
            if !ok, target.session == nil, target.window?.isVisible != true { target.window?.close(); controllers.removeAll { $0 === target } }
        }
    }

    /// Opens a project file in the editor (a window that already has it comes to the front). Old files are upgraded on reading.
    func openProject(path: String, in target: MainWindowController? = nil) {
        if let w = window(editing: path) { w.window?.makeKeyAndOrderFront(nil); return }
        Task {
            do {
                var (p, schema) = try env.projectStore.loadDetailed(path: path)
                // A copy made in Finder has the same project id as its original: it gets its own, so their recovery data stay apart.
                var newID = false
                if env.projects.registry.idIsTaken(p.id, byOtherThan: path) { p.id = UUID(); newID = true }
                env.projects.register(path: path, opened: true)
                let s = try await EditorSession.openProject(path: path, prepared: p, fileSchema: schema)
                if newID { s.noteUnsaved() }
                (target ?? editorTarget()).setSession(s, fromPlaylist: false)
                // Development aid (test runs only): start playing, to look at playback in a real window.
                if env.isSandbox, let add = ProcessInfo.processInfo.environment["MACPLAYER_DEV_ADD"] {
                    await s.addVideos(add.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
                }
                if env.isSandbox, ProcessInfo.processInfo.environment["MACPLAYER_DEV_AUTOPLAY"] != nil {
                    try? await Task.sleep(nanoseconds: 2_000_000_000); s.player.play()
                }
            } catch {
                env.projects.register(path: path)
                MainWindowController.cannotOpen(URL(fileURLWithPath: path), error)
            }
        }
    }

    func openProject(entry e: ProjectEntry) {
        switch e.status {
        case .ok: openProject(path: e.path, in: active?.route == .projects && active?.session == nil ? active : nil)
        case .missing: findProject(entry: e)
        case .driveOffline: info(L("The disk with this project is not connected."), L("Connect it and try again."))
        case .inTrash: info(L("This project is in the Trash."), L("Put it back in Finder to open it."))
        case .unreadable: info(L("This project file cannot be read."), L("It may be damaged. MacPlayer does not change it."))
        case .newerVersion: info(L("This project was made by a newer MacPlayer."), L("Update MacPlayer to open it."))
        }
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle: L("OK")); a.runModal()
    }

    /// File ▸ Open…: videos and photos to watch, or projects to edit, depending on where the window is.
    @objc func openDocument(_ sender: Any?) {
        if let r = active?.route, r == .projects || r == .editor { openProjectFile(sender) } else { openMedia(sender) }
    }

    /// File ▸ Open Link… (⌘U): a video, stream or photo from a web link, in a window of its own (0.15).
    @objc func openLink(_ sender: Any?) { LinkPanel.shared.show() }

    @objc func openMedia(_ sender: Any?) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .image]
        if p.runModal() == .OK { open(urls: p.urls) }
    }

    @objc func openProjectFile(_ sender: Any?) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = [UTType(filenameExtension: "macplayer"), UTType(filenameExtension: "macvideo")].compactMap { $0 }
        p.message = L("Choose MacPlayer projects. They are added to your list of projects.")
        guard p.runModal() == .OK else { return }
        if p.urls.count == 1 { openProject(path: p.urls[0].path) }
        else { for u in p.urls { env.projects.register(path: u.path) }; active?.go(to: .projects) }
    }

    @objc func openFolderAsPlaylist(_ sender: Any?) {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true
        p.message = L("Choose a folder of videos. You will see what was found before anything is added.")
        guard p.runModal() == .OK, let u = p.url else { return }
        let target = viewerTarget()
        target.go(to: .playlist)
        playlists.host = target
        playlists.create(name: u.lastPathComponent)
        playlists.beginAddFolder(u)
    }

    @objc func newPlaylist(_ sender: Any?) { let t = viewerTarget(); t.go(to: .playlist); playlists.host = t; playlists.createAsking() }
    @objc func newWindowAction(_ sender: Any?) { newWindow() }

    // MARK: Screens

    @objc func goHome(_ sender: Any?) { if let a = active { a.go(to: .home) } else { newWindow() } }
    @objc func showPlaylists(_ sender: Any?) { (active ?? newWindow()).go(to: .playlist) }
    @objc func showProjects(_ sender: Any?) { (active ?? newWindow()).go(to: .projects) }

    // MARK: Making projects

    /// ⌘N: a new project while editing; a new window elsewhere.
    @objc func newAction(_ sender: Any?) {
        if let r = active?.route, r == .projects || r == .editor { newProject(sender) } else { newWindow() }
    }

    /// File ▸ New Project…: an empty video or photo project. The person picks the kind, then where to save it (always asked).
    @objc func newProject(_ sender: Any?) {
        guard let kind = askKind() else { return }
        let target = editorTarget()
        guard let path = askWhereToSave(name: kind == .video ? L("Video project") : L("Photo project"), kind: kind, near: nil) else { return }
        Task { _ = await createProject(kind: kind, from: nil, at: path, in: target) }
    }

    /// The two kinds of project, side by side.
    func askKind() -> ProjectKind? {
        let a = NSAlert()
        a.messageText = L("New project")
        a.informativeText = L("A video project puts videos on a timeline. A photo project holds one photo. Choose the kind; you choose where to save it next.")
        a.addButton(withTitle: L("Video Project")); a.addButton(withTitle: L("Photo Project")); a.addButton(withTitle: L("Cancel"))
        a.buttons[2].keyEquivalent = "\u{1b}"
        switch a.runModal() {
        case .alertFirstButtonReturn: return .video
        case .alertSecondButtonReturn: return .photo
        default: return nil
        }
    }

    /// Where the new project file goes: always asked. Starts in the folder used last (or next to the file being watched).
    /// Never overwrites: a name that is taken is refused and the question comes again. nil when cancelled.
    func askWhereToSave(name: String, kind: ProjectKind, near: URL?) -> String? {
        while true {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "macplayer")!]
            panel.nameFieldStringValue = name + ".macplayer"
            panel.canCreateDirectories = true
            panel.title = kind == .video ? L("Save the new video project") : L("Save the new photo project")
            panel.message = L("Choose where the project file is kept. Your videos and photos stay where they are and are never changed.")
            if let d = env.prefs.lastProjectFolder, env.fs.isDirectory(d) { panel.directoryURL = URL(fileURLWithPath: d) }
            else if let near { panel.directoryURL = near.deletingLastPathComponent() }
            else { panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first }
            guard panel.runModal() == .OK, var url = panel.url else { return nil }
            if !ProjectFile.isProject(url) { url = url.appendingPathExtension(ProjectFile.fileExtension) }
            if env.fs.exists(url.path) {
                let a = NSAlert(); a.messageText = LF("“%@” already exists.", url.lastPathComponent)
                a.informativeText = L("MacPlayer does not write over files. Choose another name.")
                a.addButton(withTitle: L("Choose Another Name")); a.addButton(withTitle: L("Cancel"))
                if a.runModal() == .alertFirstButtonReturn { continue }
                return nil
            }
            env.prefs.lastProjectFolder = url.deletingLastPathComponent().path
            return url.path
        }
    }

    /// Makes the project file (with the video or photo already in it, when given), lists it, and opens it in `target`.
    @discardableResult
    func createProject(kind: ProjectKind, from media: URL?, at path: String, in target: MainWindowController) async -> EditorSession? {
        do {
            let s = try await EditorSession.makeProjectFile(kind: kind, media: media, at: path)
            target.setSession(s, fromPlaylist: false)
            return s
        } catch {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = L("The project could not be made.")
            a.informativeText = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            a.runModal()
            return nil
        }
    }

    /// "Edit" while watching a file: after a question and the choice of where to save, a new project that already holds the file
    /// opens in the editor. Cancelling anywhere leaves the file playing as it was; nothing is made.
    func editViewedFile(in w: MainWindowController) {
        guard let s = w.session, s.role == .viewer, let url = s.localFileURL else { return }
        let kind: ProjectKind = s.isPhoto ? .photo : .video
        let wasPlaying = s.player.isPlaying
        s.player.pause()
        let a = NSAlert()
        a.messageText = kind == .video ? LF("Make a video project from “%@”?", url.lastPathComponent) : LF("Make a photo project from “%@”?", url.lastPathComponent)
        a.informativeText = L("The project keeps your edits in a file of its own. The original file is never changed. Next you choose where to save the project.")
        a.addButton(withTitle: L("Make Project…")); a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn, let path = askWhereToSave(name: url.deletingPathExtension().lastPathComponent, kind: kind, near: url) else {
            if wasPlaying { s.player.play() }
            return
        }
        Task { _ = await createProject(kind: kind, from: url, at: path, in: w) }
    }

    @objc func editCurrentFile(_ sender: Any?) { if let w = active { editViewedFile(in: w) } }

    // MARK: Project files

    /// ⌘S: the project is saved as you work; this writes it at once.
    @objc func saveDocument(_ sender: Any?) {
        guard let s = activeEditor else { return }
        if s.saveNow() { s.flash(L("Saved.")) } else if let w = active { _ = w.writeOrAsk(s) }
    }

    /// Writes the open project into a new file chosen by the person (when its own file cannot be written). The editor goes on with
    /// the new file; the old one is left as it is.
    func moveProjectFile(of s: EditorSession) -> Bool {
        guard let path = askWhereToSave(name: s.project.name, kind: s.project.kind, near: s.projectPath.map { URL(fileURLWithPath: $0) }) else { return false }
        var p = s.project; p.playhead = s.player.currentTime; p.name = PathUtil.stem(of: path)
        do {
            let fp = try env.projectStore.create(p, at: path)
            s.projectFileMoved(to: path)
            s.mutateQuietly { $0.name = p.name }
            _ = fp
            env.projects.register(path: path, opened: true)
            return true
        } catch {
            let a = NSAlert(); a.messageText = L("The project could not be saved there."); a.informativeText = (error as? CustomStringConvertible)?.description ?? error.localizedDescription; a.runModal()
            return false
        }
    }

    @objc func saveVideo(_ sender: Any?) {
        guard let s = activeEditor, s.isProject else { return }
        active?.window?.makeKeyAndOrderFront(nil)
        if let c = active, c.contentController.workspace != nil { c.contentController.showExport(); return }
        if let c = active, let item = (c.window?.contentViewController as? NSSplitViewController)?.splitViewItems.last, item.isCollapsed { c.toggleInspector() }
    }

    @objc func relinkVideo(_ sender: Any?) {
        guard let s = activeEditor else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        if s.isPhoto {
            p.allowedContentTypes = [.image]
            p.message = LF("Choose the photo to use for “%@”.", PathUtil.fileName(of: s.project.sources.first?.path ?? ""))
            guard p.runModal() == .OK, let u = p.url else { return }
            Task { await s.relink(to: u) }
            return
        }
        guard let id = s.project.sources.first(where: { s.missingSourceIDs.contains($0.id) })?.id ?? s.project.sources.first?.id else { return }
        p.allowedContentTypes = s.project.source(id)?.stillOf != nil ? [.image] : [.movie, .video]
        p.message = LF("Choose the video to use for “%@”.", PathUtil.fileName(of: s.project.source(id)?.mediaPath ?? ""))
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await s.relinkSource(id, to: u) }
    }

    @objc func addVideoToProject(_ sender: Any?) {
        guard let s = activeEditor, s.isProject else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.message = L("Choose videos to add to the timeline.")
        if p.runModal() == .OK { Task { await s.addVideos(p.urls) } }
    }

    @objc func addOverlayVideo(_ sender: Any?) {
        guard let s = activeEditor, s.isProject else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.message = L("Choose a video to lay over the main picture.")
        if p.runModal() == .OK { Task { await s.addOverlayVideos(p.urls) } }
    }

    @objc func addOverlayPicture(_ sender: Any?) {
        guard let s = activeEditor else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false; p.allowedContentTypes = [.image]
        p.message = s.isPhoto ? L("Choose a picture to lay over the photo as a logo.") : L("Choose a picture (a logo or watermark) to lay over the main picture.")
        if p.runModal() == .OK, let u = p.url { Task { await s.addOverlayPicture(u) } }
    }

    /// The photo of a photo project: chosen when it has none, changed (after a question) when it has one.
    @objc func choosePhoto(_ sender: Any?) {
        guard let s = activeEditor, s.isPhoto else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false; p.allowedContentTypes = [.image]
        p.message = s.project.sources.isEmpty ? L("Choose the photo of this project.") : L("Choose another photo for this project.")
        if p.runModal() == .OK, let u = p.url { Task { await s.choosePhoto(u) } }
    }

    @objc func splitClip(_ sender: Any?) { activeEditor?.splitAtPlayhead() }
    @objc func duplicateSelected(_ sender: Any?) { activeEditor?.duplicateSelection() }
    @objc func groupSelected(_ sender: Any?) { activeEditor?.groupCanvas() }
    @objc func ungroupSelected(_ sender: Any?) { activeEditor?.ungroupCanvas() }
    @objc func lockSelected(_ sender: Any?) { activeEditor?.toggleLockCanvas() }

    /// Files dropped on a window. In a project they are added by its rules; on the list of projects a project file opens; elsewhere
    /// they open as usual.
    func dropped(urls: [URL]) {
        let fs = env.fs
        let projectFiles = urls.filter { ProjectFile.isProject($0) }
        if !projectFiles.isEmpty { for p in projectFiles { openProject(path: p.path) }; return }
        guard let w = active else { open(urls: urls); return }
        if let s = w.session, s.isEditor {
            let files = urls.filter { !fs.isDirectory($0.path) }
            guard files.count == urls.count else { s.flash(L("Folders cannot be added to a project. Add the files themselves."), error: true); return }
            if s.isProject {
                // Videos and photos go on the main track (a photo as a clip of its own), sounds under it: as if dropped at the end of the timeline.
                Task { await s.place(files) }
                return
            }
            // A photo project.
            let decision = ProjectRules.canAdd(paths: files.map(\.path), to: s.project)
            if decision == .ok, let u = files.first { Task { await s.choosePhoto(u) }; return }
            if decision == .photoAlreadyChosen, let u = files.first {
                let a = NSAlert(); a.messageText = LF("Add “%@” as a logo over the photo?", u.lastPathComponent)
                a.informativeText = L("A photo project holds one photo. A picture dropped on it can be a logo over it. To use another photo instead, choose File ▸ Change Photo…")
                a.addButton(withTitle: L("Add as Logo")); a.addButton(withTitle: L("Cancel"))
                if a.runModal() == .alertFirstButtonReturn { s.addLogo(u) }
                return
            }
            s.flash(EditorSession.ruleText(decision), error: true)
            return
        }
        if w.route == .projects, w.session == nil {
            let files = urls.filter { MediaFiles.isCandidate($0.path) && !fs.isDirectory($0.path) }
            guard files.count == 1, files.count == urls.count, let u = files.first else {
                info(L("Drop one video or photo to make a project from it."), L("Or drop a .macplayer project file to open it.")); return
            }
            let kind: ProjectKind = ImageFiles.isCandidate(u.path) ? .photo : .video
            let a = NSAlert()
            a.messageText = kind == .video ? LF("Make a video project from “%@”?", u.lastPathComponent) : LF("Make a photo project from “%@”?", u.lastPathComponent)
            a.informativeText = L("The project keeps your edits in a file of its own. The original file is never changed. Next you choose where to save the project.")
            a.addButton(withTitle: L("Make Project…")); a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn, let path = askWhereToSave(name: u.deletingPathExtension().lastPathComponent, kind: kind, near: u) else { return }
            Task { _ = await createProject(kind: kind, from: u, at: path, in: w) }
            return
        }
        open(urls: urls)
    }

    // MARK: Menu actions (Edit, Playback, Clips, View)

    @objc func undo(_ sender: Any?) { activeEditor?.undo() }
    @objc func redo(_ sender: Any?) { activeEditor?.redo() }
    @objc func playPause(_ sender: Any?) { activeSession?.player.togglePlay() }
    @objc func stepBack(_ sender: Any?) { activeSession?.player.step(frames: -1) }
    @objc func stepForward(_ sender: Any?) { activeSession?.player.step(frames: 1) }
    @objc func skipBack(_ sender: Any?) { activeSession?.player.skip(seconds: -env.prefs.skipSeconds) }
    @objc func skipForward(_ sender: Any?) { activeSession?.player.skip(seconds: env.prefs.skipSeconds) }
    @objc func addMarker(_ sender: Any?) { activeEditor?.addMarker() }
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
        let s = activeSession, e = activeEditor
        let route = active?.route ?? .home
        let editing = route == .projects || route == .editor
        switch item.action {
        case #selector(newAction(_:)): item.title = editing ? L("New Project…") : L("New Window"); return true
        case #selector(openDocument(_:)): item.title = editing ? L("Open Project…") : L("Open…"); return true
        case #selector(renameCurrentFile(_:)), #selector(trashCurrentFile(_:)), #selector(editCurrentFile(_:)): return s?.role == .viewer && s?.localFileURL != nil
        case #selector(renameCurrentProject(_:)), #selector(trashCurrentProject(_:)), #selector(saveDocument(_:)): return e != nil
        case #selector(duplicateSelected(_:)): return e != nil && e?.selection != EditSelection.none
        case #selector(groupSelected(_:)): return (e?.canvasSelection.count ?? 0) > 1
        case #selector(ungroupSelected(_:)): return e?.canvasHasGroup ?? false
        case #selector(lockSelected(_:)):
            item.title = e?.canvasAllLocked == true ? L("Unlock") : L("Lock")
            return !(e?.canvasSelection.isEmpty ?? true)
        case #selector(undo(_:)): item.title = e?.undoTitle ?? L("Undo"); return e?.history.canUndo ?? false
        case #selector(redo(_:)): item.title = e?.redoTitle ?? L("Redo"); return e?.history.canRedo ?? false
        case #selector(playPause(_:)), #selector(stepBack(_:)), #selector(stepForward(_:)), #selector(skipBack(_:)), #selector(skipForward(_:)):
            return s != nil && s?.isPhoto != true && !(s?.isProject == true && s?.project.timeline.isEmpty == true)
        case #selector(addMarker(_:)), #selector(splitClip(_:)), #selector(addVideoToProject(_:)), #selector(addOverlayVideo(_:)), #selector(zoomTimelineIn(_:)), #selector(zoomTimelineOut(_:)), #selector(saveVideo(_:)):
            return e?.isProject == true
        case #selector(addOverlayPicture(_:)):
            item.title = e?.isPhoto == true ? L("Add Logo…") : L("Add Overlay Picture…")
            return e?.isProject == true || (e?.isPhoto == true && e?.project.sources.isEmpty == false)
        case #selector(choosePhoto(_:)):
            item.title = e?.project.sources.isEmpty == false ? L("Change Photo…") : L("Choose Photo…")
            return e?.isPhoto == true
        case #selector(relinkVideo(_:)): return e != nil && !(e?.project.sources.isEmpty ?? true)
        case #selector(closeVideo(_:)): return s != nil
        case #selector(toggleSidebar(_:)): return route == .playlist
        case #selector(toggleInspector(_:)): return route == .editor && s != nil
        case #selector(nextVideo(_:)), #selector(previousVideo(_:)): return route == .playlist
        default: return true
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        /// `firstResponder`: the item goes to whatever has the keyboard (a text field for Cut/Copy/Paste, the window for Close).
        /// Without it the item goes to `target`, by default this app delegate. (Until 0.15.2 `target: nil` was meant this way but
        /// fell back to the app delegate, which has no `paste:`: ⌘X ⌘C ⌘V ⌘A ⌘W ⌘M did nothing anywhere.)
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, firstResponder: Bool = false) {
            let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            if !key.isEmpty { i.keyEquivalentModifierMask = mods }
            i.target = firstResponder ? nil : (target ?? (sel == nil ? nil : self))
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
        add(file, L("New Project…"), #selector(newAction(_:)), "n")
        add(file, L("New Window"), #selector(newWindowAction(_:)), "n", [.command, .option])
        add(file, L("New Playlist"), #selector(newPlaylist(_:)), "n", [.command, .shift])
        file.addItem(.separator())
        add(file, L("Open…"), #selector(openDocument(_:)), "o")
        add(file, L("Open Link…"), #selector(openLink(_:)), "u")
        let recent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: ""); recentMenu.delegate = self; file.addItem(recent); file.setSubmenu(recentMenu, for: recent)
        add(file, L("Open Folder as Playlist…"), #selector(openFolderAsPlaylist(_:)), "o", [.command, .shift])
        file.addItem(.separator())
        add(file, L("Edit This File…"), #selector(editCurrentFile(_:)), "e")
        add(file, L("Rename File…"), #selector(renameCurrentFile(_:)))
        add(file, L("Move File to Trash…"), #selector(trashCurrentFile(_:)))
        file.addItem(.separator())
        add(file, L("Save Now"), #selector(saveDocument(_:)), "s")
        add(file, L("Export Video…"), #selector(saveVideo(_:)), "s", [.command, .option])
        add(file, L("Rename Project…"), #selector(renameCurrentProject(_:)))
        add(file, L("Move Project to Trash…"), #selector(trashCurrentProject(_:)))
        file.addItem(.separator())
        add(file, L("Add Video to Project…"), #selector(addVideoToProject(_:)), "a", [.command, .option])
        add(file, L("Add Overlay Video…"), #selector(addOverlayVideo(_:)), "v", [.command, .option])
        add(file, L("Add Overlay Picture…"), #selector(addOverlayPicture(_:)), "p", [.command, .option])
        add(file, L("Choose Photo…"), #selector(choosePhoto(_:)))
        add(file, L("Relink…"), #selector(relinkVideo(_:)))
        file.addItem(.separator())
        add(file, L("Show Export Queue"), #selector(showQueue(_:)), "e", [.command, .option])
        add(file, L("Close Video"), #selector(closeVideo(_:)), "w", [.command, .shift])
        add(file, L("Close"), #selector(NSWindow.performClose(_:)), "w", firstResponder: true)

        let edit = top(L("Edit"))
        add(edit, L("Undo"), #selector(undo(_:)), "z")
        add(edit, L("Redo"), #selector(redo(_:)), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, L("Cut"), #selector(NSText.cut(_:)), "x", firstResponder: true)
        add(edit, L("Copy"), #selector(NSText.copy(_:)), "c", firstResponder: true)
        add(edit, L("Paste"), #selector(NSText.paste(_:)), "v", firstResponder: true)
        add(edit, L("Select All"), #selector(NSText.selectAll(_:)), "a", firstResponder: true)
        edit.addItem(.separator())
        add(edit, L("Duplicate"), #selector(duplicateSelected(_:)), "d")
        add(edit, L("Group"), #selector(groupSelected(_:)), "g")
        add(edit, L("Ungroup"), #selector(ungroupSelected(_:)), "g", [.command, .shift])
        add(edit, L("Lock"), #selector(lockSelected(_:)), "l")

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
        add(clips, L("Add Marker   M"), #selector(addMarker(_:)))
        add(clips, L("Split Clip at Playhead   S"), #selector(splitClip(_:)))

        let view = top(L("View"))
        add(view, L("Home"), #selector(goHome(_:)), "h", [.command, .shift])
        add(view, L("Playlists"), #selector(showPlaylists(_:)), "1")
        add(view, L("Projects"), #selector(showProjects(_:)), "2")
        view.addItem(.separator())
        add(view, L("Show / Hide Playlists"), #selector(toggleSidebar(_:)), "1", [.command, .control])
        add(view, L("Show / Hide Tools"), #selector(toggleInspector(_:)), "2", [.command, .control])
        add(view, L("Zoom Timeline In"), #selector(zoomTimelineIn(_:)), "+", [.command])
        add(view, L("Zoom Timeline Out"), #selector(zoomTimelineOut(_:)), "-", [.command])
        view.addItem(.separator())
        add(view, L("Enter Full Screen   F"), #selector(toggleFullScreen(_:)), "f", [.command, .control])

        let window = top(L("Window"))
        add(window, L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", firstResponder: true)
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

    /// File ▸ Close Video: closes what the active window shows and goes back to its list (an editor's edits are written first).
    @objc func closeVideo(_ sender: Any?) { active?.closeVideo() }

    @objc func openRecent(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { open(urls: [u]) } }
}
