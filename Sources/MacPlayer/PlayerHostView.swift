import AVKit
import AppKit
import MacPlayerCore

/// The picture area: the player, a drop target for videos and folders, and the "what went wrong" overlay.
@MainActor
final class PlayerHostView: NSView {
    let playerView = AVPlayerView()
    private let message = NSTextField(wrappingLabelWithString: "")
    let manipulator = OverlayManipulatorView()
    /// Used when the player has not reported the picture's rectangle yet.
    var fallbackAspect: () -> Double = { 16.0 / 9 }
    var onDropFiles: (([URL]) -> Void)?
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
        manipulator.videoRect = { [weak self] in self?.displayedPicture() ?? .zero }
        message.textColor = .white; message.alignment = .center; message.isHidden = true; message.font = .systemFont(ofSize: 14)
        addSubview(message)
        registerForDraggedTypes([.fileURL])
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
        manipulator.frame = bounds
        manipulator.window?.invalidateCursorRects(for: manipulator)
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
