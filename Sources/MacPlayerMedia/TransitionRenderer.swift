import CoreImage
import Foundation
import MacPlayerCore

/// How two pictures are mixed while one clip gives way to the next. `progress` runs from 0 (all outgoing) to 1 (all incoming).
enum TransitionRenderer {
    static func blend(outgoing a: CIImage, incoming b: CIImage, kind: TransitionKind, progress p: Double, frame: CGRect) -> CIImage {
        let p = min(max(p, 0), 1)
        let w = frame.width, h = frame.height
        func dissolve(_ x: CIImage, _ y: CIImage, _ t: Double) -> CIImage {
            t <= 0 ? x : (t >= 1 ? y : x.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": y, "inputTime": t]).cropped(to: frame))
        }
        func shifted(_ i: CIImage, _ dx: Double, _ dy: Double) -> CIImage { i.transformed(by: CGAffineTransform(translationX: dx, y: dy)) }
        switch kind {
        case .dissolve:
            return dissolve(a, b, p)
        case .dipBlack, .dipWhite:
            let colour = CIImage(color: kind == .dipBlack ? .black : .white).cropped(to: frame)
            return p < 0.5 ? dissolve(a, colour, p * 2) : dissolve(colour, b, (p - 0.5) * 2)
        case .slideLeft:        // the new picture pushes the old one out to the left
            return shifted(b, (1 - p) * w, 0).composited(over: shifted(a, -p * w, 0)).cropped(to: frame)
        case .slideRight:
            return shifted(b, -(1 - p) * w, 0).composited(over: shifted(a, p * w, 0)).cropped(to: frame)
        case .slideUp:          // Core Image counts y upwards
            return shifted(b, 0, -(1 - p) * h).composited(over: shifted(a, 0, p * h)).cropped(to: frame)
        case .slideDown:
            return shifted(b, 0, (1 - p) * h).composited(over: shifted(a, 0, -p * h)).cropped(to: frame)
        case .wipeRight:        // the new picture is uncovered from the left edge
            guard p > 0 else { return a }
            return b.cropped(to: CGRect(x: frame.minX, y: frame.minY, width: w * p, height: h)).composited(over: a).cropped(to: frame)
        case .zoomIn:           // the old picture swells and fades away over the new one
            let k = 1 + p * 0.6
            var big = a.transformed(by: CGAffineTransform(translationX: -frame.midX, y: -frame.midY).concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY)))
            if p > 0 { big = big.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)]) }
            return big.composited(over: b).cropped(to: frame)
        }
    }
}
