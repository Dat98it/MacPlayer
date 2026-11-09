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

@MainActor
final class ContentViewController: NSViewController {
    var session: EditorSession? { didSet { rebuild() } }
    var onOpen: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onOpenURL: (URL) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onRenameFile: () -> Void = {}
    var onTrashFile: () -> Void = {}
    private(set) var timeline: TimelineView?
    private(set) var host: PlayerHostView?
    private(set) var photoHost: PhotoHostView?
    var playlists: PlaylistModel?
    private var bag = Set<AnyCancellable>()
    private var timelineHeight: NSLayoutConstraint?

    override func loadView() { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; view = v }

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        bag.removeAll()
        timeline = nil; host = nil; photoHost = nil
        guard let s = session else {
            let start = NSHostingView(rootView: StartView(open: onOpen, openFolder: onOpenFolder, openURL: onOpenURL))
            pin(start, to: view)
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
        let header = NSHostingView(rootView: VideoHeader(session: s, onClose: { [weak self] in self?.onClose() }, onRename: { [weak self] in self?.onRenameFile() }, onTrash: { [weak self] in self?.onTrashFile() }))
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
        // Project mode adds three layer lines under the main track.
        let h = tl.heightAnchor.constraint(equalToConstant: s.isProject ? 190 : 110)
        h.isActive = true
        timelineHeight = h
        s.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self, weak s] _ in self?.timelineHeight?.constant = (s?.isProject ?? false) ? 190 : 110 }.store(in: &bag)
        s.player.$failure.receive(on: DispatchQueue.main).sink { [weak ph] f in ph?.show(message: f) }.store(in: &bag)
    }

    /// A photo has no transport and no timeline: the picture, and under it the bar with next/previous, slideshow and zoom.
    private func buildPhoto(_ s: EditorSession) {
        let ph = PhotoHostView(session: s)
        ph.onDropFiles = { [weak self] in self?.onDropFiles($0) }
        photoHost = ph
        let header = NSHostingView(rootView: VideoHeader(session: s, onClose: { [weak self] in self?.onClose() }, onRename: { [weak self] in self?.onRenameFile() }, onTrash: { [weak self] in self?.onTrashFile() }))
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

        content.onOpen = { (NSApp.delegate as? AppDelegate)?.openDocument(nil) }
        content.onOpenFolder = { (NSApp.delegate as? AppDelegate)?.openFolderAsPlaylist(nil) }
        content.onOpenURL = { u in (NSApp.delegate as? AppDelegate)?.open(urls: [u]) }
        content.onDropFiles = { urls in (NSApp.delegate as? AppDelegate)?.dropped(urls: urls) }
        content.onClose = { [weak self] in self?.closeVideo() }
        content.onRenameFile = { [weak self] in if let p = self?.session?.sourceURL?.path { (NSApp.delegate as? AppDelegate)?.renameFile(at: p) } }
        content.onTrashFile = { [weak self] in if let p = self?.session?.sourceURL?.path { (NSApp.delegate as? AppDelegate)?.trashFile(at: p) } }
        content.playlists = playlists
        content.session = nil
        setPanels(sidebarHidden: prefs.playlistPanelHidden, toolsHidden: true)
        // A panel closed or opened by dragging its edge is the person's choice too.
        panelObservers = [
            sidebarItem.observe(\.isCollapsed) { [weak self] item, _ in MainActor.assumeIsolated { if let self, !self.settingPanels { self.prefs.playlistPanelHidden = item.isCollapsed } } },
            inspectorItem.observe(\.isCollapsed) { [weak self] item, _ in MainActor.assumeIsolated { if let self, !self.settingPanels, self.session != nil { self.prefs.toolsPanelHidden = item.isCollapsed } } },
        ]
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let s = self?.session, self?.fromPlaylist == true { self?.playlists.rememberResume(s.player.currentTime) } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Session swap

    func setSession(_ s: EditorSession, fromPlaylist fp: Bool) {
        slideTimer?.invalidate(); slideTimer = nil
        session?.close(discardRecovery: true)
        session = s
        fromPlaylist = fp
        content.session = s
        inspector.rootView = AnyView(InspectorView(session: s))
        setPanels(sidebarHidden: sidebarItem.isCollapsed, toolsHidden: prefs.toolsPanelHidden)
        window?.title = s.project.name
        window?.representedURL = s.sourceURL
        s.player.onEnded = { [weak self] in
            MainActor.assumeIsolated { if self?.fromPlaylist == true { self?.playlists.advance(auto: true) } }
        }
        sessionBag.removeAll()
        s.$isDirty.receive(on: DispatchQueue.main).sink { [weak self] d in self?.window?.isDocumentEdited = d }.store(in: &sessionBag)
        s.$projectPath.receive(on: DispatchQueue.main).sink { [weak self] p in
            self?.window?.title = p.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? (self?.session?.project.name ?? "MacPlayer")
        }.store(in: &sessionBag)
        applyFloating()
        if let u = s.sourceURL { NSDocumentController.shared.noteNewRecentDocumentURL(u) }
        scheduleSlide()
    }

    // MARK: Slideshow

    func slideshowChanged() { scheduleSlide() }

    /// While the slideshow is on, a photo from a playlist stays for a few seconds and then the playlist moves on. A photo with changes that
    /// are not saved is never left behind: the slideshow stops there.
    private func scheduleSlide() {
        slideTimer?.invalidate(); slideTimer = nil
        guard playlists.slideshowOn, fromPlaylist, let s = session, s.isPhoto else { return }
        slideTimer = Timer.scheduledTimer(withTimeInterval: prefs.photoSlideSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, s.isPhoto else { return }
                if s.isDirty {
                    self.playlists.stopSlideshow()
                    s.flash(L("The slideshow stopped because this photo has changes that are not saved."))
                    return
                }
                self.playlists.advance(auto: true)
            }
        }
    }

    func applyFloating() { window?.level = AppEnvironment.shared.prefs.keepWindowOnTop ? .floating : .normal }

    // MARK: PlaylistHost

    var hostHasUnsavedEdits: Bool { session?.isDirty ?? false }

    func playPlaylistItem(url: URL, startAt: MediaTime?) async -> Bool {
        if session?.isDirty == true {
            guard confirmDiscardEdits() else { return false }
        }
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
        guard fromPlaylist, let s = session else { return }
        if let p = path, s.sourceURL?.standardizedFileURL.path != URL(fileURLWithPath: p).standardizedFileURL.path { return }
        if s.isDirty {
            // The edits exist only in this window: never close them away. Stop the video and cut its tie to the playlist.
            s.player.pause(); fromPlaylist = false
            s.flash(L("Removed from the playlist. The video stays open because it has unsaved edits."), error: false)
            return
        }
        clearSession()
    }

    /// Closes the video in the window and shows the start screen again.
    private func clearSession() {
        slideTimer?.invalidate(); slideTimer = nil
        session?.close(discardRecovery: true)
        session = nil; fromPlaylist = false
        sessionBag.removeAll()
        content.session = nil
        inspector.rootView = AnyView(EmptyView())
        setPanels(sidebarHidden: sidebarItem.isCollapsed, toolsHidden: true)
        window?.isDocumentEdited = false
        window?.title = "MacPlayer"; window?.representedURL = nil
    }

    /// The open video's file was renamed: open the same video again under its new name, at the same moment, playing or paused.
    func reopen(at url: URL) {
        guard let s = session else { return }
        let time = s.player.currentTime, playing = s.player.isPlaying, wasFromPlaylist = fromPlaylist
        Task {
            guard let fresh = try? await EditorSession.open(url: url) else { return }
            setSession(fresh, fromPlaylist: wasFromPlaylist)
            await fresh.player.seek(to: time)
            if playing { fresh.player.play() } else { fresh.player.pause() }
        }
    }

    // MARK: Opening

    func open(url: URL) async {
        do {
            let s = ProjectFile.isProject(url) ? try await EditorSession.openProject(path: url.path) : try await EditorSession.open(url: url)
            setSession(s, fromPlaylist: false)
            if s.sourceURL != nil, s.player.duration > .zero { s.player.pause() }
        } catch {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = LF("“%@” cannot be opened.", url.lastPathComponent)
            a.informativeText = ((error as? CustomStringConvertible)?.description ?? error.localizedDescription) + "\n\n" + L("MacPlayer plays and edits the formats macOS supports, such as MP4 and MOV with H.264 or HEVC. MKV and WebM are not supported yet.")
            a.runModal()
        }
    }

    private func confirmDiscardEdits() -> Bool {
        let a = NSAlert(); a.messageText = L("This video has unsaved edits."); a.informativeText = L("Save the project first, or discard the edits and continue.")
        a.addButton(withTitle: L("Discard Edits")); a.addButton(withTitle: L("Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Closing

    // MARK: Full screen

    /// What the window and its picture look like, for the full-screen check and the tests.
    var contentController: ContentViewController { content }
    var panelsCollapsed: (sidebar: Bool, inspector: Bool) { (sidebarItem.isCollapsed, inspectorItem.isCollapsed) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let s = session, s.isDirty else { return true }
        return confirmLeavingEdits(s)
    }

    /// Asks what to do with unsaved edits. True when it is fine to go on (saved, or the person chose not to save).
    private func confirmLeavingEdits(_ s: EditorSession) -> Bool {
        let a = NSAlert()
        a.messageText = LF("Save the project “%@”?", s.project.name)
        a.informativeText = L("Your edits are kept in a project file. The video file is not changed.")
        a.addButton(withTitle: L("Save…")); a.addButton(withTitle: L("Don't Save")); a.addButton(withTitle: L("Cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return (NSApp.delegate as? AppDelegate)?.saveProject(session: s, forceDialog: false) ?? false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Closes the video in this window and shows the start screen, without having to open another one. A video with unsaved edits asks
    /// first (`confirm` replaces that question, for tests). A playlist stops playing and remembers where the viewer stopped.
    /// False when the person chose to keep the video open.
    @discardableResult
    func closeVideo(confirm: ((EditorSession) -> Bool)? = nil) -> Bool {
        guard let s = session else { return false }
        if s.isDirty, !(confirm ?? { [unowned self] in self.confirmLeavingEdits($0) })(s) { return false }
        if fromPlaylist { playlists.rememberResume(s.player.currentTime); playlists.stop() }
        clearSession()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        resumeTimer?.invalidate(); slideTimer?.invalidate()
        // Its size and place are already saved; let go of the name so the next window that opens can take it over.
        if window?.frameAutosaveName == "MacPlayerMainWindow" { window?.setFrameAutosaveName("") }
        if let s = session { if fromPlaylist { playlists.rememberResume(s.player.currentTime) }; s.close(discardRecovery: true) }
        if playlists.host === self { playlists.host = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) { playlists.host = self; session?.refreshSourceState() }

    func toggleSidebar() {
        let hide = !sidebarItem.isCollapsed
        prefs.playlistPanelHidden = hide
        sidebarItem.animator().isCollapsed = hide
    }

    func toggleInspector() {
        let hide = !inspectorItem.isCollapsed
        if session != nil { prefs.toolsPanelHidden = hide }
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

    /// A photo: the arrows go to the next and previous picture of the playlist, Space starts or stops the slideshow, and the rest is zoom.
    private func handlePhotoKey(_ e: NSEvent, _ s: EditorSession, _ ch: String) -> Bool {
        switch e.keyCode {
        case 123: if fromPlaylist { playlists.previous(); return true }; return false
        case 124: if fromPlaylist { playlists.advance(auto: false); return true }; return false
        default: break
        }
        switch ch.lowercased() {
        case " ": if fromPlaylist { playlists.toggleSlideshow(); return true }; return false
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
        case 36, 76: if s.isProject { return false }; s.addClipFromInOut(); return true                    // Return
        case 51, 117: if let o = s.selectedOverlayID, s.isProject { s.deleteOverlay(o); return true }; if !s.selectedClipIDs.isEmpty { s.removeClips(s.selectedClipIDs); return true }; return false // Delete
        default: break
        }
        switch ch.lowercased() {
        case " ": s.player.togglePlay(); return true
        case "i": if s.isProject { return false }; s.markIn(); return true
        case "o": if s.isProject { return false }; s.markOut(); return true
        case "s": if s.isProject { s.splitAtPlayhead(); return true }; return false
        case "m": s.addMarker(); return true
        case ",": s.player.step(frames: -1); return true
        case ".": s.player.step(frames: 1); return true
        case "{", "[": s.jumpToMarker(forward: false); return true
        case "}", "]": s.jumpToMarker(forward: true); return true
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
