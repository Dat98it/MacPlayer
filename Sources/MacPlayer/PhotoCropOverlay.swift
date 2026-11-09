import AppKit
import Combine
import MacPlayerCore

/// The crop frame on a photo: the part that stays is clear, the rest is dimmed, with thirds lines and handles on the corners and edges.
/// Drag a handle to resize, drag inside to move. The arithmetic is `CropGeometry` (tested); this view turns the mouse into those numbers.
@MainActor
final class PhotoCropOverlayView: NSView {
    private weak var session: EditorSession?
    private weak var host: PhotoHostView?
    private var bag = Set<AnyCancellable>()
    private var dragging: (handle: CropGeometry.Handle, from: CGPoint, start: CropRect)?
    private let grab: CGFloat = 12

    init(session: EditorSession, host: PhotoHostView) {
        self.session = session; self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsDisplay = true; self?.window?.invalidateCursorRects(for: self ?? NSView()) }.store(in: &bag)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var active: Bool { session?.photoCropEditing == true }

    /// The frame in this view's coordinates (AppKit's y points up; the fractions count down from the top).
    private func frameRect(_ pic: CGRect, _ r: CropRect) -> CGRect {
        CGRect(x: pic.minX + r.x * pic.width, y: pic.maxY - (r.y + r.height) * pic.height, width: r.width * pic.width, height: r.height * pic.height)
    }

    private func handlePoints(_ f: CGRect) -> [(CropGeometry.Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: f.minX, y: f.maxY)), (.top, CGPoint(x: f.midX, y: f.maxY)), (.topRight, CGPoint(x: f.maxX, y: f.maxY)), (.right, CGPoint(x: f.maxX, y: f.midY)),
         (.bottomRight, CGPoint(x: f.maxX, y: f.minY)), (.bottom, CGPoint(x: f.midX, y: f.minY)), (.bottomLeft, CGPoint(x: f.minX, y: f.minY)), (.left, CGPoint(x: f.minX, y: f.midY))]
    }

    private func hit(_ p: CGPoint) -> CropGeometry.Handle? {
        guard active, let s = session, let pic = host?.pictureRect(), pic.width > 1 else { return nil }
        let f = frameRect(pic, s.photoCropFrame)
        for (h, pt) in handlePoints(f) where hypot(p.x - pt.x, p.y - pt.y) <= grab { return h }
        // Along an edge, between the handles, also resizes.
        if abs(p.x - f.minX) <= grab / 2, p.y >= f.minY, p.y <= f.maxY { return .left }
        if abs(p.x - f.maxX) <= grab / 2, p.y >= f.minY, p.y <= f.maxY { return .right }
        if abs(p.y - f.minY) <= grab / 2, p.x >= f.minX, p.x <= f.maxX { return .bottom }
        if abs(p.y - f.maxY) <= grab / 2, p.x >= f.minX, p.x <= f.maxX { return .top }
        return f.contains(p) ? .move : nil
    }

    // Only the frame takes the mouse; everywhere else it goes on to the picture (moving it when it is zoomed in).
    override func hitTest(_ point: NSPoint) -> NSView? { hit(convert(point, from: superview)) == nil && dragging == nil ? nil : self }

    override func draw(_ dirtyRect: NSRect) {
        guard active, let s = session, let pic = host?.pictureRect(), pic.width > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = frameRect(pic, s.photoCropFrame)
        // Dim everything of the picture outside the frame.
        ctx.saveGState()
        ctx.addRect(pic.intersection(bounds)); ctx.addRect(f); ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.fill(pic)
        ctx.restoreGState()
        // Thirds.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(1)
        for i in 1...2 {
            let x = f.minX + f.width * CGFloat(i) / 3, y = f.minY + f.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: f.minY)); ctx.addLine(to: CGPoint(x: x, y: f.maxY))
            ctx.move(to: CGPoint(x: f.minX, y: y)); ctx.addLine(to: CGPoint(x: f.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2); ctx.stroke(f)
        // Handles: corners as L shapes, edges as short bars.
        ctx.setFillColor(NSColor.white.cgColor)
        for (h, pt) in handlePoints(f) {
            let r: CGRect
            switch h {
            case .top, .bottom: r = CGRect(x: pt.x - 14, y: pt.y - 2.5, width: 28, height: 5)
            case .left, .right: r = CGRect(x: pt.x - 2.5, y: pt.y - 14, width: 5, height: 28)
            default: r = CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)
            }
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
        }
        // The size the saved photo will have.
        if let out = s.photoOutputSize {
            let text = "\(Int(out.width)) × \(Int(out.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            let box = CGRect(x: f.midX - size.width / 2 - 6, y: max(bounds.minY + 4, f.minY - size.height - 12), width: size.width + 12, height: size.height + 4)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
            text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
        }
    }

    override func resetCursorRects() {
        guard active, let s = session, let pic = host?.pictureRect(), pic.width > 1 else { return }
        let f = frameRect(pic, s.photoCropFrame)
        addCursorRect(f, cursor: .openHand)
        for (h, pt) in handlePoints(f) {
            let c: NSCursor = (h == .left || h == .right) ? .resizeLeftRight : ((h == .top || h == .bottom) ? .resizeUpDown : .crosshair)
            addCursorRect(CGRect(x: pt.x - grab, y: pt.y - grab, width: grab * 2, height: grab * 2), cursor: c)
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard let s = session else { return }
        let p = convert(e.locationInWindow, from: nil)
        if let h = hit(p) { dragging = (h, p, s.photoCropFrame) }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = dragging, let s = session, let pic = host?.pictureRect(), pic.width > 1, pic.height > 1 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let dx = Double((p.x - d.from.x) / pic.width), dy = Double(-(p.y - d.from.y) / pic.height)
        s.setPhotoCropFrame(CropGeometry.drag(d.handle, from: d.start, dx: dx, dy: dy, ratio: s.photoCropRatio, pictureAspect: s.photoShownAspect))
    }

    override func mouseUp(with e: NSEvent) {
        dragging = nil
        session?.endCoalescing()
    }
}
