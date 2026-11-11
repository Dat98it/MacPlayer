import AppKit
import SwiftUI
import MacPlayerCore

/// The video editor's screen, laid out like most editors so a beginner finds things where they expect them:
///
///     ┌──────────────────────── project name · saved · Export ────────────────────────┐
///     │ Library (media, sound, │        picture         │ Properties of what is      │
///     │ text, filters,         │   play · time · speed  │ selected (or the project)  │
///     │ transitions)           │                        │                            │
///     ├─ undo redo │ split duplicate delete │ marker ───────────── zoom − ━━○━━ + fit ─┤
///     │ timeline: video with pictures · text · 3 layers · sound (full width)          │
///     └────────────────────────────────────────────────────────────────────────────────┘
///
/// The three upper panels can be resized; the two side ones can be closed (⌃⌘1 / ⌃⌘2 style menu items close the Properties panel).
@MainActor
final class EditorWorkspace {
    let split = NSSplitViewController()
    let libraryItem: NSSplitViewItem
    let propertiesItem: NSSplitViewItem
    let centre = NSViewController()
    /// The timeline and its bar (a video project; a photo has no time).
    let timeline: TimelineView?
    let toolbar: NSHostingView<TimelineToolbar>?
    private let zoom = Box<Double>(0)

    init(session s: EditorSession, centreViews: [NSView]) {
        if s.isProject {
            let tl = TimelineView(session: s)
            let zoom = self.zoom
            timeline = tl
            toolbar = NSHostingView(rootView: TimelineToolbar(session: s, zoom: zoom, setZoom: { [weak tl] f in tl?.setZoom(f) }, fit: { [weak tl] in tl?.fitAll() }))
            tl.onZoomChange = { f in if abs(zoom.value - f) > 0.001 { zoom.value = f } }
        } else { timeline = nil; toolbar = nil }

        let library = NSHostingController(rootView: LibraryPanel(session: s))
        let properties = NSHostingController(rootView: PropertiesPanel(session: s))
        library.sizingOptions = []; properties.sizingOptions = []
        centre.view = NSView()
        libraryItem = NSSplitViewItem(viewController: library)
        libraryItem.minimumThickness = 230; libraryItem.maximumThickness = 520; libraryItem.canCollapse = true
        propertiesItem = NSSplitViewItem(viewController: properties)
        propertiesItem.minimumThickness = 290; propertiesItem.maximumThickness = 520; propertiesItem.canCollapse = true
        let middle = NSSplitViewItem(viewController: centre)
        middle.minimumThickness = 340
        for item in [libraryItem, propertiesItem] {
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 270)
        }
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.addSplitViewItem(libraryItem); split.addSplitViewItem(middle); split.addSplitViewItem(propertiesItem)
        if !AppEnvironment.shared.isSandbox { split.splitView.autosaveName = "MacPlayerEditorSplit" }
        // The library starts a little narrower than the properties.
        libraryItem.viewController.view.setFrameSize(NSSize(width: 270, height: 400))
        properties.view.setFrameSize(NSSize(width: 330, height: 400))
        if AppEnvironment.shared.prefs.toolsPanelHidden { propertiesItem.isCollapsed = true }

        // The picture, the bar under it and the play controls fill the middle.
        let v = centre.view
        var above: NSLayoutYAxisAnchor = v.topAnchor
        for (i, sub) in centreViews.enumerated() {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
            NSLayoutConstraint.activate([sub.topAnchor.constraint(equalTo: above), sub.leadingAnchor.constraint(equalTo: v.leadingAnchor), sub.trailingAnchor.constraint(equalTo: v.trailingAnchor)])
            if i == centreViews.count - 1 { sub.bottomAnchor.constraint(equalTo: v.bottomAnchor).isActive = true }
            above = sub.bottomAnchor
        }
    }

    var propertiesHidden: Bool { propertiesItem.isCollapsed }
    func toggleProperties() { propertiesItem.animator().isCollapsed.toggle(); AppEnvironment.shared.prefs.toolsPanelHidden = propertiesItem.isCollapsed }
    func showProperties() { if propertiesItem.isCollapsed { propertiesItem.animator().isCollapsed = false; AppEnvironment.shared.prefs.toolsPanelHidden = false } }
    func toggleLibrary() { libraryItem.animator().isCollapsed.toggle() }
}

/// The bar above the timeline: undo and redo, the editing actions for what is selected, and the zoom.
struct TimelineToolbar: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var zoom: Box<Double>
    var setZoom: (Double) -> Void
    var fit: () -> Void

    var body: some View {
        let sel = session.selection
        let canSplit = session.isProject && TimelineMap.locate(session.project.timeline, at: session.player.currentTime) != nil
        HStack(spacing: 4) {
            tool("arrow.uturn.backward", L("Undo"), session.undoTitle + " (⌘Z)", enabled: session.history.canUndo) { session.undo() }
            tool("arrow.uturn.forward", L("Redo"), session.redoTitle + " (⇧⌘Z)", enabled: session.history.canRedo) { session.redo() }
            Divider().frame(height: 18).padding(.horizontal, 4)
            tool("scissors", L("Split"), L("Split the clip at the playhead (S)"), enabled: canSplit) { session.splitAtPlayhead() }
            tool("plus.square.on.square", L("Duplicate"), L("Duplicate what is selected"), enabled: sel != .none) { session.duplicateSelection() }
            tool("trash", L("Delete"), L("Delete what is selected (⌫)"), enabled: sel != .none) { session.deleteSelection() }
            Divider().frame(height: 18).padding(.horizontal, 4)
            tool("flag", L("Marker"), L("Add a marker at the playhead (M)"), enabled: true) { session.addMarker() }
            tool("textformat", L("Text"), L("Add a text at the playhead"), enabled: !session.project.timeline.isEmpty) { session.addText(nil) }
            Spacer(minLength: 8)
            Text(hint(sel)).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button { setZoom(max(0, zoom.value - 0.1)); zoom.value = max(0, zoom.value - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless).help(L("Zoom out")).accessibilityLabel(L("Zoom out"))
            Slider(value: Binding(get: { zoom.value }, set: { zoom.value = $0; setZoom($0) }), in: 0...1).frame(width: 110).controlSize(.small).accessibilityLabel(L("Timeline zoom"))
            Button { setZoom(min(1, zoom.value + 0.1)); zoom.value = min(1, zoom.value + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless).help(L("Zoom in")).accessibilityLabel(L("Zoom in"))
            Button { fit(); zoom.value = 0 } label: { Image(systemName: "arrow.left.and.right.square") }
                .buttonStyle(.borderless).help(L("Show the whole timeline")).accessibilityLabel(L("Show the whole timeline"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func hint(_ sel: EditSelection) -> String {
        switch sel {
        case .none: return session.project.timeline.isEmpty ? L("Drag videos from the library onto the timeline") : L("Click a clip to edit it · drag to move · drag its edges to trim")
        case .clip: return L("Drag the clip to move it · drag its white edges to trim · S splits at the playhead")
        case .layer, .text, .sound: return L("Drag to move it in time · drag its edges to make it longer or shorter")
        }
    }

    private func tool(_ icon: String, _ title: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 13)); Text(title).font(.system(size: 11.5)) }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).disabled(!enabled).help(help).accessibilityLabel(title)
    }
}
