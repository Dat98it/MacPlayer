import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MacPlayerCore
import UniformTypeIdentifiers

/// A logo laid over a photo: its picture, and where and how it is drawn (no time: it is always there).
public struct PhotoLogo: @unchecked Sendable {
    public var spec: LayerSpec
    public var image: CIImage
    public var border: CIColor

    /// The logos of a photo project, read from their files (those that cannot be read are left out). Lowest lane first.
    public static func load(_ clips: [OverlayClip], image: (String) -> CIImage? = PhotoLogo.readImage) -> [PhotoLogo] {
        clips.sorted { $0.lane < $1.lane }.compactMap { c in
            guard case .image(let path, _) = c.kind, let ci = image(path) else { return nil }
            return PhotoLogo(spec: still(c, path: path), image: ci, border: CompositionBuilder.ciColor(hex: c.transform.borderHex))
        }
    }

    public static func readImage(_ path: String) -> CIImage? { CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) }

    /// On a photo a layer is always shown and does not move.
    static func still(_ c: OverlayClip, path: String) -> LayerSpec {
        LayerSpec(id: c.id, kind: .image(path: path), lane: c.lane, start: .zero, duration: MediaTime(seconds: 200_000), transform: c.transform, keyframes: [],
                  audio: AudioSettings(), fadeIn: 0, fadeOut: 0, animationIn: nil, animationOut: nil)
    }
}

/// Draws an edited photo with the same code that draws the frames of a video, so a photo looks the same on the screen and in the saved file:
/// crop, turn, flip, canvas, colour, filters, effects, then logos, then text, shapes and stickers over it.
public enum PhotoRenderer {
    /// Everything on a photo is "on" all the time; text and shapes are drawn as they stand at this moment of their (endless) life.
    static let stillTime = 50_000.0
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// The size of the result for an upright picture of `source` pixels.
    public static func outputSize(source: CGSize, look: VideoLook) -> CGSize {
        let o = RenderGeometry.outputSize(source: PixelSize(width: max(1, Int(source.width.rounded())), height: max(1, Int(source.height.rounded()))), look: look)
        return CGSize(width: o.width, height: o.height)
    }

    /// Elements put on a photo are always shown, and do not move: whatever times or animations they were made with are set aside.
    static func stilled(_ overlays: [TextOverlay]) -> [TextOverlay] {
        overlays.map { o in
            var n = o
            n.start = .zero; n.end = MediaTime(seconds: 100_000)
            n.animationIn = nil; n.animationOut = nil; n.keyframes = []
            return n
        }
    }

    /// The edited picture. `base` is the upright picture (any size: the edit is in fractions of it). `effects` replaces the look's own filter
    /// settings (used for a live preview while a slider moves).
    public static func render(base: CIImage, look: VideoLook, overlays: [TextOverlay], logos: [PhotoLogo] = [], effects: LookEffects? = nil) -> CIImage {
        var l = look
        l.motion = []; l.stabilize = 0; l.speed = 1; l.transitionIn = nil
        if let effects { l.effects = effects }
        let b = RecipeCompositor.normalized(base)
        let out = outputSize(source: b.extent.size, look: l)
        var plan = PiecePlan(look: l, trackOrientation: .up, storedSize: PixelSize(width: Int(b.extent.width), height: Int(b.extent.height)))
        plan.subjectMode = .photo
        var picture = RecipeCompositor.mainPicture(base: b, plan: plan, time: stillTime, outputSize: out)
        let frame = CGRect(origin: .zero, size: out)
        for logo in logos {
            picture = RecipeCompositor.drawLayer(RecipeCompositor.normalized(logo.image), spec: logo.spec, border: logo.border, time: 1, subjectMode: .photo, over: picture, frame: frame)
        }
        let layer = OverlayLayer(overlays: stilled(overlays), cues: [], style: SubtitleStyle())
        if !layer.isEmpty {
            for (overlay, alpha) in layer.visible(at: stillTime, size: out) {
                let o = alpha >= 1 ? overlay : overlay.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                picture = o.composited(over: picture)
            }
        }
        return picture.cropped(to: CGRect(origin: .zero, size: out))
    }

    /// The picture as pixels, tagged with the colour space it came in so that nothing shifts.
    public static func cgImage(_ image: CIImage, colorSpace: CGColorSpace?) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Saves an edited photo as a new file.
public enum PhotoExporter {
    /// What saving gives for a picture of `width`×`height` pixels with this edit and size limit, to the pixel: the edit's size, brought down to the
    /// limit by scaling the picture first, and the edit's size once more on the scaled picture (the sizes are kept even). Saving uses these same
    /// numbers, so what the screen says and what is written agree.
    public static func plannedSize(width: Double, height: Double, look: VideoLook, maxLongEdge: Int?) -> (scale: Double, width: Int, height: Int) {
        let natural = PhotoRenderer.outputSize(source: CGSize(width: width, height: height), look: look)
        let limited = PhotoSizing.fit(width: Int(natural.width), height: Int(natural.height), maxLongEdge: maxLongEdge)
        let k = Double(limited.width) < natural.width - 0.5 ? Double(limited.width) / natural.width : 1
        let final = PhotoRenderer.outputSize(source: scaledSize(width: width, height: height, scale: k), look: look)
        return (k, Int(final.width), Int(final.height))
    }

    /// The size a picture has after being scaled by `scale`: whole pixels.
    static func scaledSize(width: Double, height: Double, scale k: Double) -> CGSize { CGSize(width: max(1, (width * k).rounded()), height: max(1, (height * k).rounded())) }

    /// The picture scaled by `plan.scale` to exactly the whole-pixel size the plan counts with.
    static func scaled(_ base: CIImage, by k: Double) -> CIImage {
        let size = scaledSize(width: Double(base.extent.width), height: Double(base.extent.height), scale: k)
        return base.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1]).clampedToExtent().cropped(to: CGRect(origin: .zero, size: size))
    }

    /// An animation, with the same edit on every frame, written as an animated GIF or (0.16) an animated PNG, which keeps every colour and
    /// see-through edges. Frames are drawn and written one at a time.
    @discardableResult
    static func exportAnimation(source: URL, animation: PhotoLoader.Animation, look: VideoLook, overlays: [TextOverlay], logos: [PhotoLogo], options: PhotoExportOptions, to destination: URL) throws -> (width: Int, height: Int) {
        let png = options.format == .png
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, (png ? UTType.png : UTType.gif).identifier as CFString, animation.frameCount, nil) else {
            throw PhotoError.cannotWrite("\(png ? "Animated PNG" : "GIF") cannot be written on this Mac")
        }
        if png { CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: animation.loopCount]] as CFDictionary) }
        else { CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: animation.loopCount]] as CFDictionary) }
        var size = (width: 0, height: 0)
        for i in 0..<animation.frameCount {
            let cg = try PhotoLoader.frame(url: source, index: i, maxPixel: nil)
            var base = CIImage(cgImage: cg)
            let plan = plannedSize(width: Double(base.extent.width), height: Double(base.extent.height), look: look, maxLongEdge: options.maxLongEdge)
            if plan.scale < 1 { base = scaled(base, by: plan.scale) }
            let edited = PhotoRenderer.render(base: base, look: look, overlays: overlays, logos: logos)
            guard let out = PhotoRenderer.cgImage(edited, colorSpace: cg.colorSpace) else { throw PhotoError.cannotWrite("a frame could not be drawn") }
            size = (out.width, out.height)
            let delay = animation.delays[i]
            if png { CGImageDestinationAddImage(dest, out, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]] as CFDictionary) }
            else { CGImageDestinationAddImage(dest, out, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary) }
        }
        guard CGImageDestinationFinalize(dest) else { throw PhotoError.cannotWrite("the file could not be completed") }
        return size
    }

    /// Renders `source` with the edit and writes it to `destination` (a temporary file the caller then puts in place). Returns the size written.
    @discardableResult
    public static func export(source: URL, look: VideoLook, overlays: [TextOverlay], layers: [OverlayClip] = [], options: PhotoExportOptions, to destination: URL) throws -> (width: Int, height: Int) {
        let logos = PhotoLogo.load(layers)
        if options.format == .gif || options.format == .png, let animation = PhotoLoader.animation(url: source) { return try exportAnimation(source: source, animation: animation, look: look, overlays: overlays, logos: logos, options: options, to: destination) }
        let loaded = try PhotoLoader.full(url: source)
        var base = loaded.image
        // A size limit is applied to the picture first, so the work is done on fewer pixels.
        let plan = plannedSize(width: Double(base.extent.width), height: Double(base.extent.height), look: look, maxLongEdge: options.maxLongEdge)
        if plan.scale < 1 { base = scaled(base, by: plan.scale) }
        let edited = PhotoRenderer.render(base: base, look: look, overlays: overlays, logos: logos)
        guard let cg = PhotoRenderer.cgImage(edited, colorSpace: loaded.colorSpace) else { throw PhotoError.cannotWrite("the picture could not be drawn") }
        try ImageWriter.write(cg, to: destination, photo: options, metadata: PhotoLoader.metadata(of: source, removeLocation: options.removeLocation))
        return (cg.width, cg.height)
    }
}

public extension ImageWriter {
    /// Writes a picture in one of the photo formats, with the given metadata.
    static func write(_ image: CGImage, to url: URL, photo options: PhotoExportOptions, metadata: [CFString: Any] = [:]) throws {
        let type: UTType
        switch options.format { case .jpeg: type = .jpeg; case .png: type = .png; case .heic: type = .heic; case .tiff: type = .tiff; case .gif: type = .gif }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw PhotoError.cannotWrite("\(options.format.rawValue) cannot be written on this Mac") }
        var props = metadata
        if options.format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.3, options.quality)) }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoError.cannotWrite("the file could not be completed") }
    }
}
