import AppKit
import Combine
import MacPlayerCore

/// The picture area for a photo: the picture drawn as large as fits, which can be zoomed (pinch, ⌘-scroll, the buttons) and moved by dragging
/// once it is larger than the window. Dropping files on it opens them, as on a video.
@MainActor
final class PhotoHostView: NSView {
    private weak var session: EditorSession?
    private let imageLayer = CALayer()
    private var bag = Set<AnyCancellable>()
    private var shown: CGImage?
    private var dragFrom: CGPoint?
    private var offsetAtDragStart = CGSize.zero
    var onDropFiles: (([URL]) -> Void)?
    private var crop: PhotoCropOverlayView?
    private var animationTimer: Timer?
    private var frameIndex = 0

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.minificationFilter = .trilinear; imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        registerForDraggedTypes([.fileURL])
        session.$photoImage.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsLayout = true }.store(in: &bag)
        session.$photoZoom.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsLayout = true; self?.window?.invalidateCursorRects(for: self ?? NSView()) }.store(in: &bag)
        session.$photoOffset.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsLayout = true }.store(in: &bag)
        session.$photoFrames.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.frameIndex = 0; self?.restartAnimation() }.store(in: &bag)
        session.$photoPlaying.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.restartAnimation() }.store(in: &bag)
        setAccessibilityLabel(L("Photo")); setAccessibilityRole(.group)
        let overlay = PhotoCropOverlayView(session: session, host: self)
        addSubview(overlay); crop = overlay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Where the picture is inside this view, for the zoom it has now.
    func pictureRect() -> CGRect {
        guard let s = session, let img = s.photoImage, img.width > 0, img.height > 0, bounds.width > 1, bounds.height > 1 else { return .zero }
        let fit = min(bounds.width / CGFloat(img.width), bounds.height / CGFloat(img.height))
        let w = CGFloat(img.width) * fit * s.photoZoom, h = CGFloat(img.height) * fit * s.photoZoom
        // Moved only as far as keeps the picture covering the window; smaller than the window it stays in the middle.
        let maxX = max(0, (w - bounds.width) / 2), maxY = max(0, (h - bounds.height) / 2)
        let ox = min(max(s.photoOffset.width, -maxX), maxX), oy = min(max(s.photoOffset.height, -maxY), maxY)
        return CGRect(x: (bounds.width - w) / 2 + ox, y: (bounds.height - h) / 2 + oy, width: w, height: h)
    }

    override func layout() {
        super.layout()
        guard let s = session else { return }
        if let img = s.photoImage, shown !== img, animationTimer == nil { shown = img; imageLayer.contents = img }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = pictureRect()
        imageLayer.isHidden = s.photoImage == nil
        CATransaction.commit()
        crop?.frame = bounds
        crop?.needsDisplay = true
    }

    // MARK: Animation

    /// Plays the frames of an animated picture (GIF, animated PNG or WebP) when it is playing, one after the other for the time each stays.
    private func restartAnimation() {
        animationTimer?.invalidate(); animationTimer = nil
        guard let s = session, s.photoFrames.count > 1, s.photoPlaying, let a = s.photoAnimation, a.delays.count == s.photoFrames.count else {
            shown = nil; needsLayout = true          // back to the one picture
            return
        }
        showFrame()
    }

    private func showFrame() {
        guard let s = session, s.photoFrames.count > 1, s.photoPlaying, let a = s.photoAnimation, a.delays.count == s.photoFrames.count else { return }
        let i = frameIndex % s.photoFrames.count
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = s.photoFrames[i]
        CATransaction.commit()
        animationTimer = Timer.scheduledTimer(withTimeInterval: a.delays[i], repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameIndex += 1; self?.showFrame() }
        }
    }

    deinit { MainActor.assumeIsolated { animationTimer?.invalidate() } }

    /// The zoom at which one pixel of the saved picture is one pixel on the screen.
    func actualPixelsZoom() -> CGFloat {
        guard let s = session, let out = s.photoOutputSize, let img = s.photoImage, img.width > 0 else { return 1 }
        let scale = window?.backingScaleFactor ?? 2
        let fitWidth = min(bounds.width / CGFloat(img.width), bounds.height / CGFloat(img.height)) * CGFloat(img.width)
        return max(1, min(16, (out.width / scale) / max(1, fitWidth)))
    }

    // MARK: Mouse and trackpad

    override func magnify(with event: NSEvent) {
        guard let s = session else { return }
        s.photoZoom = min(16, max(1, s.photoZoom * (1 + event.magnification)))
        if s.photoZoom == 1 { s.photoOffset = .zero }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = session else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            s.photoZoom = min(16, max(1, s.photoZoom * (1 + event.scrollingDeltaY * 0.01)))
            if s.photoZoom == 1 { s.photoOffset = .zero }
        } else if s.photoZoom > 1 {
            s.photoOffset = CGSize(width: s.photoOffset.width + event.scrollingDeltaX, height: s.photoOffset.height - event.scrollingDeltaY)
        } else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let s = session else { return }
        if event.clickCount == 2 {
            if s.photoZoom > 1 { s.photoFit() } else { s.photoZoom = max(2, actualPixelsZoom()) }
            return
        }
        dragFrom = convert(event.locationInWindow, from: nil); offsetAtDragStart = s.photoOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = session, s.photoZoom > 1, let from = dragFrom else { return }
        let p = convert(event.locationInWindow, from: nil)
        s.photoOffset = CGSize(width: offsetAtDragStart.width + p.x - from.x, height: offsetAtDragStart.height + p.y - from.y)
    }

    override func mouseUp(with event: NSEvent) { dragFrom = nil }

    override func resetCursorRects() { if (session?.photoZoom ?? 1) > 1 { addCursorRect(bounds, cursor: .openHand) } }

    // MARK: Dropping files

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
