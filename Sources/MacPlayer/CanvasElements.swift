import AppKit
import Combine
import MacPlayerCore
import MacPlayerMedia

extension Notification.Name {
    /// A drag on the picture moved (object: the session): the frames on the picture are drawn again.
    static let canvasDraftChanged = Notification.Name("MacPlayer.canvasDraftChanged")
}

// Text, stickers and shapes handled right on the picture (0.11): click one to select it, drag it to move it, drag a corner to make it bigger or
// smaller. Things dragged from the library land where they are dropped. The picture follows the mouse at once (`ElementLive`); each drag is one
// undo step.

extension EditorSession {
    /// What an element shows now: where it is, how big and how turned (a photo: as it is saved, with no animation). Nil when it is not on screen.
    func elementState(_ o: TextOverlay) -> ElementState? {
        if isPhoto { return ElementState(x: o.x, y: o.y, scale: o.scale ?? 1, rotation: o.rotation ?? 0) }
        return ElementAnimator.state(of: o, at: player.currentTime.seconds)
    }

    /// Moves and sizes an element of `p` from where it was when the drag began (`origin`): by `dx`, `dy` (fractions of the picture) and `k`
    /// times its size. An element with keyframes gets a keyframe at the playhead; otherwise its place itself changes.
    func place(_ id: UUID, in p: inout Project, from origin: TextOverlay, dx: Double, dy: Double, scaleBy k: Double) {
        guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
        // Kept to a millionth of the picture (far below a pixel), so a thing put on a centre is exactly there.
        func tidy(_ v: Double) -> Double { (min(max(v, 0), 1) * 1_000_000).rounded() / 1_000_000 }
        let keyed = !isPhoto && !(origin.keyframes ?? []).isEmpty
        if keyed, let st = ElementAnimator.state(of: origin, at: player.currentTime.seconds) {
            var to = st; to.x = min(max(st.x + dx, 0), 1); to.y = min(max(st.y + dy, 0), 1); to.scale = min(max(st.scale * k, 0.15), 8)
            p.overlays[i].keyframes = ElementAnimator.setting(origin.keyframes ?? [], at: player.currentTime.seconds - origin.start.seconds, to: to)
        } else {
            let scale = min(max((origin.scale ?? 1) * k, 0.15), 8)
            p.overlays[i].x = tidy(origin.x + dx); p.overlays[i].y = tidy(origin.y + dy); p.overlays[i].scale = abs(scale - 1) < 0.001 ? nil : scale
        }
    }

    /// Moves and sizes an element straight away (one edit). A drag uses `place(_:in:…)` on a draft instead, and one edit at the drop.
    func placeElement(_ id: UUID, from origin: TextOverlay, dx: Double, dy: Double, scaleBy k: Double) {
        guard canEdit else { return }
        var d = project
        place(id, in: &d, from: origin, dx: dx, dy: dy, scaleBy: k)
        showDraft(d, ids: [id])
        commitDraft(k == 1 ? "Move on the picture" : "Resize on the picture", keyed: !(origin.keyframes ?? []).isEmpty)
    }

    // MARK: A drag in progress (0.14.2)

    /// What the things on the picture look like now: the drag in progress, else the project.
    var canvasProject: Project { canvasDraft ?? project }

    /// Shows a drag in progress — the frames on the picture and the picture itself — without changing the project. Changing it at every
    /// mouse move redrew every panel and the timeline and asked the player for a new frame each time (up to 120 a second); the picture and
    /// the frame fell behind the mouse. The project changes once, at the drop (`commitDraft`).
    func showDraft(_ d: Project, ids: Set<UUID>) {
        canvasDraft = d
        NotificationCenter.default.post(name: .canvasDraftChanged, object: self)
        // What is lifted is drawn by the views themselves: nothing for the preview to do until the drop.
        let rest = ids.subtracting(CanvasLift.ids)
        guard !rest.isEmpty else { return }
        if isPhoto { renderPhotoSoon(); return }
        pushLive(d, ids: rest)
        refreshFrameSoon()
    }

    /// Tells the preview where the dragged things are now (it moves what it has, without being built again).
    private func pushLive(_ d: Project, ids: Set<UUID>) {
        let t = player.currentTime.seconds
        for o in d.overlays where ids.contains(o.id) {
            // The compositor moves what it has by the difference: from where it is in the project to where the drag puts it, now.
            guard let was = project.overlays.first(where: { $0.id == o.id }) else { continue }
            let s0 = ElementAnimator.state(of: was, at: t), s1 = ElementAnimator.state(of: o, at: t)
            let dx = (s1?.x ?? o.x) - (s0?.x ?? was.x), dy = (s1?.y ?? o.y) - (s0?.y ?? was.y)
            let k = (s1?.scale ?? (o.scale ?? 1)) / max(0.0001, s0?.scale ?? (was.scale ?? 1))
            ElementLive.set(.init(x: was.x + dx, y: was.y + dy, scale: (was.scale ?? 1) * k), for: o.id)
        }
        for spec in d.layerSpecs(resolve: { sourceURLs[$0]?.path }) where ids.contains(spec.id) { LayerLive.set(spec) }
    }

    /// The drop: the drag becomes one edit (one undo step). `whenShown` runs once the preview shows the dropped things itself (the views then
    /// take their own pictures of them away, so nothing blinks).
    func commitDraft(_ label: String, keyed: Bool, whenShown: (@MainActor () -> Void)? = nil) {
        let lifted = CanvasLift.ids
        let since = isPhoto ? photoRenderGeneration : CompositorStats.framesDrawn
        let d = canvasDraft
        canvasDraft = nil
        if let d, !lifted.isEmpty, !isPhoto { pushLive(d, ids: lifted) }
        CanvasLift.set([])
        var drawn = false
        if let d, canEdit, d.overlays != project.overlays || d.overlayClips != project.overlayClips {
            edit(label, refreshPreview: isPhoto) { p in p.overlays = d.overlays; p.overlayClips = d.overlayClips }
            drawn = isPhoto
        }
        if !lifted.isEmpty && !drawn { if isPhoto { renderPhoto() } else { player.refreshFrame() } }
        if d != nil { endCoalescing() }
        if keyed && !isPhoto { schedulePreviewRefresh() }     // an animated element: the preview is built again with its new keyframe
        NotificationCenter.default.post(name: .canvasDraftChanged, object: self)
        if let whenShown { afterPreviewDraws(since: since, whenShown) }
    }

    /// Lifts things off the preview for a drag (see `CanvasLift`): the preview draws the picture once without them.
    func beginLift(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        CanvasLift.set(ids)
        liftRefreshes += 1
        if isPhoto { renderPhoto() } else { player.refreshFrame() }
    }

    /// Runs `done` once the preview has drawn a picture after `since` (a compositor frame count, or a photo drawing), and the screen has
    /// had time to show it; half a second at most.
    private func afterPreviewDraws(since: Int, _ done: @escaping @MainActor () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        func check() {
            let ready = isPhoto ? photoShownGeneration > since : CompositorStats.framesDrawn > since
            if ready || ProcessInfo.processInfo.systemUptime - start > 0.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + (ready ? 1.0 / 30 : 0)) { MainActor.assumeIsolated { done() } }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { MainActor.assumeIsolated { check() } }
            }
        }
        check()
    }

    /// One thing on the picture as the preview draws it now, for a drag: its pixels, where they lie in a view whose picture is `pic`
    /// (drawn at `scale` pixels per point), the point it turns and grows around, and its opacity. Nil when it cannot be drawn this way
    /// (a video layer, a cut-out subject, a blend): it then moves in the preview as before.
    func liftPicture(_ id: UUID, pic: CGRect, scale: CGFloat) -> (image: CGImage, frame: CGRect, centre: CGPoint, alpha: Double)? {
        guard !player.isPlaying, pic.width > 4, pic.height > 4 else { return nil }
        let size = CGSize(width: (pic.width * scale).rounded(), height: (pic.height * scale).rounded())
        func inView(_ r: CGRect) -> CGRect { CGRect(x: pic.minX + r.minX * pic.width / size.width, y: pic.minY + r.minY * pic.height / size.height, width: r.width * pic.width / size.width, height: r.height * pic.height / size.height) }
        let p = canvasProject
        if let o = p.overlays.first(where: { $0.id == id }) {
            guard let st = elementState(o), let got = CanvasLift.element(o, at: player.currentTime.seconds, size: size, still: isPhoto) else { return nil }
            return (got.image, inView(got.rect), CGPoint(x: pic.minX + st.x * pic.width, y: pic.maxY - st.y * pic.height), got.alpha)
        }
        guard let c = p.overlayClips.first(where: { $0.id == id }), case .image(let path, _) = c.kind,
              c.transform.blend == .normal, !c.transform.isolateSubject, let centre = liftLayerCentre(c, pic: pic) else { return nil }
        let picture: CIImage
        if let hit = liftPictures[path] { picture = hit } else {
            guard let read = PhotoLogo.readImage(path) else { return nil }
            if liftPictures.count > 30 { liftPictures.removeAll() }
            liftPictures[path] = read; picture = read
        }
        let spec: LayerSpec, t: Double
        if isPhoto { spec = CanvasLift.photoSpec(c, path: path); t = CanvasLift.photoLayerTime } else {
            guard let s = p.layerSpecs(resolve: { sourceURLs[$0]?.path }).first(where: { $0.id == id }) else { return nil }
            spec = s; t = player.currentTime.seconds
        }
        guard let got = CanvasLift.layer(spec, picture: picture, at: t, size: size) else { return nil }
        return (got.image, inView(got.rect), centre.centre, c.transform.opacity)
    }

    /// Where a lifted thing is now in the draft (its centre in the view) and how much bigger it is than when it was lifted.
    func liftPlacement(_ id: UUID, pic: CGRect) -> (centre: CGPoint, size: Double)? {
        let p = canvasProject
        if let o = p.overlays.first(where: { $0.id == id }), let st = elementState(o) {
            return (CGPoint(x: pic.minX + st.x * pic.width, y: pic.maxY - st.y * pic.height), st.scale)
        }
        if let c = p.overlayClips.first(where: { $0.id == id }) { return liftLayerCentre(c, pic: pic) }
        return nil
    }

    private func liftLayerCentre(_ c: OverlayClip, pic: CGRect) -> (centre: CGPoint, size: Double)? {
        let t = isPhoto ? MediaTime.zero : player.currentTime
        guard c.state(at: t) != nil else { return nil }
        let st = OverlayEditor.editableState(c, at: t)
        let r = OverlayDrag.rect(st, outputAspect: Double(pic.width / pic.height), layerAspect: layerAspect(c))
        return (CGPoint(x: pic.minX + (r.x0 + r.width / 2) * pic.width, y: pic.maxY - (r.y1 - r.height / 2) * pic.height), r.width)
    }

    /// The player draws the current frame again at most once per screen refresh, however many mouse moves come in.
    private func refreshFrameSoon() {
        guard !frameRefreshQueued else { return }
        frameRefreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            MainActor.assumeIsolated { self?.frameRefreshQueued = false; self?.frameRefreshes += 1; self?.player.refreshFrame() }
        }
    }

    /// A photo is drawn again with the drag at most one at a time: a new drawing starts when the one before is done.
    private func renderPhotoSoon() {
        guard !photoDraftQueued else { return }
        photoDraftQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            MainActor.assumeIsolated { self?.photoDraftQueued = false; self?.renderPhoto() }
        }
    }

    /// A text style dropped on a text that is already on the picture: that text takes the style (its words, place and timing stay).
    func restyleText(_ id: UUID, _ t: TextTemplate) {
        guard canEdit else { return }
        edit(LF("Text style %@", TextPane.templateName(t))) { p in if let i = p.overlays.firstIndex(where: { $0.id == id }) { t.apply(to: &p.overlays[i]) } }
        select(.text(id)); activeTool = .text
    }

    /// The end of a drag on the picture.
    func finishPlacingElement(_ id: UUID, keyed: Bool) {
        commitDraft(L("Move on the picture"), keyed: keyed)
    }
}

/// Sits over the picture: the frames of the things on it. Text, stickers and shapes are handled here; layers and logos have their own
/// view underneath (`OverlayManipulatorView`), except when several things are selected or ⇧/⌘ is held, when this view takes them too.
/// A press on an empty part of the picture starts a selection frame; a click there selects nothing.
@MainActor
final class ElementManipulatorView: NSView {
    private(set) weak var session: EditorSession?
    private var bag = Set<AnyCancellable>()
    /// The picture's rectangle in this view's coordinates, supplied by the host.
    var pictureRect: () -> CGRect = { .zero }
    /// False while something else owns the picture (the photo's crop frame).
    var isActive: () -> Bool = { true }
    /// The layers' frames on screen (from the layers' own view), so they can be selected and moved with the rest.
    var layerFrames: () -> [(id: UUID, frame: CGRect)] = { [] }
    /// False when a press on an empty part of the picture belongs to the view below (a zoomed photo is moved by dragging).
    var takesEmptyClicks: () -> Bool = { true }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    private enum Hit { case corner(TextOverlay, Corner), body(TextOverlay), layer(UUID), empty, none }
    private enum Mode {
        case move(origin: TextOverlay, from: CGPoint)
        case resize(origin: TextOverlay, centre: CGPoint, startDistance: CGFloat)
        case several(ids: Set<UUID>, origin: Project, from: CGPoint)
        case marquee(from: CGPoint, to: CGPoint, adding: Bool)
    }
    private var mode: Mode?
    private var moved = false
    /// The project as it was when the drag began (the draft starts from it at every move).
    private var dragOrigin: Project?
    /// The pictures of what is being dragged (see `CanvasLiftLayers`).
    private lazy var lift = CanvasLiftLayers(host: self)
    private var centerGuides: [CenterGuide] = [] { didSet { if !centerGuides.isEmpty { lastGuideLabels = centerGuides.map(\.label) } } }
    /// What the last drag was centred on (for the self-test).
    private(set) var lastGuideLabels: [String] = []
    /// The frame around everything being moved together, where it was when the drag began.
    private var severalBox: CGRect?
    private let handle: CGFloat = 10
    /// Where something being dragged in would land (drawn as a target while it hovers), in this view's coordinates.
    var dropPoint: CGPoint? { didSet { if dropPoint != oldValue { needsDisplay = true } } }
    /// Where the mouse rests over the picture: only the element under it shows a dashed frame (0.14.4). A frame around every
    /// element, all the time, looked like a border on the sticker or text itself, even with its outline turned off.
    private(set) var hoverPoint: CGPoint? { didSet { if hoverPoint != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseMoved(with e: NSEvent) { hoverPoint = convert(e.locationInWindow, from: nil) }
    override func mouseExited(with e: NSEvent) { hoverPoint = nil }
    /// The element the mouse is over (the topmost one there), whose dashed frame is drawn.
    private func hovered(_ items: [(o: TextOverlay, frame: CGRect)]) -> UUID? {
        guard mode == nil, let p = hoverPoint else { return nil }
        return items.last { $0.frame.contains(p) }?.o.id
    }
    /// For the self-test: the elements drawn with a dashed frame now.
    var testDashedIDs: [UUID] {
        guard let s = session else { return [] }
        let items = visible(), h = hovered(items)
        return items.filter { !(s.canvasSelection.contains($0.o.id) || $0.o.id == s.selectedTextID) && $0.o.id == h }.map(\.o.id)
    }
    func testHover(at p: CGPoint?) { hoverPoint = p }

    func attach(_ s: EditorSession?) {
        session = s
        bag.removeAll()
        s?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.needsDisplay = true
            if let self { self.window?.invalidateCursorRects(for: self) }
        }.store(in: &bag)
        // Elements and layers move with the playhead (animations, keyframes): follow every frame, not the panels' slower pace.
        s?.player.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        // A drag in progress (it is not in the project until the drop).
        NotificationCenter.default.publisher(for: .canvasDraftChanged, object: s).sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        setAccessibilityElement(false)
    }

    // MARK: Geometry

    /// The elements on screen now, bottom first, each with its frame in this view.
    private func visible() -> [(o: TextOverlay, frame: CGRect)] {
        guard let s = session, s.isEditor, isActive() else { return [] }
        let pic = pictureRect()
        guard pic.width > 4, pic.height > 4 else { return [] }
        // Measured on a picture of the output's shape, a thousand points high (the layout scales with the picture).
        let size = CGSize(width: 1000 * pic.width / pic.height, height: 1000)
        return s.canvasProject.overlays.compactMap { o in
            guard let st = s.elementState(o), let base = baseRect(o, size) else { return nil }
            // Moved, scaled and turned like the renderer does, around the element's own centre.
            let c0 = CGPoint(x: o.x, y: o.y), c1 = CGPoint(x: st.x, y: st.y)
            let corners = [CGPoint(x: base.minX, y: base.minY), CGPoint(x: base.maxX, y: base.minY), CGPoint(x: base.minX, y: base.maxY), CGPoint(x: base.maxX, y: base.maxY)].map { p -> CGPoint in
                // In picture points, so a turn keeps its shape on a wide picture.
                var vx = (p.x - c0.x) * pic.width * st.scale, vy = (p.y - c0.y) * pic.height * st.scale
                let a = st.rotation * .pi / 180
                (vx, vy) = (vx * cos(a) - vy * sin(a), vx * sin(a) + vy * cos(a))
                return CGPoint(x: pic.minX + c1.x * pic.width + vx, y: pic.maxY - (c1.y * pic.height + vy))
            }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return (o, r.width < 14 || r.height < 14 ? r.insetBy(dx: min(0, (r.width - 14) / 2), dy: min(0, (r.height - 14) / 2)) : r)
        }
    }

    /// Text laid out once per look (the frames are drawn and the mouse is tested many times a second).
    private var rectCache: [String: CGRect?] = [:]
    private func baseRect(_ o: TextOverlay, _ size: CGSize) -> CGRect? {
        let key = "\(o.id)|\(o.text)|\(o.fontName)|\(o.sizeFraction)|\(o.x)|\(o.y)|\(o.alignment)|\(o.backgroundHex ?? "")|\(String(describing: o.flair))|\(String(describing: o.shape))|\(Int(size.width))"
        if let hit = rectCache[key] { return hit }
        if rectCache.count > 400 { rectCache.removeAll() }
        let r = ElementGeometry.baseRect(o, pictureSize: size)
        rectCache[key] = r
        return r
    }

    private func corners(_ r: CGRect) -> [(Corner, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.bottomRight, CGPoint(x: r.maxX, y: r.minY))]
    }

    /// The one element that shows corners: selected alone and not locked.
    private func handled(_ items: [(o: TextOverlay, frame: CGRect)]) -> (o: TextOverlay, frame: CGRect)? {
        guard let s = session, s.canvasSelection.count <= 1, let sel = items.first(where: { $0.o.id == s.selectedTextID }), !(sel.o.locked ?? false) else { return nil }
        return sel
    }

    private func hit(at p: CGPoint) -> Hit {
        guard let s = session, s.isEditor, isActive() else { return .none }
        let items = visible()
        if let sel = handled(items) {
            for (c, pt) in corners(sel.frame) where hypot(p.x - pt.x, p.y - pt.y) <= handle { return .corner(sel.o, c) }
        }
        for item in items.reversed() where item.frame.contains(p) { return .body(item.o) }
        for l in layerFrames().reversed() where l.frame.contains(p) { return .layer(l.id) }
        return pictureRect().contains(p) ? .empty : .none
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if let f = inlineField, f.frame.contains(p) { return f.hitTest(convert(point, from: superview).applying(.identity)) ?? f }
        if mode != nil { return self }
        let adding = !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty
        switch hit(at: p) {
        case .corner, .body: return self
        case .layer(let id):
            // A layer alone is handled by its own view (corners and all); in a selection of several, or with ⇧/⌘, here.
            guard let s = session else { return nil }
            let grouped = s.project.overlayClips.first { $0.id == id }?.groupID != nil
            return adding || grouped || (s.canvasSelection.count > 1 && s.canvasSelection.contains(id)) ? self : nil
        case .empty: return takesEmptyClicks() ? self : nil
        case .none: return nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let items = visible()
        let several = s.canvasSelection.count > 1
        let corner = handled(items)
        let hover = hovered(items)
        for item in items {
            let r = item.frame
            let selected = s.canvasSelection.contains(item.o.id) || item.o.id == s.selectedTextID
            if selected {
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.stroke(r)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1); ctx.stroke(r.insetBy(dx: -1.5, dy: -1.5))
            } else if item.o.id == hover {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.stroke(r); ctx.setLineDash(phase: 0, lengths: [])
            }
            if item.o.locked ?? false { drawLock(ctx, at: CGPoint(x: r.maxX, y: r.maxY)) }
        }
        if let sel = corner {
            for (_, pt) in corners(sel.frame) {
                let h = CGRect(x: pt.x - handle / 2, y: pt.y - handle / 2, width: handle, height: handle)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: h)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: h)
            }
        }
        // Layers chosen with others (alone, a layer's own view draws its handles).
        for l in layerFrames() {
            let selected = several && s.canvasSelection.contains(l.id)
            if selected {
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.stroke(l.frame)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1); ctx.stroke(l.frame.insetBy(dx: -1.5, dy: -1.5))
            }
            if s.isLocked(l.id) { drawLock(ctx, at: CGPoint(x: l.frame.maxX, y: l.frame.maxY)) }
        }
        if case .marquee(let a, let b, _) = mode {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor); ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1); ctx.stroke(r)
        }
        let pic = pictureRect()
        if let d = dropPoint {
            // A target where the drop will land, with lines to the edges of the picture.
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: pic.minX, y: d.y)); ctx.addLine(to: CGPoint(x: pic.maxX, y: d.y))
            ctx.move(to: CGPoint(x: d.x, y: pic.minY)); ctx.addLine(to: CGPoint(x: d.x, y: pic.maxY)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
            let r = CGRect(x: d.x - 14, y: d.y - 14, width: 28, height: 28)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor); ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2); ctx.strokeEllipse(in: r)
        }
        CenterSnap.draw(centerGuides, in: ctx)
    }

    private func drawLock(_ ctx: CGContext, at p: CGPoint) {
        let r = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.fillEllipse(in: r)
        ("🔒" as NSString).draw(at: CGPoint(x: r.minX + 3, y: r.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
    }

    override func resetCursorRects() {
        guard let s = session else { return }
        let items = visible()
        for item in items { addCursorRect(item.frame, cursor: (item.o.locked ?? false) ? .arrow : .openHand) }
        if let sel = handled(items) {
            for (_, pt) in corners(sel.frame) { addCursorRect(CGRect(x: pt.x - handle, y: pt.y - handle, width: handle * 2, height: handle * 2), cursor: .crosshair) }
        }
        if s.canvasSelection.count > 1 { for l in layerFrames() where s.canvasSelection.contains(l.id) { addCursorRect(l.frame, cursor: .openHand) } }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard let s = session else { return }
        window?.makeFirstResponder(self)          // the keys (⌫, arrows) then go to the picture, not to a text field on the right
        let p = convert(e.locationInWindow, from: nil)
        moved = false
        if inlineField != nil { finishTyping(keep: true) }        // a click elsewhere on the picture ends the typing
        let adding = !e.modifierFlags.intersection([.shift, .command]).isEmpty
        switch hit(at: p) {
        case .corner(let o, _):
            guard let f = visible().first(where: { $0.o.id == o.id })?.frame else { return }
            let c = CGPoint(x: f.midX, y: f.midY)
            mode = .resize(origin: o, centre: c, startDistance: max(4, hypot(p.x - c.x, p.y - c.y)))
            dragOrigin = s.project
        case .body(let o):
            if adding { s.toggleCanvas(o.id); mode = nil; return }
            if e.clickCount == 2, o.shape == nil, !(o.locked ?? false) {
                // A double click on a text: type in it right there.
                s.select(.text(o.id)); s.activeTool = .text
                beginTyping(o.id); mode = nil; return
            }
            if !s.canvasSelection.contains(o.id) { s.select(.text(o.id)) } else if s.selectedTextID != o.id, s.canvasSelection.count > 1 { s.selectedTextID = o.id; s.selectedOverlayID = nil }
            s.activeTool = .text
            if o.locked ?? false { mode = nil; return }
            if s.canvasSelection.count > 1 { mode = .several(ids: s.canvasSelection, origin: s.project, from: p) }
            else { mode = .move(origin: o, from: p); NSCursor.closedHand.set() }
            dragOrigin = s.project
        case .layer(let id):
            if adding { s.toggleCanvas(id); mode = nil; return }
            if !s.canvasSelection.contains(id) { s.select(.layer(id)) }
            s.activeTool = .layers
            mode = s.isLocked(id) ? nil : .several(ids: s.canvasSelection, origin: s.project, from: p)
        case .empty:
            if e.clickCount == 2 { superview?.mouseDown(with: e); return }     // a photo zooms in and out on a double click
            mode = .marquee(from: p, to: p, adding: adding)
        case .none: mode = nil
        }
    }

    /// Everything on the picture but `ids`, with a name and its frame (what a moved thing may be centred on).
    func things(excluding ids: Set<UUID>) -> [(name: String, frame: CGRect)] {
        visible().filter { !ids.contains($0.o.id) }.map { ($0.o.shape.map { TextPane.shapeName($0.kind) } ?? "“\($0.o.text.prefix(20))”", $0.frame) }
            + layerFrames().filter { !ids.contains($0.id) }.map { l in (session?.canvasProject.overlayClips.first { $0.id == l.id }?.name ?? L("Layer"), l.frame) }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = session, let mode else { return }
        if case .several(let ids, _, _) = mode, severalBox == nil {
            let frames = visible().filter { ids.contains($0.o.id) }.map(\.frame) + layerFrames().filter { ids.contains($0.id) }.map(\.frame)
            severalBox = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
        }
        let pic = pictureRect()
        guard pic.width > 4, pic.height > 4 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let first = !moved
        moved = true
        if first {
            // The drag really starts: what moves is lifted off the preview and drawn here.
            switch mode {
            case .move(let o, _), .resize(let o, _, _): lift.lift([o.id], session: s, pic: pic)
            case .several(let ids, let origin, _): lift.lift(CanvasSelection.movable(ids, in: origin), session: s, pic: pic)
            case .marquee: break
            }
        }
        switch mode {
        case .move(let o, let from):
            var dx = Double((p.x - from.x) / pic.width), dy = Double(-(p.y - from.y) / pic.height)
            centerGuides = []
            if !e.modifierFlags.contains(.option), let st = s.elementState(o) {
                // The centre clings to the middle of the picture, or of the thing it lies on, and says so (⌥ turns it off).
                let c = CGPoint(x: pic.minX + CGFloat(st.x + dx) * pic.width, y: pic.maxY - CGFloat(st.y + dy) * pic.height)
                let snap = CenterSnap.snap(c, picture: pic, things: things(excluding: [o.id]))
                // Placed exactly on the line (not a hair off from turning points back into fractions).
                for g in snap.guides {
                    if g.vertical { dx = Double((g.at - pic.minX) / pic.width) - st.x } else { dy = Double((pic.maxY - g.at) / pic.height) - st.y }
                }
                centerGuides = snap.guides
            }
            guard var d = dragOrigin else { return }
            s.place(o.id, in: &d, from: o, dx: dx, dy: dy, scaleBy: 1)
            s.showDraft(d, ids: [o.id]); lift.follow(s, pic: pic)
        case .resize(let o, let c, let d0):
            guard var d = dragOrigin else { return }
            s.place(o.id, in: &d, from: o, dx: 0, dy: 0, scaleBy: Double(max(4, hypot(p.x - c.x, p.y - c.y)) / d0))
            s.showDraft(d, ids: [o.id]); lift.follow(s, pic: pic)
        case .several(let ids, let origin, let from):
            var dx = p.x - from.x, dy = p.y - from.y
            centerGuides = []
            if !e.modifierFlags.contains(.option), let box = severalBox {
                let snap = CenterSnap.snap(CGPoint(x: box.midX + dx, y: box.midY + dy), picture: pic, things: things(excluding: ids))
                dx += snap.dx; dy += snap.dy; centerGuides = snap.guides
            }
            let ok = CanvasSelection.movable(ids, in: origin)
            var d = origin
            CanvasSelection.nudge(ok, dx: Double(dx / pic.width), dy: Double(-dy / pic.height), in: &d)
            s.showDraft(d, ids: ok); lift.follow(s, pic: pic)
        case .marquee(let a, _, let adding):
            self.mode = .marquee(from: a, to: p, adding: adding)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let mode, let s = session {
            switch mode {
            case .move(let o, _): if moved { s.commitDraft("Move on the picture", keyed: !(o.keyframes ?? []).isEmpty, whenShown: lift.drop()) }
            case .resize(let o, _, _): if moved { s.commitDraft("Resize on the picture", keyed: !(o.keyframes ?? []).isEmpty, whenShown: lift.drop()) }
            case .several: if moved { s.commitDraft("Move", keyed: false, whenShown: lift.drop()) }
            case .marquee(let a, let b, let adding):
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                if moved, r.width > 3 || r.height > 3 {
                    let inside = Set(visible().filter { $0.frame.intersects(r) }.map(\.o.id)).union(layerFrames().filter { $0.frame.intersects(r) }.map(\.id))
                    let next = adding ? s.canvasSelection.union(inside) : inside
                    if next.isEmpty { s.select(.none) } else { s.selectCanvas(next) }
                } else if !adding {
                    s.select(.none)            // a click on an empty part of the picture
                }
            }
        }
        mode = nil; centerGuides = []; severalBox = nil; dragOrigin = nil; needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let s = session else { return nil }
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .body(let o): if !s.canvasSelection.contains(o.id) { s.select(.text(o.id)) }
        case .layer(let id): if !s.canvasSelection.contains(id) { s.select(.layer(id)) }
        default: break
        }
        return canvasMenu(s)
    }

    /// The text (not a shape) under a point of this view, if any.
    func textElement(at p: CGPoint) -> TextOverlay? { visible().reversed().first { $0.o.shape == nil && $0.frame.contains(p) }?.o }

    // MARK: Typing on the picture

    private var inlineField: InlineTextField?
    private var typingID: UUID?
    private var typingOriginal = ""

    /// Opens a field over a text on the picture, with its words selected, in its own font, size and colour (0.13).
    func beginTyping(_ id: UUID) {
        guard let s = session, let item = visible().first(where: { $0.o.id == id }) else { return }
        finishTyping(keep: true)
        let o = item.o, pic = pictureRect()
        let scale = s.elementState(o)?.scale ?? (o.scale ?? 1)
        let size = max(12, min(120, CGFloat(o.sizeFraction) * pic.height * scale))
        let f = InlineTextField(string: o.text)
        f.font = NSFont(name: o.fontName, size: size) ?? .boldSystemFont(ofSize: size)
        f.textColor = NSColor(cgColor: OverlayRendererBridge.color(o.colorHex)) ?? .white
        f.backgroundColor = NSColor.black.withAlphaComponent(0.55); f.drawsBackground = true
        f.isBordered = false; f.focusRingType = .none
        f.alignment = o.alignment == .left ? .left : (o.alignment == .right ? .right : .center)
        f.cell?.wraps = true; f.cell?.isScrollable = false; f.maximumNumberOfLines = 0; f.usesSingleLineMode = false
        f.delegate = self
        f.setAccessibilityLabel(L("Text"))
        let w = max(item.frame.width + 24, 160), h = max(item.frame.height + 12, size * 1.5)
        f.frame = CGRect(x: item.frame.midX - w / 2, y: item.frame.midY - h / 2, width: w, height: h).intersection(bounds.insetBy(dx: 2, dy: 2))
        addSubview(f)
        inlineField = f; typingID = id; typingOriginal = o.text
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// Ends the typing: keeps what was typed (one undo step), or puts the words back (Esc).
    func finishTyping(keep: Bool) {
        guard let f = inlineField, let id = typingID, let s = session else { return }
        inlineField = nil; typingID = nil
        if !keep, f.stringValue != typingOriginal { s.edit("Edit text", coalesce: "inline-\(id)") { p in if let i = p.overlays.firstIndex(where: { $0.id == id }) { p.overlays[i].text = self.typingOriginal } } }
        s.endCoalescing()
        f.delegate = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: For the self-test

    /// The field open over a text being typed in, if any.
    var testTypingField: NSTextField? { inlineField }

    /// The frame of an element on screen, in this view's coordinates.
    func testFrame(of id: UUID) -> CGRect? { visible().first { $0.o.id == id }?.frame }
    /// Where the picture of a thing being dragged is on screen, and what is lifted (for the self-test).
    func testLiftFrame(of id: UUID) -> CGRect? { lift.frame(of: id) }
    var testLifted: Set<UUID> { lift.ids }
    var testLiftShowing: Int { lift.showing }
}

extension ElementManipulatorView: NSTextFieldDelegate {
    /// Each change shows on the picture (the typing is one undo step).
    func controlTextDidChange(_ obj: Notification) {
        guard let f = inlineField, let id = typingID, let s = session else { return }
        let text = f.stringValue
        s.edit("Edit text", coalesce: "inline-\(id)") { p in if let i = p.overlays.firstIndex(where: { $0.id == id }) { p.overlays[i].text = text } }
    }

    /// Return ends the typing; ⌥Return starts a new line; Esc puts the words back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): finishTyping(keep: true); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): textView.insertText("\n", replacementRange: textView.selectedRange()); controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); return true
        case #selector(NSResponder.cancelOperation(_:)): finishTyping(keep: false); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { if inlineField != nil { finishTyping(keep: true) } }
}

/// The field for typing in a text on the picture.
final class InlineTextField: NSTextField {
    convenience init(string: String) { self.init(frame: .zero); stringValue = string; isEditable = true; isSelectable = true }
}

/// The menu for things on the picture (right click): what can be done with what is selected.
@MainActor
func canvasMenu(_ s: EditorSession) -> NSMenu? {
    guard !s.canvasSelection.isEmpty else { return nil }
    let m = NSMenu()
    func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], enabled: Bool = true, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(CanvasMenuTarget.run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        let target = CanvasMenuTarget(action); item.target = target; item.representedObject = target; item.isEnabled = enabled
        m.addItem(item)
    }
    m.autoenablesItems = false
    add(L("Duplicate"), "d") { s.duplicateSelection() }
    add(L("Delete"), "\u{8}", []) { s.deleteSelection() }
    m.addItem(.separator())
    add(L("Group"), "g", enabled: s.canvasSelection.count > 1) { s.groupCanvas() }
    add(L("Ungroup"), "g", [.command, .shift], enabled: s.canvasHasGroup) { s.ungroupCanvas() }
    add(s.canvasAllLocked ? L("Unlock") : L("Lock"), "l") { s.toggleLockCanvas() }
    return m
}

final class CanvasMenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { MainActor.assumeIsolated { action() } }
}

/// Turns a point of a view into a place on the picture (fractions from the top-left), nil outside the picture.
func pictureFraction(_ p: CGPoint, in pic: CGRect) -> CGPoint? {
    guard pic.width > 1, pic.height > 1, pic.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
    return CGPoint(x: min(max((p.x - pic.minX) / pic.width, 0), 1), y: min(max((pic.maxY - p.y) / pic.height, 0), 1))
}

// MARK: Centring

/// A line drawn while something being dragged sits at a centre: of the picture, or of the thing under it that it lies inside.
struct CenterGuide: Equatable {
    var vertical: Bool
    /// Where the line is (x for a vertical one, y for a horizontal one), and how far it runs, in view coordinates.
    var at: CGFloat, from: CGFloat, to: CGFloat
    var label: String
}

enum CenterSnap {
    /// Moves a centre `c` onto the nearest centre within `tolerance` points: the picture's, or that of a thing whose frame holds `c`
    /// (text on a shape, a sticker on a logo…). Returns the shift to apply and the lines to draw.
    static func snap(_ c: CGPoint, picture: CGRect, things: [(name: String, frame: CGRect)], tolerance: CGFloat = 7) -> (dx: CGFloat, dy: CGFloat, guides: [CenterGuide]) {
        var xs: [(at: CGFloat, from: CGFloat, to: CGFloat, label: String, size: CGFloat)] = [(picture.midX, picture.minY, picture.maxY, L("Centre of the picture"), picture.width)]
        var ys: [(at: CGFloat, from: CGFloat, to: CGFloat, label: String, size: CGFloat)] = [(picture.midY, picture.minX, picture.maxX, L("Centre of the picture"), picture.height)]
        for t in things where t.frame.insetBy(dx: -2, dy: -2).contains(c) {
            xs.append((t.frame.midX, t.frame.minY, t.frame.maxY, LF("Centre of %@", t.name), t.frame.width))
            ys.append((t.frame.midY, t.frame.minX, t.frame.maxX, LF("Centre of %@", t.name), t.frame.height))
        }
        // The nearest; on a tie the smaller thing (the one it was put on) wins over the picture.
        func best(_ list: [(at: CGFloat, from: CGFloat, to: CGFloat, label: String, size: CGFloat)], _ v: CGFloat) -> (at: CGFloat, from: CGFloat, to: CGFloat, label: String, size: CGFloat)? {
            list.filter { abs($0.at - v) <= tolerance }.min { (abs($0.at - v), $0.size) < (abs($1.at - v), $1.size) }
        }
        var guides: [CenterGuide] = []
        var dx: CGFloat = 0, dy: CGFloat = 0
        if let b = best(xs, c.x) { dx = b.at - c.x; guides.append(CenterGuide(vertical: true, at: b.at, from: b.from, to: b.to, label: b.label)) }
        if let b = best(ys, c.y) { dy = b.at - c.y; guides.append(CenterGuide(vertical: false, at: b.at, from: b.from, to: b.to, label: b.label)) }
        return (dx, dy, guides)
    }

    /// Draws the lines, and one label saying what it is centred on.
    static func draw(_ guides: [CenterGuide], in ctx: CGContext) {
        guard !guides.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemPink.cgColor); ctx.setLineWidth(1.5)
        for g in guides {
            if g.vertical { ctx.move(to: CGPoint(x: g.at, y: g.from)); ctx.addLine(to: CGPoint(x: g.at, y: g.to)) }
            else { ctx.move(to: CGPoint(x: g.from, y: g.at)); ctx.addLine(to: CGPoint(x: g.to, y: g.at)) }
            ctx.strokePath()
        }
        // "Centred" + what on: both directions on the same thing say so once.
        let both = guides.count == 2 && guides[0].label == guides[1].label
        let text = (both ? LF("Centred: %@", guides[0].label) : guides.map { ($0.vertical ? "↔ " : "↕ ") + $0.label }.joined(separator: "   ")) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let v = guides.first { $0.vertical }, h = guides.first { !$0.vertical }
        let anchor = CGPoint(x: (v?.at ?? ((h?.from ?? 0) + (h?.to ?? 0)) / 2), y: (h?.at ?? ((v?.from ?? 0) + (v?.to ?? 0)) / 2))
        let box = CGRect(x: anchor.x - size.width / 2 - 8, y: anchor.y + 10, width: size.width + 16, height: size.height + 6)
        ctx.setFillColor(NSColor.systemPink.cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil)); ctx.fillPath()
        ctx.restoreGState()
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attrs)
    }
}
