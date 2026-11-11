import AppKit
import AVKit
import Combine
import SwiftUI
import MacPlayerCore
import MacPlayerMedia

/// Plain-key shortcuts (Space, I, O, M, arrows) work only when no text is being typed.
final class VideoWindow: NSWindow {
    var shortcutHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !(firstResponder is NSText), event.modifierFlags.intersection([.command, .control]).isEmpty,
           shortcutHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// What a window shows. Each window has its own: one can play a playlist while another edits a project.
enum WindowRoute: Equatable { case home, playlist, projects, editor }

@MainActor
final class ContentViewController: NSViewController {
    var route = WindowRoute.home
    var session: EditorSession?
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onRenameFile: () -> Void = {}
    var onTrashFile: () -> Void = {}
    var onEditFile: () -> Void = {}
    var onRoute: (WindowRoute) -> Void = { _ in }
    private(set) var timeline: TimelineView?
    private(set) var host: PlayerHostView?
    private(set) var photoHost: PhotoHostView?
    /// The bar above the picture (file name and Close while watching; back, name and save state while editing), when one is shown.
    private(set) var header: NSView?
    var playlists: PlaylistModel?
    private var bag = Set<AnyCancellable>()
    private var timelineHeight: NSLayoutConstraint?

    override func loadView() { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; view = v }

    func show(_ route: WindowRoute, session: EditorSession?) {
        self.route = route; self.session = session
        rebuild()
    }

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        bag.removeAll()
        timeline = nil; host = nil; photoHost = nil; header = nil
        guard let s = session else {
            let root: AnyView
            switch route {
            case .home, .editor:
                root = AnyView(HomeView(openPlaylists: { [weak self] in self?.onRoute(.playlist) }, openProjects: { [weak self] in self?.onRoute(.projects) }))
            case .playlist:
                root = AnyView(PlaylistStartView(open: { (NSApp.delegate as? AppDelegate)?.openMedia(nil) },
                                                 openFolder: { (NSApp.delegate as? AppDelegate)?.openFolderAsPlaylist(nil) },
                                                 openURL: { u in (NSApp.delegate as? AppDelegate)?.open(urls: [u]) },
                                                 home: { [weak self] in self?.onRoute(.home) }))
            case .projects:
                root = AnyView(ProjectsView(projects: AppEnvironment.shared.projects, home: { [weak self] in self?.onRoute(.home) }))
            }
            pin(NSHostingView(rootView: root), to: view)
            // The empty window still accepts drops.
            let drop = DropCatcher(); drop.onDrop = { [weak self] in self?.onDropFiles($0) }
            pin(drop, to: view)
            return
        }
        if s.isPhoto { buildPhoto(s); return }
        let ph = PlayerHostView(player: s.player.player)
        ph.onDropFiles = { [weak self] in self?.onDropFiles($0) }
        host = ph
        ph.manipulator.attach(s)
        ph.fallbackAspect = { [weak s] in s?.outputAspect ?? 16.0 / 9 }
        let header = makeHeader(s)
        let notice = NSHostingView(rootView: NoticeBar(session: s))
        let transport = NSHostingView(rootView: TransportBar(session: s, player: s.player))
        let tl = TimelineView(session: s)
        timeline = tl
        // These bars take whatever width they are given but keep their natural height. Left to the default, SwiftUI hosting views also
        // report a largest size, and that caps how wide the window can be: full screen came out as a narrow window in the middle of the screen.
        // (Dropping the natural height too would let the title bar swallow the picture's height.)
        header.sizingOptions = [.minSize, .intrinsicContentSize]; notice.sizingOptions = [.minSize, .intrinsicContentSize]; transport.sizingOptions = [.minSize, .intrinsicContentSize]
        for v in [header, ph, notice, transport, tl] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ph.topAnchor.constraint(equalTo: header.bottomAnchor), ph.leadingAnchor.constraint(equalTo: view.leadingAnchor), ph.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            notice.topAnchor.constraint(equalTo: ph.bottomAnchor), notice.leadingAnchor.constraint(equalTo: view.leadingAnchor), notice.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transport.topAnchor.constraint(equalTo: notice.bottomAnchor), transport.leadingAnchor.constraint(equalTo: view.leadingAnchor), transport.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tl.topAnchor.constraint(equalTo: transport.bottomAnchor), tl.leadingAnchor.constraint(equalTo: view.leadingAnchor), tl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // A video project adds three layer lines under the main track; watching only needs the waveform and the playhead.
        let h = tl.heightAnchor.constraint(equalToConstant: s.isProject ? 190 : 70)
        h.isActive = true
        timelineHeight = h
        s.player.$failure.receive(on: DispatchQueue.main).sink { [weak ph] f in ph?.show(message: f) }.store(in: &bag)
        if s.isProject {
            // An empty timeline says what to do, right on the picture.
            let empty = NSHostingView(rootView: EmptyVideoProjectView(session: s))
            empty.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(empty)
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: ph.centerXAnchor), empty.centerYAnchor.constraint(equalTo: ph.centerYAnchor)])
        }
    }

    private func makeHeader(_ s: EditorSession) -> NSHostingView<AnyView> {
        let v: NSHostingView<AnyView>
        if s.isEditor {
            v = NSHostingView(rootView: AnyView(EditorHeader(session: s, onBack: { [weak self] in self?.onClose() })))
        } else {
            v = NSHostingView(rootView: AnyView(VideoHeader(session: s, onClose: { [weak self] in self?.onClose() }, onRename: { [weak self] in self?.onRenameFile() },
                                                            onTrash: { [weak self] in self?.onTrashFile() }, onEdit: { [weak self] in self?.onEditFile() })))
        }
        header = v
        return v
    }

    /// A photo has no transport and no timeline: the picture, and under it the bar with next/previous, slideshow and zoom.
    private func buildPhoto(_ s: EditorSession) {
        let ph = PhotoHostView(session: s)
        ph.onDropFiles = { [weak self] in self?.onDropFiles($0) }
        photoHost = ph
        let header = makeHeader(s)
        let notice = NSHostingView(rootView: NoticeBar(session: s))
        let model = playlists ?? (NSApp.delegate as! AppDelegate).playlists
        let bar = NSHostingView(rootView: PhotoBar(session: s, playlists: model, actualZoom: { [weak ph] in ph?.actualPixelsZoom() ?? 1 }))
        header.sizingOptions = [.minSize, .intrinsicContentSize]; notice.sizingOptions = [.minSize, .intrinsicContentSize]; bar.sizingOptions = [.minSize, .intrinsicContentSize]
        for v in [header, ph, notice, bar] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ph.topAnchor.constraint(equalTo: header.bottomAnchor), ph.leadingAnchor.constraint(equalTo: view.leadingAnchor), ph.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            notice.topAnchor.constraint(equalTo: ph.bottomAnchor), notice.leadingAnchor.constraint(equalTo: view.leadingAnchor), notice.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: notice.bottomAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if s.isEditor {
            let empty = NSHostingView(rootView: EmptyPhotoProjectView(session: s))
            empty.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(empty)
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: ph.centerXAnchor), empty.centerYAnchor.constraint(equalTo: ph.centerYAnchor)])
        }
    }

    private func pin(_ v: NSView, to parent: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: parent.topAnchor), v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: parent.leadingAnchor), v.trailingAnchor.constraint(equalTo: parent.trailingAnchor)])
    }
}

final class DropCatcher: NSView {
    var onDrop: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks pass through to the buttons below
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        onDrop?(urls); return true
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, PlaylistHost {
    private(set) var session: EditorSession?
    private(set) var route = WindowRoute.home
    let playlists: PlaylistModel
    private let content = ContentViewController()
    private let inspector = NSHostingController(rootView: AnyView(EmptyView()))
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var fromPlaylist = false
    private var panelObservers: [NSKeyValueObservation] = []
    /// True while the code (not the person) opens or closes a panel, so that is not taken for the person's choice.
    private var settingPanels = false
    private var prefs: AppPreferences { AppEnvironment.shared.prefs }
    private var resumeTimer: Timer?
    private var sessionBag = Set<AnyCancellable>()
    private var slideTimer: Timer?
    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    init(playlists: PlaylistModel) {
        self.playlists = playlists
        let w = VideoWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "MacPlayer"; w.minSize = NSSize(width: 900, height: 560); w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)      // the green button and F both need this to enter full screen
        super.init(window: w)
        w.delegate = self
        w.shortcutHandler = { [weak self] e in self?.handleKey(e) ?? false }

        let split = NSSplitViewController()
        let side = NSHostingController(rootView: PlaylistSidebar(model: playlists, openURL: { u in (NSApp.delegate as? AppDelegate)?.open(urls: [u]) }))
        // What the panels show must never decide how big the window is. By default a hosting controller passes the size its SwiftUI content would
        // like up to the window, so changing the tool (or the video) made the window wider or taller, and on a small screen pushed its top out of sight.
        side.sizingOptions = []
        inspector.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: side)
        sidebarItem.minimumThickness = 230; sidebarItem.maximumThickness = 560; sidebarItem.canCollapse = true
        let centre = NSSplitViewItem(viewController: content)
        centre.minimumThickness = 520
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 300; inspectorItem.maximumThickness = 460
        // Free space always goes to the picture. By default AppKit shrinks the whole window when a side panel is collapsed, and when the
        // window grows (full screen) it hands the new width to the panels first.
        for item in [sidebarItem!, inspectorItem!] {
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
        }
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(centre); split.addSplitViewItem(inspectorItem)
        if !AppEnvironment.shared.isSandbox { split.splitView.autosaveName = "MacPlayerMainSplit" }      // the widths of the panels are remembered between runs (not by test runs)
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1280, height: 800))
        // The size and place of the window are remembered. This comes last: the content above would otherwise resize it again.
        // (Not in test runs, whose windows are odd sizes and must not overwrite the person's.)
        w.center()
        if !AppEnvironment.shared.isSandbox {
            if !w.setFrameAutosaveName("MacPlayerMainWindow") {
                // Another window already holds the name: this one opens at the saved size, a little down and to the right of it.
                if let other = NSApp.windows.first(where: { $0 !== w && $0.frameAutosaveName == "MacPlayerMainWindow" }) {
                    w.setFrame(other.frame.offsetBy(dx: 28, dy: -28), display: false)
                } else { _ = w.setFrameUsingName("MacPlayerMainWindow") }
            }
        }

        content.onDropFiles = { urls in (NSApp.delegate as? AppDelegate)?.dropped(urls: urls) }
        content.onClose = { [weak self] in self?.closeVideo() }
        content.onRenameFile = { [weak self] in if let p = self?.session?.sourceURL?.path { (NSApp.delegate as? AppDelegate)?.renameFile(at: p) } }
        content.onTrashFile = { [weak self] in if let p = self?.session?.sourceURL?.path { (NSApp.delegate as? AppDelegate)?.trashFile(at: p) } }
        content.onEditFile = { [weak self] in if let self { (NSApp.delegate as? AppDelegate)?.editViewedFile(in: self) } }
        content.onRoute = { [weak self] r in self?.go(to: r) }
        content.playlists = playlists
        // A development aid for screenshots: start a window on one of its screens (test runs only).
        let start = AppEnvironment.shared.isSandbox ? ProcessInfo.processInfo.environment["MACPLAYER_START_ROUTE"] : nil
        route = start == "playlist" ? .playlist : start == "projects" ? .projects : .home
        content.show(route, session: nil)
        applyPanels()
        // A panel closed or opened by dragging its edge is the person's choice too.
        panelObservers = [
            sidebarItem.observe(\.isCollapsed) { [weak self] item, _ in MainActor.assumeIsolated { if let self, !self.settingPanels, self.route == .playlist { self.prefs.playlistPanelHidden = item.isCollapsed } } },
            inspectorItem.observe(\.isCollapsed) { [weak self] item, _ in MainActor.assumeIsolated { if let self, !self.settingPanels, self.route == .editor { self.prefs.toolsPanelHidden = item.isCollapsed } } },
        ]
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let s = self?.session, self?.fromPlaylist == true { self?.playlists.rememberResume(s.player.currentTime) } }
        }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Where the window is

    /// Goes to another screen of this window. What is open is closed first (an editor's edits are written to its file first);
    /// false when the person chose to stay.
    @discardableResult
    func go(to r: WindowRoute) -> Bool {
        if session != nil, !(r == .playlist && session?.role == .viewer) {
            guard closeVideo(goingTo: r) else { return false }
            return true
        }
        route = r
        if r == .projects { AppEnvironment.shared.projects.refresh() }
        content.show(r, session: session)
        applyPanels()
        updateTitle()
        return true
    }

    /// The side panels each screen has: the playlists only while watching, the tools only while editing.
    private func applyPanels() {
        switch route {
        case .playlist: setPanels(sidebarHidden: prefs.playlistPanelHidden, toolsHidden: true)
        case .editor: setPanels(sidebarHidden: true, toolsHidden: session == nil ? true : prefs.toolsPanelHidden)
        case .home, .projects: setPanels(sidebarHidden: true, toolsHidden: true)
        }
    }

    private func updateTitle() {
        guard let w = window else { return }
        if let s = session {
            if s.isEditor, let p = s.projectPath {
                w.title = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                w.representedURL = URL(fileURLWithPath: p)
            } else {
                w.title = s.sourceURL?.lastPathComponent ?? s.project.name
                w.representedURL = s.sourceURL
            }
            return
        }
        w.representedURL = nil
        switch route {
        case .home, .editor: w.title = "MacPlayer"
        case .playlist: w.title = L("Playlists")
        case .projects: w.title = L("Projects")
        }
    }

    // MARK: Session swap

    func setSession(_ s: EditorSession, fromPlaylist fp: Bool) {
        slideTimer?.invalidate(); slideTimer = nil
        if let old = session { finish(old) }
        session = s
        fromPlaylist = fp
        route = s.isEditor ? .editor : .playlist
        content.show(route, session: s)
        inspector.rootView = s.isEditor ? AnyView(InspectorView(session: s)) : AnyView(EmptyView())
        applyPanels()
        updateTitle()
        s.player.onEnded = { [weak self] in
            MainActor.assumeIsolated { if self?.fromPlaylist == true { self?.playlists.advance(auto: true) } }
        }
        sessionBag.removeAll()
        s.$saveState.receive(on: DispatchQueue.main).sink { [weak self] st in
            switch st { case .failed, .externallyChanged: self?.window?.isDocumentEdited = true; default: self?.window?.isDocumentEdited = false }
        }.store(in: &sessionBag)
        s.$projectPath.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitle() } }.store(in: &sessionBag)
        applyFloating()
        if s.role == .viewer, let u = s.sourceURL { NSDocumentController.shared.noteNewRecentDocumentURL(u) }
        if s.isEditor, let p = s.projectPath {
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: p))
            // A project listed without a picture gets one once its picture is ready.
            if !FileManager.default.fileExists(atPath: AppEnvironment.shared.projects.thumbnailURL(s.project.id).path) {
                Task { [weak s] in try? await Task.sleep(nanoseconds: 1_500_000_000); s?.storeThumbnail() }
            }
        }
        scheduleSlide()
    }

    /// Lets go of a session: an editor's last edits are written, its card gets a fresh picture, the player stops.
    private func finish(_ s: EditorSession) {
        if s.isEditor {
            s.saveNow()
            storeThumbnail(of: s)
        }
        s.close()
    }

    private func storeThumbnail(of s: EditorSession) { s.storeThumbnail() }

    // MARK: Slideshow

    func slideshowChanged() { scheduleSlide() }

    /// While the slideshow is on, a photo from a playlist stays for a few seconds and then the playlist moves on.
    private func scheduleSlide() {
        slideTimer?.invalidate(); slideTimer = nil
        guard playlists.slideshowOn, fromPlaylist, let s = session, s.isPhoto, s.role == .viewer else { return }
        slideTimer = Timer.scheduledTimer(withTimeInterval: prefs.photoSlideSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, s.isPhoto else { return }
                self.playlists.advance(auto: true)
            }
        }
    }

    func applyFloating() { window?.level = AppEnvironment.shared.prefs.keepWindowOnTop ? .floating : .normal }

    // MARK: PlaylistHost

    /// Watching never has unsaved edits; an editor writes its own.
    var hostHasUnsavedEdits: Bool { false }

    func playPlaylistItem(url: URL, startAt: MediaTime?) async -> Bool {
        // A project being edited in this window is written and closed first; the playlist plays here.
        if let s = session, s.isEditor { guard closeVideo(goingTo: .playlist) else { return false } }
        do {
            let s = try await EditorSession.open(url: url)
            setSession(s, fromPlaylist: true)
            if !s.isPhoto {
                if let t = startAt { await s.player.seek(to: t) }
                s.player.play()
            }
            return true
        } catch {
            return false
        }
    }

    func showPlaylistMessage(_ text: String, isError: Bool) { session?.flash(text, error: isError) }

    func stopPlaylistPlayback(path: String?) {
        guard fromPlaylist, let s = session, s.role == .viewer else { return }
        if let p = path, s.sourceURL?.standardizedFileURL.path != URL(fileURLWithPath: p).standardizedFileURL.path { return }
        clearSession(to: .playlist)
    }

    /// Closes what is open in the window and shows `next` (by default the list it came from).
    private func clearSession(to next: WindowRoute? = nil) {
        slideTimer?.invalidate(); slideTimer = nil
        let wasEditor = session?.isEditor ?? false
        if let s = session { finish(s) }
        session = nil; fromPlaylist = false
        sessionBag.removeAll()
        route = next ?? (wasEditor ? .projects : .playlist)
        if route == .projects { AppEnvironment.shared.projects.refresh() }
        content.show(route, session: nil)
        inspector.rootView = AnyView(EmptyView())
        applyPanels()
        window?.isDocumentEdited = false
        updateTitle()
    }

    /// The open video's file was renamed: open the same video again under its new name, at the same moment, playing or paused.
    func reopen(at url: URL) {
        guard let s = session, s.role == .viewer else { return }
        let time = s.player.currentTime, playing = s.player.isPlaying, wasFromPlaylist = fromPlaylist
        Task {
            guard let fresh = try? await EditorSession.open(url: url) else { return }
            setSession(fresh, fromPlaylist: wasFromPlaylist)
            await fresh.player.seek(to: time)
            if playing { fresh.player.play() } else { fresh.player.pause() }
        }
    }

    // MARK: Opening

    /// Opens a video or photo to watch in this window.
    func open(url: URL) async {
        do {
            let s = try await EditorSession.open(url: url)
            setSession(s, fromPlaylist: false)
            if s.sourceURL != nil, s.player.duration > .zero { s.player.pause() }
        } catch {
            Self.cannotOpen(url, error)
        }
    }

    static func cannotOpen(_ url: URL, _ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = LF("“%@” cannot be opened.", url.lastPathComponent)
        a.informativeText = ((error as? CustomStringConvertible)?.description ?? error.localizedDescription) + "\n\n" + L("MacPlayer plays and edits the formats macOS supports, such as MP4 and MOV with H.264 or HEVC. MKV and WebM are not supported yet.")
        a.runModal()
    }

    // MARK: Closing

    /// What the window and its picture look like, for the full-screen check and the tests.
    var contentController: ContentViewController { content }
    var panelsCollapsed: (sidebar: Bool, inspector: Bool) { (sidebarItem.isCollapsed, inspectorItem.isCollapsed) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let s = session, s.isEditor else { return true }
        return writeOrAsk(s)
    }

    /// An editor's edits are written into the project file. If that cannot be done, the person decides: try again, save somewhere
    /// else, or close anyway (the edits stay in the recovery copy). True when it is fine to go on.
    func writeOrAsk(_ s: EditorSession) -> Bool {
        while true {
            if s.saveNow() { return true }
            if case .externallyChanged = s.saveState {
                let a = NSAlert()
                a.messageText = L("The project file was changed outside MacPlayer.")
                a.informativeText = L("Keep your edits (they replace the file on disk), or close and keep the file as it is on disk. Your edits are also kept in the recovery data.")
                a.addButton(withTitle: L("Keep My Edits")); a.addButton(withTitle: L("Close Without Them")); a.addButton(withTitle: L("Cancel"))
                switch a.runModal() {
                case .alertFirstButtonReturn: if s.saveNow(force: true) { return true }
                case .alertSecondButtonReturn: return true
                default: return false
                }
                continue
            }
            let why: String = { if case .failed(let m) = s.saveState { return m }; return "" }()
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = LF("The project “%@” could not be saved.", s.project.name)
            a.informativeText = why + "\n\n" + L("Your edits are kept in MacPlayer's recovery data, and MacPlayer offers them again next time.")
            a.addButton(withTitle: L("Try Again")); a.addButton(withTitle: L("Save Somewhere Else…")); a.addButton(withTitle: L("Close Anyway")); a.addButton(withTitle: L("Cancel"))
            switch a.runModal() {
            case .alertFirstButtonReturn: continue
            case .alertSecondButtonReturn: if app?.moveProjectFile(of: s) == true { continue } else { return false }
            case .alertThirdButtonReturn: return true
            default: return false
            }
        }
    }

    /// Closes what is open in this window and goes back to the list it came from (or to `goingTo`). An editor's edits are written
    /// first. `confirm` is for tests. False when the person chose to stay.
    @discardableResult
    func closeVideo(goingTo: WindowRoute? = nil, confirm: ((EditorSession) -> Bool)? = nil) -> Bool {
        guard let s = session else {
            guard let g = goingTo else { return false }      // nothing open: nothing to close
            route = g; content.show(g, session: nil); applyPanels(); updateTitle()
            return true
        }
        if s.isEditor, !(confirm ?? { [unowned self] in self.writeOrAsk($0) })(s) { return false }
        if fromPlaylist { playlists.rememberResume(s.player.currentTime); playlists.stop() }
        clearSession(to: goingTo)
        return true
    }

    /// The project file of this window went to the Trash: close it without writing anything more.
    func closeTrashedProject() {
        guard let s = session, s.isEditor else { return }
        s.writingPaused = true
        s.close()
        session = nil
        sessionBag.removeAll()
        route = .projects
        content.show(.projects, session: nil)
        inspector.rootView = AnyView(EmptyView())
        applyPanels(); window?.isDocumentEdited = false; updateTitle()
    }

    func windowWillClose(_ notification: Notification) {
        resumeTimer?.invalidate(); slideTimer?.invalidate()
        // Its size and place are already saved; let go of the name so the next window that opens can take it over.
        if window?.frameAutosaveName == "MacPlayerMainWindow" { window?.setFrameAutosaveName("") }
        if let s = session { if fromPlaylist { playlists.rememberResume(s.player.currentTime) }; finish(s) }
        if playlists.host === self { playlists.host = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        playlists.host = self
        session?.refreshSourceState()
        if route == .projects, session == nil { AppEnvironment.shared.projects.refresh() }
    }

    func toggleSidebar() {
        guard route == .playlist else { return }
        let hide = !sidebarItem.isCollapsed
        prefs.playlistPanelHidden = hide
        sidebarItem.animator().isCollapsed = hide
    }

    func toggleInspector() {
        guard route == .editor, session != nil else { return }
        let hide = !inspectorItem.isCollapsed
        prefs.toolsPanelHidden = hide
        inspectorItem.animator().isCollapsed = hide
    }

    /// Opens or closes the two side panels from code, without that counting as the person's choice.
    private func setPanels(sidebarHidden: Bool, toolsHidden: Bool) {
        settingPanels = true
        defer { settingPanels = false }
        if sidebarItem.isCollapsed != sidebarHidden { sidebarItem.isCollapsed = sidebarHidden }
        if inspectorItem.isCollapsed != toolsHidden { inspectorItem.isCollapsed = toolsHidden }
    }

    // MARK: Keyboard

    /// A photo: when watching, the arrows go to the next and previous picture of the playlist and Space starts or stops the slideshow;
    /// the rest is zoom.
    private func handlePhotoKey(_ e: NSEvent, _ s: EditorSession, _ ch: String) -> Bool {
        if s.role == .viewer {
            switch e.keyCode {
            case 123: if fromPlaylist { playlists.previous(); return true }; return false
            case 124: if fromPlaylist { playlists.advance(auto: false); return true }; return false
            default: break
            }
            if ch == " " { if fromPlaylist { playlists.toggleSlideshow(); return true }; return false }
        }
        switch ch.lowercased() {
        case "+", "=": s.photoZoomIn(); return true
        case "-": s.photoZoomOut(); return true
        case "0": s.photoFit(); return true
        case "1": s.photoZoom = content.photoHost?.actualPixelsZoom() ?? 1; return true
        case "f": window?.toggleFullScreen(nil); return true
        default: return false
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let s = session else { return false }
        let prefs = AppEnvironment.shared.prefs
        let shift = e.modifierFlags.contains(.shift)
        guard let ch = e.charactersIgnoringModifiers else { return false }
        if s.isPhoto { return handlePhotoKey(e, s, ch) }
        switch e.keyCode {
        case 123: s.player.skip(seconds: -(shift ? prefs.bigSkipSeconds : prefs.skipSeconds)); return true // ←
        case 124: s.player.skip(seconds: shift ? prefs.bigSkipSeconds : prefs.skipSeconds); return true   // →
        case 115: Task { await s.player.seek(to: .zero) }; return true                                      // Home
        case 119: Task { await s.player.seek(to: s.duration) }; return true                                 // End
        case 51, 117:                                                                                         // Delete
            guard s.isProject else { return false }
            if let o = s.selectedOverlayID { s.deleteOverlay(o); return true }
            if !s.selectedClipIDs.isEmpty { s.deleteTimelineClips(s.selectedClipIDs); return true }
            return false
        default: break
        }
        switch ch.lowercased() {
        case " ": s.player.togglePlay(); return true
        case "s": if s.isProject { s.splitAtPlayhead(); return true }; return false
        case "m": if s.isProject { s.addMarker(); return true }; return false
        case ",": s.player.step(frames: -1); return true
        case ".": s.player.step(frames: 1); return true
        case "{", "[": if s.isProject { s.jumpToMarker(forward: false); return true }; return false
        case "}", "]": if s.isProject { s.jumpToMarker(forward: true); return true }; return false
        case "-": s.player.setSpeed(s.player.speed / 1.25); return true
        case "=", "+": s.player.setSpeed(s.player.speed * 1.25); return true
        case "f": window?.toggleFullScreen(nil); return true
        case "j": s.player.skip(seconds: -prefs.skipSeconds); return true
        case "k": s.player.pause(); return true
        case "l": s.player.skip(seconds: prefs.skipSeconds); return true
        default: return false
        }
    }
}
