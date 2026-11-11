import AppKit
import QuartzCore
import MacPlayerMedia

/// The pictures of the things being dragged, drawn by a view over the preview (0.14.3, see `CanvasLift`). Each is a Core Animation layer
/// that is only moved and scaled while the mouse moves, which the screen does at its own pace: the thing stays under the mouse however
/// long the preview would take to draw a frame.
@MainActor
final class CanvasLiftLayers {
    private struct Piece { let layer: CALayer; let size: Double }
    private var pieces: [UUID: Piece] = [:]
    private weak var host: NSView?
    /// Pictures still shown after a drop, until the preview shows the dropped things.
    private var leaving: [CALayer] = []

    init(host: NSView) { self.host = host }

    var ids: Set<UUID> { Set(pieces.keys) }
    var isEmpty: Bool { pieces.isEmpty }

    /// Lifts these things off the preview and shows their pictures instead. Those that cannot be drawn this way stay in the preview.
    func lift(_ ids: Set<UUID>, session s: EditorSession, pic: CGRect) {
        guard pieces.isEmpty, let host else { return }
        host.wantsLayer = true
        guard let root = host.layer else { return }
        let scale = host.window?.backingScaleFactor ?? 2
        clearLeaving()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in ids {
            guard let got = s.liftPicture(id, pic: pic, scale: scale), let place = s.liftPlacement(id, pic: pic), got.frame.width > 0, got.frame.height > 0 else { continue }
            let l = CALayer()
            l.contents = got.image
            l.contentsScale = scale
            l.contentsGravity = .resize
            l.opacity = Float(min(max(got.alpha, 0), 1))
            l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull(), "contents": NSNull()]
            l.frame = got.frame
            // Turned and grown around the thing's own centre, like the preview does.
            l.anchorPoint = CGPoint(x: (got.centre.x - got.frame.minX) / got.frame.width, y: (got.centre.y - got.frame.minY) / got.frame.height)
            l.position = got.centre
            root.addSublayer(l)
            pieces[id] = Piece(layer: l, size: place.size)
        }
        CATransaction.commit()
        if !pieces.isEmpty { s.beginLift(Set(pieces.keys)) }
    }

    /// Puts each picture where the draft has its thing now.
    func follow(_ s: EditorSession, pic: CGRect) {
        guard !pieces.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, p) in pieces {
            guard let now = s.liftPlacement(id, pic: pic) else { continue }
            p.layer.position = now.centre
            let k = CGFloat(now.size / max(0.0001, p.size))
            p.layer.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        }
        CATransaction.commit()
    }

    /// The drop: the pictures stay until the preview shows the things again (`whenShown` of `commitDraft`).
    func drop() -> @MainActor () -> Void {
        let going = pieces.values.map(\.layer)
        pieces = [:]
        leaving += going
        return { [weak self] in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for l in going { l.removeFromSuperlayer() }
            CATransaction.commit()
            self?.leaving.removeAll { l in going.contains { $0 === l } }
        }
    }

    private func clearLeaving() { for l in leaving { l.removeFromSuperlayer() }; leaving = [] }

    /// Pictures on screen, being dragged or waiting for the preview after a drop (for the self-test).
    var showing: Int { pieces.count + leaving.count }
    /// Where a lifted picture is on screen (for the self-test).
    func frame(of id: UUID) -> CGRect? { pieces[id]?.layer.frame }
}
