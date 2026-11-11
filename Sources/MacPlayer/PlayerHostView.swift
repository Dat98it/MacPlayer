import AVKit
import AppKit
import MacPlayerCore

/// The picture area: the player, a drop target for videos and folders, and the "what went wrong" overlay.
@MainActor
final class PlayerHostView: NSView {
    let playerView = AVPlayerView()
    private let message = NSTextField(wrappingLabelWithString: "")
    let manipulator = OverlayManipulatorView()
    /// Text, stickers and shapes, moved and sized right on the picture (above the layers, as they are drawn).
    let elements = ElementManipulatorView()
    /// Used when the player has not reported the picture's rectangle yet.
    var fallbackAspect: () -> Double = { 16.0 / 9 }
    var onDropFiles: (([URL]) -> Void)?
    /// Something dragged from the library and dropped on the picture, with where (fractions of the picture from its top-left).
    var onDropPayload: ((DragPayload, CGPoint?) -> Void)?
    /// Pictures dropped on the picture: they go there as layers.
    var onDropPictures: (([URL], CGPoint?) -> Void)?
    var zoom: CGFloat = 1 { didSet { needsLayout = true } }
    var fillMode = false { didSet { playerView.videoGravity = fillMode ? .resizeAspectFill : .resizeAspect } }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerView.player = player
        playerView.controlsStyle = .none          // MacPlayer draws its own controls
        playerView.allowsMagnification = false
        playerView.showsFullScreenToggleButton = false
        addSubview(playerView)
        addSubview(manipulator)
        addSubview(elements)
        manipulator.videoRect = { [weak self] in self?.displayedPicture() ?? .zero }
        elements.pictureRect = { [weak self] in self?.displayedPicture() ?? .zero }
        elements.layerFrames = { [weak self] in self?.manipulator.frames() ?? [] }
        manipulator.things = { [weak self] id in self?.elements.things(excluding: [id]) ?? [] }
        message.textColor = .white; message.alignment = .center; message.isHidden = true; message.font = .systemFont(ofSize: 14)
        addSubview(message)
        registerForDraggedTypes([.fileURL, .string])
        setAccessibilityLabel(L("Video"))
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How many times the picture area was laid out (the self-test checks that playing does not keep doing it).
    static var layouts = 0

    override func layout() {
        super.layout()
        Self.layouts += 1
        let w = bounds.width * zoom, h = bounds.height * zoom
        playerView.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        message.frame = bounds.insetBy(dx: 40, dy: bounds.height / 2 - 40)
        manipulator.frame = bounds; elements.frame = bounds
        manipulator.window?.invalidateCursorRects(for: manipulator)
        elements.window?.invalidateCursorRects(for: elements)
    }

    /// Where the picture really is inside this view: what the player reports, else the picture's shape fitted into the view.
    func displayedPicture() -> CGRect {
        let b = playerView.videoBounds
        if b.width > 2, b.height > 2 { return b.offsetBy(dx: playerView.frame.minX, dy: playerView.frame.minY) }
        let a = max(0.1, fallbackAspect()), f = playerView.frame
        let w = min(f.width, f.height * a), h = w / a
        return CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
    }

    func show(message text: String?) { message.stringValue = text ?? ""; message.isHidden = text == nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    /// While something hovers over the picture, a target shows where text, a shape, a sticker or a picture would land.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let pb = sender.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let placeable: Bool
        if urls.isEmpty, let item = pb.string(forType: .string).flatMap(DragPayload.parse) {
            switch item { case .text, .sticker, .shape, .preset: placeable = true; default: placeable = false }
        } else { placeable = !urls.isEmpty && urls.allSatisfy { ImageFiles.isCandidate($0.path) } }
        elements.dropPoint = placeable && pictureFraction(p, in: displayedPicture()) != nil ? p : nil
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { elements.dropPoint = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { elements.dropPoint = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        elements.dropPoint = nil
        let at = pictureFraction(convert(sender.draggingLocation, from: nil), in: displayedPicture())
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let str = sender.draggingPasteboard.string(forType: .string), let item = DragPayload.parse(str), let onDropPayload {
            // A text style dropped on a text already there restyles it; anywhere else it adds a new text.
            if case .text(let t?) = item, let o = elements.textElement(at: convert(sender.draggingLocation, from: nil)), let s = elements.session { s.restyleText(o.id, t); return true }
            onDropPayload(item, at); return true
        }
        guard !urls.isEmpty else { return false }
        // Pictures dropped on the picture itself go where they are dropped, over the video.
        if let onDropPictures, at != nil, urls.allSatisfy({ ImageFiles.isCandidate($0.path) }) { onDropPictures(urls, at); return true }
        onDropFiles?(urls)
        return true
    }
}
