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
/// `solo` (0.15): one video or photo opened on its own (from Finder, Open…, a web link), in a window with nothing about playlists.
enum WindowRoute: Equatable { case home, playlist, projects, editor, solo }

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
    /// The cover shown in place of the picture while a sound plays (0.16), for the self-test.
    private(set) var soundCover: NSView?
    private(set) var host: PlayerHostView?
    private(set) var photoHost: PhotoHostView?
    /// The bar above the picture (file name and Close while watching; back, name and save state while editing), when one is shown.
    private(set) var header: NSView?
    var playlists: PlaylistModel?
    private var bag = Set<AnyCancellable>()
    private var timelineHeight: NSLayoutConstraint?
    /// The video editor's panels (library, picture, properties, timeline), while a video project is open.
    private(set) var workspace: EditorWorkspace?

    override func loadView() { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; view = v }

    func show(_ route: WindowRoute, session: EditorSession?) {
        self.route = route; self.session = session
        rebuild()
    }

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        bag.removeAll()
        timeline = nil; host = nil; photoHost = nil; header = nil; timelineHeight = nil; headerKind = ""; chromeViews = []; soundCover = nil
        if let w = workspace { w.split.view.removeFromSuperview(); w.split.removeFromParent(); workspace = nil }
        guard let s = session else {
            let root: AnyView
            switch route {
            case .home, .editor, .solo:
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
        if s.isProject { buildWorkspace(s); return }
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
        chromeViews = [header, notice, transport]
        keepPictureRoom(picture: ph, notice: notice)
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
        if s.isSoundOnly {
            // A sound: its cover and tags where the picture would be (0.16).
            let cover = PassThroughHostingView(rootView: NowPlayingView(session: s, player: s.player))
            cover.sizingOptions = []
            cover.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cover)
            NSLayoutConstraint.activate([cover.topAnchor.constraint(equalTo: ph.topAnchor), cover.bottomAnchor.constraint(equalTo: ph.bottomAnchor),
                                         cover.leadingAnchor.constraint(equalTo: ph.leadingAnchor), cover.trailingAnchor.constraint(equalTo: ph.trailingAnchor)])
            soundCover = cover
        }
        if s.remote != nil {
            // A link: its own overlay says what is happening (connecting, waiting for data, failed, live), and a live stream has no
            // timeline to move along.
            let overlay = PassThroughHostingView(rootView: LinkOverlay(session: s, player: s.player))
            overlay.takesClicks = { [weak s] in s?.player.failure != nil }
            // It lies over the picture and never decides the window's size (a message card made the window taller).
            overlay.sizingOptions = []
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([overlay.topAnchor.constraint(equalTo: ph.topAnchor), overlay.bottomAnchor.constraint(equalTo: ph.bottomAnchor),
                                         overlay.leadingAnchor.constraint(equalTo: ph.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: ph.trailingAnchor)])
            s.player.$isLive.receive(on: DispatchQueue.main).sink { [weak h] live in h?.constant = live ? 0 : 70 }.store(in: &bag)
        } else {
            s.player.$failure.receive(on: DispatchQueue.main).sink { [weak ph] f in ph?.show(message: f) }.store(in: &bag)
        }
        if s.isProject {
            // An empty timeline says what to do, right on the picture.
            let empty = NSHostingView(rootView: EmptyVideoProjectView(session: s))
            empty.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(empty)
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: ph.centerXAnchor), empty.centerYAnchor.constraint(equalTo: ph.centerYAnchor)])
        }
    }

    /// A video project: the library on the left, the picture in the middle, the properties on the right, the timeline across the bottom.
    private func buildWorkspace(_ s: EditorSession) {
        let ph = PlayerHostView(player: s.player.player)
        ph.onDropFiles = { [weak s] urls in
            // Files dropped on the picture go into the project, as if dropped at the end of the timeline.
            guard let s else { return }
            Task { await s.place(urls) }
        }
        host = ph
        ph.manipulator.attach(s)
        ph.elements.attach(s)
        ph.onDropPayload = { [weak s] item, at in s?.applyDropped(item, position: at) }
        ph.onDropPictures = { [weak s] urls, at in
            guard let s else { return }
            // Over the video at the playhead, centred where dropped; with no video yet, as clips on the main track.
            Task { if s.project.timeline.isEmpty { await s.place(urls) } else { for u in urls { await s.addOverlayPicture(u, center: at) } } }
        }
        ph.fallbackAspect = { [weak s] in s?.outputAspect ?? 16.0 / 9 }
        let header = makeHeader(s)
        let notice = NSHostingView(rootView: NoticeBar(session: s))
        let transport = NSHostingView(rootView: TransportBar(session: s, player: s.player))
        header.sizingOptions = [.minSize, .intrinsicContentSize]; notice.sizingOptions = [.minSize, .intrinsicContentSize]; transport.sizingOptions = [.minSize, .intrinsicContentSize]
        let w = EditorWorkspace(session: s, centreViews: [ph, notice, transport])
        keepPictureRoom(picture: ph, notice: notice)
        workspace = w
        timeline = w.timeline
        addChild(w.split)
        let body = w.split.view
        guard let bar = w.toolbar, let tlView = w.timeline else { return }
        bar.sizingOptions = [.minSize, .intrinsicContentSize]
        let line = NSBox(); line.boxType = .separator
        for v in [header, body, line, bar, tlView] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor), body.leadingAnchor.constraint(equalTo: view.leadingAnchor), body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            line.topAnchor.constraint(equalTo: body.bottomAnchor), line.leadingAnchor.constraint(equalTo: view.leadingAnchor), line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: line.bottomAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tlView.topAnchor.constraint(equalTo: bar.bottomAnchor), tlView.leadingAnchor.constraint(equalTo: view.leadingAnchor), tlView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tlView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tlView.heightAnchor.constraint(equalToConstant: TimelineView.projectHeight),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        s.player.$failure.receive(on: DispatchQueue.main).sink { [weak ph] f in ph?.show(message: f) }.store(in: &bag)
        let empty = NSHostingView(rootView: EmptyVideoProjectView(session: s))
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: ph.centerXAnchor), empty.centerYAnchor.constraint(equalTo: ph.centerYAnchor)])
    }

    /// The export window, while it is open.
    private(set) var exportSheet: NSViewController?

    /// Opens the export window (the Export button at the top right, File ▸ Export): the frame for each social network, one quality
    /// choice, where to save. It is the only place to export from (0.14).
    func showExport() {
        guard let s = session, exportSheet == nil else { return }
        let host = NSHostingController(rootView: ExportSheet(session: s, close: { [weak self] in self?.closeExport() }))
        host.preferredContentSize = NSSize(width: 580, height: s.isPhoto ? 600 : 680)
        exportSheet = host
        presentAsSheet(host)
    }

    func closeExport() {
        guard let sheet = exportSheet else { return }
        exportSheet = nil
        dismiss(sheet)
    }

    /// The bars above and below the picture of a watched file (the strip under a video is `timelineHeight`).
    private var chromeViews: [NSView] = []

    /// The height of everything above and below the picture, from what each bar would like to be. Asked before the window has laid
    /// them out (the picture's own height is not known yet then).
    func chromeHeight() -> CGFloat {
        chromeViews.reduce(0) { $0 + $1.fittingSize.height } + (timelineHeight?.constant ?? 0)
    }

    /// Which bar is above the picture ("solo", "viewer", "editor"), for the self-test.
    private(set) var headerKind = ""
    /// The height of the strip under a watched video (0 for a live stream), for the self-test.
    var timelineHeightValue: CGFloat? { timelineHeight?.constant }

    private func makeHeader(_ s: EditorSession) -> NSHostingView<AnyView> {
        let v: NSHostingView<AnyView>
        headerKind = s.isEditor ? "editor" : route == .solo ? "solo" : "viewer"
        if s.isEditor {
            v = NSHostingView(rootView: AnyView(EditorHeader(session: s, onBack: { [weak self] in self?.onClose() },
                                                             onExport: { [weak self] in self?.showExport() })))
        } else if route == .solo {
            v = NSHostingView(rootView: AnyView(SoloHeader(session: s, linkSave: s.linkSave, onRename: { [weak self] in self?.onRenameFile() },
                                                           onTrash: { [weak self] in self?.onTrashFile() }, onEdit: { [weak self] in self?.onEditFile() })))
        } else {
            v = NSHostingView(rootView: AnyView(VideoHeader(session: s, onClose: { [weak self] in self?.onClose() }, onRename: { [weak self] in self?.onRenameFile() },
                                                            onTrash: { [weak self] in self?.onTrashFile() }, onEdit: { [weak self] in self?.onEditFile() })))
        }
        header = v
        return v
    }

    /// A photo has no transport and no timeline: the picture, and under it the bar with next/previous, slideshow and zoom. A photo project
    /// puts the library on its left and the properties on its right, like the video editor.
    private func buildPhoto(_ s: EditorSession) {
        let ph = PhotoHostView(session: s)
        ph.onDropFiles = { [weak self] in self?.onDropFiles($0) }
        ph.onDropPayload = { [weak s] item, at in s?.applyDropped(item, position: at) }
        ph.onDropPictures = { [weak s] urls, at in
            guard let s else { return }
            // The first picture of an empty photo project becomes its photo; the others go on as logos where they are dropped.
            Task { if s.project.sources.isEmpty { await s.place(urls) } else { for u in urls { s.addLogo(u, center: at) } } }
        }
        photoHost = ph
        let header = makeHeader(s)
        let notice = NSHostingView(rootView: NoticeBar(session: s))
        let model = playlists ?? (NSApp.delegate as! AppDelegate).playlists
        let bar = NSHostingView(rootView: PhotoBar(session: s, playlists: model, solo: route == .solo, actualZoom: { [weak ph] in ph?.actualPixelsZoom() ?? 1 }))
        header.sizingOptions = [.minSize, .intrinsicContentSize]; notice.sizingOptions = [.minSize, .intrinsicContentSize]; bar.sizingOptions = [.minSize, .intrinsicContentSize]
        if s.isEditor {
            let w = EditorWorkspace(session: s, centreViews: [ph, notice, bar])
            keepPictureRoom(picture: ph, notice: notice)
            workspace = w
            addChild(w.split)
            let body = w.split.view
            for v in [header, body] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                body.topAnchor.constraint(equalTo: header.bottomAnchor), body.leadingAnchor.constraint(equalTo: view.leadingAnchor), body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            let empty = NSHostingView(rootView: EmptyPhotoProjectView(session: s))
            empty.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(empty)
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: ph.centerXAnchor), empty.centerYAnchor.constraint(equalTo: ph.centerYAnchor)])
            return
        }
        for v in [header, ph, notice, bar] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        chromeViews = [header, notice, bar]
        keepPictureRoom(picture: ph, notice: notice)
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

    /// The message bar never takes the picture's room: it is kept short, and the picture keeps a height of its own first.
    private func keepPictureRoom(picture: NSView, notice: NSView) {
        let cap = notice.heightAnchor.constraint(lessThanOrEqualToConstant: 64); cap.priority = .required
        let room = picture.heightAnchor.constraint(greaterThanOrEqualToConstant: 160); room.priority = NSLayoutConstraint.Priority(rawValue: 760)
        notice.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([cap, room])
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
        content.onRenameFile = { [weak self] in if let p = self?.session?.localFileURL?.path { (NSApp.delegate as? AppDelegate)?.renameFile(at: p) } }
        content.onTrashFile = { [weak self] in if let p = self?.session?.localFileURL?.path { (NSApp.delegate as? AppDelegate)?.trashFile(at: p) } }
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
        if session != nil, !(r == .playlist && session?.role == .viewer && route != .solo) {
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
        // An editor (video or photo project) has its own panels (library, properties) inside the window's middle.
        case .editor: setPanels(sidebarHidden: true, toolsHidden: true)
        case .home, .projects: setPanels(sidebarHidden: true, toolsHidden: true)
        // One file on its own: only the picture and its controls.
        case .solo: setPanels(sidebarHidden: true, toolsHidden: true)
        }
        // A window that only plays one file may be small; the others hold panels side by side.
        window?.minSize = route == .solo ? Self.soloMinimum : NSSize(width: 900, height: 560)
        // A small window that played one file and now shows another screen grows to that screen's minimum.
        if let w = window, let c = w.contentView, !w.styleMask.contains(.fullScreen), c.bounds.width < w.minSize.width - 1 || c.bounds.height < w.minSize.height - 1 {
            w.setContentSize(NSSize(width: max(c.bounds.width, w.minSize.width), height: max(c.bounds.height, w.minSize.height)))
        }
    }

    static let soloMinimum = NSSize(width: 480, height: 340)

    private func updateTitle() {
        guard let w = window else { return }
        if let s = session {
            if s.isEditor, let p = s.projectPath {
                w.title = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                w.representedURL = URL(fileURLWithPath: p)
            } else if let r = s.remote {
                w.title = r.displayName
                w.subtitle = r.host
                w.representedURL = nil
            } else {
                w.title = s.sourceURL?.lastPathComponent ?? s.project.name
                w.representedURL = s.sourceURL
            }
            if s.remote == nil { w.subtitle = "" }
            return
        }
        w.representedURL = nil; w.subtitle = ""
        switch route {
        case .home, .editor, .solo: w.title = "MacPlayer"
        case .playlist: w.title = L("Playlists")
        case .projects: w.title = L("Projects")
        }
    }

    // MARK: Session swap

    func setSession(_ s: EditorSession, fromPlaylist fp: Bool, solo: Bool = false) {
        slideTimer?.invalidate(); slideTimer = nil
        if let old = session { finish(old) }
        session = s
        fromPlaylist = fp
        route = s.isEditor ? .editor : (solo ? .solo : .playlist)
        content.show(route, session: s)
        inspector.rootView = AnyView(EmptyView())      // editors have their own panels (EditorWorkspace)
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
        if s.role == .viewer, let u = s.localFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(u) }
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
        let time = s.player.currentTime, playing = s.player.isPlaying, wasFromPlaylist = fromPlaylist, wasSolo = route == .solo
        Task {
            guard let fresh = try? await EditorSession.open(url: url) else { return }
            // At the same moment before it is shown (shown first, it sat at 0 until the seek ended; the self-test caught it there once).
            await fresh.player.seek(to: time)
            setSession(fresh, fromPlaylist: wasFromPlaylist, solo: wasSolo)
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

    /// Opens one video or photo in this window on its own (0.15): no playlists, the window fitted to the picture. False when it
    /// cannot be opened (the person was told why).
    @discardableResult
    /// `autoplay`: a video or a sound opened this way (Finder, File ▸ Open…, Open Recent) starts playing at once (0.16.1); the person
    /// asked to watch it. Off when the caller decides itself (a downloaded link's file goes on where the link was).
    func openSolo(url: URL, autoplay: Bool = true) async -> Bool {
        do {
            let s = try await EditorSession.open(url: url)
            showSolo(s)
            if autoplay, !s.isPhoto, s.remote == nil, s.player.duration > .zero { s.player.play() }
            return true
        } catch {
            Self.cannotOpen(url, error)
            return false
        }
    }

    /// Shows a session opened elsewhere (a web link) on its own in this window.
    /// The size a sound's cover is shown at in a window of its own.
    static let soundPicture = CGSize(width: 800, height: 450)

    func showSolo(_ s: EditorSession) {
        // This window's size is its own: it is not the remembered size of the main window.
        if window?.frameAutosaveName == "MacPlayerMainWindow" { window?.setFrameAutosaveName("") }
        setSession(s, fromPlaylist: false, solo: true)
        fitToPicture(s)
        guard s.remote != nil, !s.isPhoto else {
            if window?.isVisible != true { showWindow(nil) }
            return
        }
        // A link plays as soon as it can; its picture size is known only then. A new window waits a moment for it, so it does not
        // appear at one size and jump to another.
        s.player.play()
        var fitted = false
        let reveal = { [weak self] in if self?.window?.isVisible != true { self?.showWindow(nil) } }
        s.player.$presentationSize.receive(on: DispatchQueue.main).sink { [weak self, weak s] size in
            guard let self, let s, !fitted, size.width > 0, self.session === s else { return }
            fitted = true
            self.fitToPicture(s, media: size)
            reveal()
        }.store(in: &sessionBag)
        s.player.$failure.receive(on: DispatchQueue.main).sink { f in if f != nil { reveal() } }.store(in: &sessionBag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { reveal() } }
    }

    /// Sizes the window to the picture's shape, as large as fits comfortably on its screen (not in full screen).
    func fitToPicture(_ s: EditorSession, media: CGSize? = nil) {
        guard let w = window, !w.styleMask.contains(.fullScreen), let screen = w.screen ?? NSScreen.main else { return }
        // A sound has no picture: its cover gets a modest wide window.
        let size = media ?? (s.isSoundOnly ? Self.soundPicture : s.info?.primaryVideo.map { CGSize(width: $0.width, height: $0.height) })
        // The bars around the picture.
        let chrome = max(40, content.chromeHeight())
        let visible = screen.visibleFrame
        let contentSize = PlayerWindowSizing.contentSize(media: size, chrome: chrome, screen: CGSize(width: visible.width, height: visible.height - 28),
                                                         minimum: Self.soloMinimum)
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let centre = CGPoint(x: w.frame.midX, y: w.frame.midY)
        frame.origin = CGPoint(x: centre.x - frame.width / 2, y: centre.y - frame.height / 2)
        // Kept on the screen.
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        w.setFrame(frame, display: true, animate: w.isVisible && !AppEnvironment.shared.isSandbox)
    }

    static func cannotOpen(_ url: URL, _ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = LF("“%@” cannot be opened.", url.lastPathComponent)
        a.informativeText = ((error as? CustomStringConvertible)?.description ?? error.localizedDescription) + "\n\n" + L("MacPlayer plays and edits the formats macOS supports: MP4 and MOV videos (H.264, HEVC), MP3, M4A, FLAC, WAV and Ogg sounds, and common pictures. MKV, WebM, AVI and WMA are not supported.")
        a.runModal()
    }

    // MARK: Closing

    /// What the window and its picture look like, for the full-screen check and the tests.
    var contentController: ContentViewController { content }
    var panelsCollapsed: (sidebar: Bool, inspector: Bool) { (sidebarItem.isCollapsed, content.workspace?.propertiesHidden ?? inspectorItem.isCollapsed) }

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
        // A window that only played one file goes away with it (unless it is asked to show another screen).
        if route == .solo, goingTo == nil { clearSession(to: .home); window?.close(); return true }
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
        if let w = content.workspace { w.toggleProperties(); return }
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
    /// Keys for what is selected on the picture (text, shapes, stickers, layers, logos): ⌫ deletes, the arrows move it by one point
    /// (⇧: ten), Esc selects nothing. With nothing selected on the picture the keys keep their usual meaning (the arrows skip in time).
    private func handleCanvasKey(_ e: NSEvent, _ s: EditorSession) -> Bool {
        guard s.isEditor, !s.canvasSelection.isEmpty else {
            if s.isPhoto, s.isEditor, e.keyCode == 51 || e.keyCode == 117, s.selection != .none { s.deleteSelection(); return true }
            return false
        }
        let pic = s.isPhoto ? (content.photoHost?.pictureRect() ?? .zero) : (content.host?.displayedPicture() ?? .zero)
        let step = e.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let dx = step / Double(max(1, pic.width)), dy = step / Double(max(1, pic.height))
        switch e.keyCode {
        case 51, 117: s.deleteSelection(); return true                     // ⌫ ⌦
        case 53: s.select(.none); return true                               // Esc
        case 123: s.nudgeCanvas(dx: -dx, dy: 0); return true                // ←
        case 124: s.nudgeCanvas(dx: dx, dy: 0); return true                 // →
        case 126: s.nudgeCanvas(dx: 0, dy: -dy); return true                // ↑
        case 125: s.nudgeCanvas(dx: 0, dy: dy); return true                 // ↓
        default: return false
        }
    }

    /// For the self-test: a key as the window would hand it to the picture.
    func testKey(_ e: NSEvent) -> Bool { handleKey(e) }

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
        if handleCanvasKey(e, s) { return true }
        if s.isPhoto { return handlePhotoKey(e, s, ch) }
        switch e.keyCode {
        case 123: s.player.skip(seconds: -(shift ? prefs.bigSkipSeconds : prefs.skipSeconds)); return true // ←
        case 124: s.player.skip(seconds: shift ? prefs.bigSkipSeconds : prefs.skipSeconds); return true   // →
        case 115: Task { await s.player.seek(to: .zero) }; return true                                      // Home
        case 119: Task { await s.player.seek(to: s.duration) }; return true                                 // End
        case 51, 117:                                                                                         // Delete
            guard s.isProject, s.selection != .none else { return false }
            s.deleteSelection(); return true
        case 53:                                                                                              // Esc: nothing selected
            guard s.isProject, s.selection != .none else { return false }
            s.select(.none); return true
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
