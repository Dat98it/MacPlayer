import CoreImage
import Foundation
import MacPlayerCore

/// The picture effects of `LookEffects`, and chroma key, as Core Image recipes. Used by the one renderer behind preview and export.
enum LookEffectsRenderer {
    // MARK: Effects on the whole frame

    /// Filter, sharpening, blur and vignette, in that order. (The blurred backdrop is made separately, before the picture is placed.)
    static func apply(_ e: LookEffects, to image: CIImage, frame: CGRect) -> CIImage {
        let e = e.clamped()
        var out = image
        if e.filter != .none {
            let filtered = filtered(out, preset: e.filter)
            out = e.filterAmount >= 0.999 ? filtered : out.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": filtered, "inputTime": e.filterAmount])
        }
        if e.sharpen > 0 { out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: e.sharpen * 1.6]) }
        if e.blur > 0 {
            out = out.clampedToExtent().applyingGaussianBlur(sigma: e.blur * Double(frame.height) * 0.05).cropped(to: frame)
        }
        if e.vignette > 0 {
            out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: e.vignette * 1.6, kCIInputRadiusKey: 1.7 - e.vignette * 0.7])
        }
        return out.cropped(to: frame)
    }

    static func filtered(_ img: CIImage, preset: FilterPreset) -> CIImage {
        func controls(_ i: CIImage, sat: Double = 1, contrast: Double = 1, brightness: Double = 0) -> CIImage {
            i.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: sat, kCIInputContrastKey: contrast, kCIInputBrightnessKey: brightness])
        }
        func temperature(_ i: CIImage, to kelvin: Double) -> CIImage {
            i.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: kelvin, y: 0)])
        }
        switch preset {
        case .none: return img
        case .vivid: return controls(img, sat: 1.35, contrast: 1.08).applyingFilter("CIVibrance", parameters: ["inputAmount": 0.5])
        case .warm: return controls(temperature(img, to: 5000), sat: 1.08)
        case .cool: return controls(temperature(img, to: 8500), sat: 1.05)
        case .cinematic:
            // Lifted contrast, a little less colour, warm highlights and cool shadows pushed apart by scaling red up and blue down.
            return controls(img, sat: 0.88, contrast: 1.18, brightness: -0.02).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.06, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.94, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        case .vintage: return img.applyingFilter("CIPhotoEffectInstant")
        case .fade: return img.applyingFilter("CIPhotoEffectFade")
        case .film: return img.applyingFilter("CIPhotoEffectTransfer")
        case .mono: return img.applyingFilter("CIPhotoEffectMono")
        case .noir: return img.applyingFilter("CIPhotoEffectNoir")
        case .dramatic:
            return controls(img, sat: 0.75, contrast: 1.35, brightness: -0.04).applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 1.6])
        }
    }

    // MARK: Zoom and move

    /// Enlarges the frame about the part of it that should be in the middle (`state.x`/`y` from the top-left), then crops back to the frame.
    static func zoomed(_ image: CIImage, state: MotionState, frame: CGRect) -> CIImage {
        let m = state.clamped()
        let px = frame.minX + m.x * frame.width, py = frame.minY + (1 - m.y) * frame.height      // Core Image's origin is bottom-left
        var t = CGAffineTransform(translationX: -px, y: -py)
        t = t.concatenating(CGAffineTransform(scaleX: m.scale, y: m.scale))
        if m.rotation != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: -m.rotation * .pi / 180)) }        // clockwise on screen, and Core Image's y points up
        t = t.concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY))
        return image.transformed(by: t).cropped(to: frame)
    }

    // MARK: Blurred backdrop

    /// The picture enlarged until it covers the whole frame, blurred and slightly darkened: what fills the bars around a picture that fits.
    static func backdrop(of upright: CIImage, frame: CGRect, amount: Double) -> CIImage {
        let w = upright.extent.width, h = upright.extent.height
        guard w > 0, h > 0 else { return CIImage(color: .black).cropped(to: frame) }
        let k = max(frame.width / w, frame.height / h)
        var bg = upright.transformed(by: CGAffineTransform(scaleX: k, y: k))
        bg = bg.transformed(by: CGAffineTransform(translationX: (frame.width - bg.extent.width) / 2 - bg.extent.origin.x, y: (frame.height - bg.extent.height) / 2 - bg.extent.origin.y))
        let sigma = Double(frame.height) * (0.015 + 0.05 * min(max(amount, 0), 1))
        bg = bg.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: frame)
        return bg.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.1])
    }

    // MARK: Chroma key

    private static let cubeLock = NSLock()
    nonisolated(unsafe) private static var cubes: [String: Data] = [:]
    private static let cubeSize = 32

    /// Makes the key colour (and what is close to it) transparent. Distance is measured between the colours' shares of red, green and
    /// blue (so it does not depend on brightness): a green backdrop in shadow is still removed, and grey or black is never taken for it.
    static func chromaKeyed(_ image: CIImage, key: ChromaKey) -> CIImage {
        let id = "\(key.colorHex)|\(Int(key.tolerance * 1000))|\(Int(key.softness * 1000))"
        cubeLock.lock()
        var data = cubes[id]
        cubeLock.unlock()
        if data == nil {
            data = makeCube(key)
            cubeLock.lock(); if cubes.count > 12 { cubes.removeAll() }; cubes[id] = data; cubeLock.unlock()
        }
        return image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cubeSize, "inputCubeData": data!])
    }

    static func makeCube(_ key: ChromaKey) -> Data {
        let kc = CompositionBuilderColor.components(hex: key.colorHex)
        func share(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double)? {
            let sum = r + g + b
            return sum < 0.06 ? nil : (r / sum, g / sum)       // a nearly black pixel has no colour to speak of
        }
        let key2 = share(kc.r, kc.g, kc.b) ?? (0, 1)
        let threshold = min(max(key.tolerance, 0), 1) * 0.6
        let soft = max(min(max(key.softness, 0), 1) * 0.4, 0.004)
        let n = cubeSize
        var floats = [Float](); floats.reserveCapacity(n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
            var a = 1.0
            if let (sr, sg) = share(r, g, b) {
                let d = ((sr - key2.0) * (sr - key2.0) + (sg - key2.1) * (sg - key2.1)).squareRoot()
                a = min(max((d - threshold) / soft, 0), 1)
            }
            floats.append(Float(r * a)); floats.append(Float(g * a)); floats.append(Float(b * a)); floats.append(Float(a))
        } } }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// "#RRGGBB" as numbers 0...1.
enum CompositionBuilderColor {
    static func components(hex: String) -> (r: Double, g: Double, b: Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return (0, 1, 0) }
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }
}
