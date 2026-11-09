import CoreImage
import CoreGraphics
import Foundation
import Vision
import MacPlayerCore

/// Masks as pictures: white where the picture stays, black where it goes. Shapes are drawn once per size and kept.
enum MaskRenderer {
    private struct Key: Hashable { let spec: MaskSpec; let w: Int; let h: Int }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CIImage] = [:]
    nonisolated(unsafe) private static var order: [Key] = []

    /// The mask for a picture of `size` pixels, with its soft edge and inversion. Same size as the picture, origin at zero.
    static func alpha(_ spec: MaskSpec, size: CGSize) -> CIImage {
        let m = spec.clamped()
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        let key = Key(spec: m, w: w, h: h)
        lock.lock(); if let hit = cache[key] { lock.unlock(); return hit }; lock.unlock()
        let image = draw(m, w: w, h: h)
        lock.lock(); defer { lock.unlock() }
        cache[key] = image; order.append(key)
        while order.count > 24 { cache[order.removeFirst()] = nil }
        return image
    }

    /// Draws the shape at a reduced size (a soft edge does not need every pixel) and scales it up.
    private static func draw(_ m: MaskSpec, w: Int, h: Int) -> CIImage {
        let scale = min(1.0, 640.0 / Double(max(w, h)))
        let dw = max(2, Int(Double(w) * scale)), dh = max(2, Int(Double(h) * scale))
        let aspect = Double(w) / Double(h)
        var bytes = [UInt8](repeating: 0, count: dw * dh)
        // Each pixel asks the geometry whether it is inside (4 sample points a pixel give a smooth sharp edge).
        for y in 0..<dh {
            for x in 0..<dw {
                var inside = 0
                for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let fx = (Double(x) + ox) / Double(dw), fy = (Double(y) + oy) / Double(dh)
                    if MaskGeometry.contains(m, x: fx, y: fy, aspect: aspect) { inside += 1 }
                }
                bytes[y * dw + x] = UInt8(inside * 255 / 4)
            }
        }
        if m.invert { for i in bytes.indices { bytes[i] = 255 - bytes[i] } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: dw, height: dh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: dw, space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        var img = CIImage(cgImage: cg)
        if m.feather > 0 {
            let sigma = m.feather * Double(min(dw, dh)) * 0.12
            img = img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: CGRect(x: 0, y: 0, width: dw, height: dh))
        }
        if dw != w || dh != h { img = img.transformed(by: CGAffineTransform(scaleX: Double(w) / Double(dw), y: Double(h) / Double(dh))) }
        // (Core Image reads the bitmap's first row as the top of the picture, so no turning over is needed.)
        return img.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Keeps `image` where `mask` is white and makes it see-through where it is black. The mask is placed on the image's own extent.
    static func apply(_ mask: CIImage, to image: CIImage) -> CIImage {
        let moved = mask.transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: moved]).cropped(to: image.extent)
    }
}

/// Finds the person or subject in a picture with Vision (on this Mac, no network). Used to cut a subject out of its background.
public enum SubjectMasker {
    public enum Mode: Sendable {
        /// A photo: any foreground subject, as accurate as possible.
        case photo
        /// A frame of video shown in the preview: people only, quick.
        case previewVideo
        /// A frame of video being exported: people only, accurate.
        case exportVideo
    }

    /// Tests replace this to give a mask without a person in the picture.
    nonisolated(unsafe) static var provider: ((CIImage, Mode) -> CIImage?)?

    // A photo is drawn again at every slider step while Vision takes a fraction of a second: the last few answers are kept, found by what
    // the picture looks like (a tiny copy of it).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var photoCache: [String: CIImage?] = [:]
    nonisolated(unsafe) private static var photoOrder: [String] = []
    private static let fingerprintContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private static func fingerprint(_ image: CIImage) -> String {
        let e = image.extent, n = 12
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: Double(n) / e.width, y: Double(n) / e.height))
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        fingerprintContext.render(small, toBitmap: &bytes, rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8, colorSpace: nil)
        var h = 14695981039346656037 as UInt64
        for b in bytes { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(Int(e.width))x\(Int(e.height))-\(h)"
    }

    /// A mask as big as `image` (white = subject), or nil when nothing was found or Vision cannot do it.
    static func mask(for image: CIImage, mode: Mode) -> CIImage? {
        if let provider { return provider(image, mode) }
        guard mode == .photo else { return find(image, mode: mode) }
        let key = fingerprint(image)
        lock.lock(); if let hit = photoCache[key] { lock.unlock(); return hit }; lock.unlock()
        let found = find(image, mode: mode)
        lock.lock(); defer { lock.unlock() }
        photoCache[key] = .some(found); photoOrder.append(key)
        while photoOrder.count > 4 { photoCache[photoOrder.removeFirst()] = nil }
        return found
    }

    private static func find(_ image: CIImage, mode: Mode) -> CIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        // Vision does not need more than a few hundred pixels; a smaller picture is much faster and the edge is smoothed anyway.
        let longest = mode == .exportVideo || mode == .photo ? 1024.0 : 512.0
        let k = min(1.0, longest / Double(max(extent.width, extent.height)))
        let small = k < 1 ? image.transformed(by: CGAffineTransform(scaleX: k, y: k)) : image
        let normalized = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        let handler = VNImageRequestHandler(ciImage: normalized, options: [:])
        var observation: CVPixelBuffer?
        do {
            if mode == .photo {
                let request = VNGenerateForegroundInstanceMaskRequest()
                try handler.perform([request])
                if let result = request.results?.first, !result.allInstances.isEmpty {
                    observation = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                }
            }
            if observation == nil {
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = mode == .previewVideo ? .balanced : .accurate
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                try handler.perform([request])
                observation = request.results?.first?.pixelBuffer
            }
        } catch { return nil }
        guard let buffer = observation else { return nil }
        var mask = CIImage(cvPixelBuffer: buffer)
        // To the picture's size and place.
        mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
        mask = mask.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        // A little softening hides the stair-steps of the small mask.
        return mask.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: extent)
    }
}
