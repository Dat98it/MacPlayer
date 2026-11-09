import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MacPlayerCore
import UniformTypeIdentifiers

public enum PhotoError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case cannotWrite(String)
    public var description: String {
        switch self {
        case .unreadable(let m): return "Cannot read this picture: \(m)"
        case .cannotWrite(let m): return "Cannot write the picture: \(m)"
        }
    }
}

/// Reading pictures: what a file is (size, orientation), a screen-sized copy to edit with, the full picture for saving, and small stills for lists.
public enum PhotoLoader {
    public struct Loaded {
        /// Upright (the camera's rotation is applied), with its origin at zero.
        public var image: CIImage
        /// The size of the whole picture, upright, in pixels (what the file holds, even when `image` is a smaller copy).
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var colorSpace: CGColorSpace?
        public init(image: CIImage, pixelWidth: Int, pixelHeight: Int, colorSpace: CGColorSpace?) { self.image = image; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.colorSpace = colorSpace }
    }

    private static func source(_ url: URL) throws -> CGImageSource {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(s) > 0 else {
            throw PhotoError.unreadable(url.lastPathComponent)
        }
        return s
    }

    /// Width and height as shown (turned when the camera stored the picture on its side), and the properties the file carries.
    public static func dimensions(of src: CGImageSource) -> (width: Int, height: Int, orientation: Int, properties: [CFString: Any])? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 && o <= 8 ? (h, w, o, p) : (w, h, o, p)
    }

    /// What the editing code knows about a picture: shaped like a video's information, with one picture "track" and no length.
    public static func info(url: URL) throws -> MediaInfo {
        let src = try source(url)
        guard let d = dimensions(of: src) else { throw PhotoError.unreadable(url.lastPathComponent) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return MediaInfo(duration: .zero, fileExtension: url.pathExtension.lowercased(), fileSize: size,
                         video: [.init(trackID: 1, codec: "image", width: d.width, height: d.height)], audio: [])
    }

    /// A copy of the picture whose longest side is at most `maxPixel`, upright. Quick to make, and what the screen preview is drawn from.
    public static func preview(url: URL, maxPixel: Int) throws -> Loaded {
        let src = try source(url)
        guard let d = dimensions(of: src) else { throw PhotoError.unreadable(url.lastPathComponent) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw PhotoError.unreadable(url.lastPathComponent) }
        return Loaded(image: CIImage(cgImage: cg), pixelWidth: d.width, pixelHeight: d.height, colorSpace: cg.colorSpace)
    }

    /// The whole picture at full size, upright.
    public static func full(url: URL) throws -> Loaded {
        let src = try source(url)
        guard let d = dimensions(of: src) else { throw PhotoError.unreadable(url.lastPathComponent) }
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw PhotoError.unreadable(url.lastPathComponent) }
        let e = ci.extent
        let image = e.origin == .zero ? ci : ci.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
        return Loaded(image: image, pixelWidth: Int(e.width.rounded()), pixelHeight: Int(e.height.rounded()), colorSpace: ci.colorSpace)
    }

    // MARK: Animated pictures (GIF, animated PNG and WebP)

    public struct Animation: Equatable, Sendable {
        /// How long each frame stays, in seconds.
        public var delays: [Double]
        /// How many times it plays; 0 = for ever.
        public var loopCount: Int
        public var frameCount: Int { delays.count }
        public var duration: Double { delays.reduce(0, +) }
    }

    /// The frames' timing when the file is an animation; nil for an ordinary picture.
    public static func animation(url: URL) -> Animation? {
        guard let src = try? source(url), CGImageSourceGetCount(src) > 1, ["gif", "png", "apng", "webp", "heics", "avif"].contains(url.pathExtension.lowercased()) else { return nil }
        var delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(src) {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
            func delay(_ dict: CFString, _ unclamped: CFString, _ clamped: CFString) -> Double? {
                guard let d = p[dict] as? [CFString: Any] else { return nil }
                return (d[unclamped] as? NSNumber)?.doubleValue ?? (d[clamped] as? NSNumber)?.doubleValue
            }
            let d = delay(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
                ?? delay(kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
                ?? delay(kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
                ?? delay(kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
            delays.append(max(0.02, d ?? 0.1))       // players treat 0 as "not set", and nothing shows faster than this
        }
        let file = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
        let loop = ((file[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
            ?? ((file[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] as? NSNumber)?.intValue ?? 0
        return Animation(delays: delays, loopCount: loop)
    }

    /// Frame `index` of an animation, with at most `maxPixel` on its longest side (full size when nil).
    public static func frame(url: URL, index: Int, maxPixel: Int?) throws -> CGImage {
        let src = try source(url)
        guard index >= 0, index < CGImageSourceGetCount(src) else { throw PhotoError.unreadable(url.lastPathComponent) }
        if let maxPixel {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary) { return cg }
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, index, nil) else { throw PhotoError.unreadable(url.lastPathComponent) }
        return cg
    }

    /// A small still for a list or a grid.
    public static func thumbnail(url: URL, maxSize: CGSize) -> CGImage? {
        guard let src = try? source(url) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(max(maxSize.width, maxSize.height).rounded(.up)), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// The properties to carry into a saved copy (date, camera, lens, position...), without the things that no longer hold: the rotation
    /// (the pixels are already upright) and the old pixel size.
    public static func metadata(of url: URL, removeLocation: Bool) -> [CFString: Any] {
        guard let src = try? source(url), var p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation, kCGImagePropertyDepth, kCGImagePropertyColorModel,
                  kCGImagePropertyProfileName, kCGImagePropertyHasAlpha, kCGImagePropertyFileSize, kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed] { p.removeValue(forKey: k) }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation); p[kCGImagePropertyTIFFDictionary] = tiff }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension); exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            p[kCGImagePropertyExifDictionary] = exif
        }
        // Not carried: embedded thumbnails and maker notes describe the old picture.
        p.removeValue(forKey: kCGImagePropertyMakerAppleDictionary)
        if removeLocation {
            p.removeValue(forKey: kCGImagePropertyGPSDictionary)
            if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                for k in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware] { tiff.removeValue(forKey: k) }
                p[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                for k in [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber] { exif.removeValue(forKey: k) }
                p[kCGImagePropertyExifDictionary] = exif
            }
        }
        return p
    }
}
