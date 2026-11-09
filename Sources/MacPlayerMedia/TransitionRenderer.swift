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
        case .wipeLeft:         // uncovered from the right edge
            guard p > 0 else { return a }
            return b.cropped(to: CGRect(x: frame.maxX - w * p, y: frame.minY, width: w * p, height: h)).composited(over: a).cropped(to: frame)
        case .wipeUp:           // uncovered from the bottom edge, going up
            guard p > 0 else { return a }
            return b.cropped(to: CGRect(x: frame.minX, y: frame.minY, width: w, height: h * p)).composited(over: a).cropped(to: frame)
        case .wipeDown:         // uncovered from the top edge, going down
            guard p > 0 else { return a }
            return b.cropped(to: CGRect(x: frame.minX, y: frame.maxY - h * p, width: w, height: h * p)).composited(over: a).cropped(to: frame)
        case .circleOpen:       // the new picture opens from the middle as a growing circle
            guard p > 0 else { return a }
            guard p < 1 else { return b }
            let radius = (w * w + h * h).squareRoot() / 2 * p
            let disc = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: frame.midX, y: frame.midY), "inputRadius0": radius, "inputRadius1": radius + max(2, h * 0.02),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: frame)
            return b.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: a, kCIInputMaskImageKey: disc]).cropped(to: frame)
        case .blur:             // both pictures blur most in the middle of the change
            guard p > 0, p < 1 else { return p <= 0 ? a : b }
            let sigma = sin(p * Double.pi) * h * 0.035
            func soft(_ i: CIImage) -> CIImage { i.clampedToExtent().applyingGaussianBlur(sigma: max(0.01, sigma)).cropped(to: frame) }
            return dissolve(soft(a), soft(b), p)
        case .spin:             // the old picture turns and shrinks away, uncovering the new one
            guard p > 0 else { return a }
            guard p < 1 else { return b }
            let k = 1 - p * 0.9
            var t = CGAffineTransform(translationX: -frame.midX, y: -frame.midY).concatenating(CGAffineTransform(rotationAngle: -p * Double.pi))
            t = t.concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
            let away = a.transformed(by: t).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p * p)])
            return away.composited(over: b).cropped(to: frame)
        case .flash:            // a quick white flash covers the cut
            let mixed = dissolve(a, b, p)
            let strength = max(0, 1 - abs(p - 0.5) * 3)
            guard strength > 0 else { return mixed }
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: strength)).cropped(to: frame)
            return white.composited(over: mixed).cropped(to: frame)
        case .pixelate:         // both pictures break into blocks, biggest in the middle
            guard p > 0, p < 1 else { return p <= 0 ? a : b }
            let block = 1 + sin(p * Double.pi) * h * 0.06
            func blocks(_ i: CIImage) -> CIImage { i.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: frame.midX, y: frame.midY)]).cropped(to: frame) }
            return dissolve(blocks(a), blocks(b), p)
        }
    }
}
