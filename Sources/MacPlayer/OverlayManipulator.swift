import AppKit
import Combine
import MacPlayerCore

/// Sits on top of the picture and lets a layer be dragged where it is: drag the body to move, drag a corner to resize
/// (the opposite corner stays put). Snaps to the centre and the margins; hold ⌥ to turn snapping off.
/// All the arithmetic is `OverlayDrag` (tested); this view only turns the mouse into those numbers and draws handles.
/// Keyboard and VoiceOver users have the same controls as sliders in the Layers tool.
@MainActor
final class OverlayManipulatorView: NSView {
    private weak var session: EditorSession?
    private var bag = Set<AnyCancellable>()
    /// The picture's rectangle in this view's coordinates, supplied by the host.
    var videoRect: () -> CGRect = { .zero }

    private enum Mode { case move(start: OverlayState, from: CGPoint), resize(corner: OverlayDrag.Corner, start: OverlayState) }
    private enum Hit { case handle(OverlayClip, OverlayDrag.Corner), body(OverlayClip), none }
    private var mode: Mode?
    private var guides: (x: Double?, y: Double?) = (nil, nil)
    private let handleSize: CGFloat = 10

    func attach(_ s: EditorSession?) {
        session = s
        bag.removeAll()
        s?.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.needsDisplay = true
            self?.window?.invalidateCursorRects(for: self ?? NSView())
        }.store(in: &bag)
        setAccessibilityElement(false)
    }

    // MARK: Geometry

    private func outputAspect(_ video: CGRect) -> Double { video.height > 0 ? Double(video.width / video.height) : 16.0 / 9 }

    /// Layers on screen at the playhead, lowest line first, with the values the picture shows now.
    private func visible() -> [(clip: OverlayClip, state: OverlayState)] {
        guard let s = session, s.isProject else { return [] }
        let t = s.player.currentTime
        return s.project.overlayClips.compactMap { c in
            c.state(at: t) == nil ? nil : (c, OverlayEditor.editableState(c, at: t))
        }.sorted { $0.clip.lane < $1.clip.lane }
    }

    private func rect(_ clip: OverlayClip, _ st: OverlayState, video: CGRect) -> CGRect {
        guard let s = session else { return .zero }
        let r = OverlayDrag.rect(st, outputAspect: outputAspect(video), layerAspect: s.layerAspect(clip))
        return CGRect(x: video.minX + r.x0 * video.width, y: video.maxY - r.y1 * video.height, width: r.width * video.width, height: r.height * video.height)
    }

    private func cornerPoints(_ r: CGRect) -> [(OverlayDrag.Corner, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.topRight, CGPoint(x: r.maxX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.bottomRight, CGPoint(x: r.maxX, y: r.minY))]
    }

    private func hit(at p: CGPoint) -> Hit {
        let video = videoRect()
        guard video.width > 1, let s = session else { return .none }
        let items = visible()
        if let sel = items.first(where: { $0.clip.id == s.selectedOverlayID }) {
            let r = rect(sel.clip, sel.state, video: video)
            for (corner, pt) in cornerPoints(r) where hypot(p.x - pt.x, p.y - pt.y) <= handleSize { return .handle(sel.clip, corner) }
            if r.contains(p) { return .body(sel.clip) }
        }
        for item in items.reversed() where rect(item.clip, item.state, video: video).contains(p) { return .body(item.clip) }
        return .none
    }

    // Only the layers (and the selected one's handles) take the mouse; everywhere else it passes through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if case .none = hit(at: convert(point, from: superview)) { return mode == nil ? nil : self }
        return self
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let video = videoRect()
        guard video.width > 1, let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        for item in visible() {
            let r = rect(item.clip, item.state, video: video)
            if item.clip.id == s.selectedOverlayID {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor); ctx.fill(r)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(2); ctx.stroke(r)
                for (_, pt) in cornerPoints(r) {
                    let h = CGRect(x: pt.x - handleSize / 2, y: pt.y - handleSize / 2, width: handleSize, height: handleSize)
                    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(h)
                    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1.5); ctx.stroke(h)
                }
            } else {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3]); ctx.stroke(r); ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        ctx.setStrokeColor(NSColor.systemYellow.cgColor); ctx.setLineWidth(1)
        if let gx = guides.x { let x = video.minX + gx * video.width; ctx.move(to: CGPoint(x: x, y: video.minY)); ctx.addLine(to: CGPoint(x: x, y: video.maxY)); ctx.strokePath() }
        if let gy = guides.y { let y = video.maxY - gy * video.height; ctx.move(to: CGPoint(x: video.minX, y: y)); ctx.addLine(to: CGPoint(x: video.maxX, y: y)); ctx.strokePath() }
    }

    override func resetCursorRects() {
        let video = videoRect()
        guard video.width > 1, let s = session, let sel = visible().first(where: { $0.clip.id == s.selectedOverlayID }) else { return }
        let r = rect(sel.clip, sel.state, video: video)
        addCursorRect(r, cursor: .openHand)
        for (_, pt) in cornerPoints(r) { addCursorRect(CGRect(x: pt.x - handleSize, y: pt.y - handleSize, width: handleSize * 2, height: handleSize * 2), cursor: .crosshair) }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard let s = session else { return }
        let p = convert(e.locationInWindow, from: nil)
        switch hit(at: p) {
        case .handle(let c, let corner):
            guard let st = visible().first(where: { $0.clip.id == c.id })?.state else { return }
            mode = .resize(corner: corner, start: st)
        case .body(let c):
            if s.selectedOverlayID != c.id { s.selectedOverlayID = c.id; s.selectedClipIDs = []; s.activeTool = .layers }
            guard let st = visible().first(where: { $0.clip.id == c.id })?.state else { return }
            mode = .move(start: st, from: p)
        case .none: mode = nil
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = session, let mode, let id = s.selectedOverlayID, let clip = s.project.overlayClips.first(where: { $0.id == id }) else { return }
        let video = videoRect()
        guard video.width > 1, video.height > 1 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let oa = outputAspect(video), la = s.layerAspect(clip)
        var next: OverlayState
        switch mode {
        case .move(let start, let from):
            next = OverlayDrag.move(start, dx: Double((p.x - from.x) / video.width), dy: Double(-(p.y - from.y) / video.height))
            if e.modifierFlags.contains(.option) { guides = (nil, nil) }
            else {
                let sn = OverlayDrag.snapped(next, outputAspect: oa, layerAspect: la, tolerance: Double(6 / video.width))
                next = sn.state; guides = (sn.guideX, sn.guideY)
            }
        case .resize(let corner, let start):
            let point = (x: Double((p.x - video.minX) / video.width), y: Double(1 - (p.y - video.minY) / video.height))
            next = OverlayDrag.resize(start, corner: corner, to: point, outputAspect: oa, layerAspect: la)
            guides = (nil, nil)
        }
        s.setOverlayValue(id, "drag") { $0.centerX = next.centerX; $0.centerY = next.centerY; $0.width = next.width }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        session?.endCoalescing()
        mode = nil; guides = (nil, nil)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}
