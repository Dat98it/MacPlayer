import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MacPlayerCore

/// What to do to one stretch of the composition (one clip): its look and how the source is oriented.
struct PiecePlan {
    var look: VideoLook
    /// The orientation stored in the source track (phone video held upright), applied before anything else.
    var trackOrientation: CGImagePropertyOrientation
    /// Source size in pixels as stored (before orientation).
    var storedSize: PixelSize
    /// Where this clip starts on the composition's timeline, in seconds: animations count from here.
    var rangeStart: Double = 0
    /// Steadying for this clip, and where it starts in its source and how fast it plays (to find the source frame being drawn).
    var stabilizer: StabilizerPlan?
    var sourceStart: Double = 0
    var speed: Double = 1
    /// A preview only: the effects of this clip may be replaced while it plays (see `EffectsLive`).
    var liveKey: UUID?
    /// How carefully a subject is cut out of its background (a preview is quick, an export and a photo are careful).
    var subjectMode: SubjectMasker.Mode = .exportVideo
}

/// Everything time-based that is drawn over the picture, shared by all instructions. Drawn text images are cached
/// per size, so each frame costs a lookup rather than a layout.
final class OverlayLayer: @unchecked Sendable {
    let overlays: [TextOverlay]
    let cues: [SubtitleCue]
    let style: SubtitleStyle
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    init(overlays: [TextOverlay], cues: [SubtitleCue], style: SubtitleStyle) {
        self.overlays = overlays
        self.cues = cues.sorted { $0.start < $1.start }
        self.style = style
    }

    var isEmpty: Bool { overlays.isEmpty && cues.isEmpty }

    private func image(key: String, size: CGSize, make: () -> OverlayRenderer.TextBox?, makeImage: (() -> CGImage?)? = nil) -> CIImage? {
        let k = "\(key)@\(Int(size.width))x\(Int(size.height))"
        lock.lock(); let hit = cache[k]; lock.unlock()
        if let hit { return hit }
        let drawn: CGImage? = makeImage?() ?? make().flatMap { OverlayRenderer.render($0, size: size) }
        guard let cg = drawn else { return nil }
        let ci = CIImage(cgImage: cg)
        lock.lock()
        if cache.count > 80 { cache.removeAll() }
        cache[k] = ci
        lock.unlock()
        return ci
    }

    /// Overlay images visible at output time `t` (seconds), with their opacity. Each is moved, scaled and turned to where its animation
    /// has put it at that moment, so a drawn element is made once and only transformed per frame.
    func visible(at t: Double, size: CGSize) -> [(CIImage, Double)] {
        var out: [(CIImage, Double)] = []
        for o in overlays {
            guard let st = ElementAnimator.state(of: o, at: t), st.alpha > 0.001 else { continue }
            let still = o.id.uuidString + "|\(o.x)|\(o.y)|\(o.sizeFraction)|\(o.colorHex)|\(o.backgroundHex ?? "-")|\(o.fontName)|\(o.alignment)"
            var img: CIImage?
            if let shape = o.shape {
                img = image(key: still + "|S\(shape)", size: size, make: { nil }, makeImage: { OverlayRenderer.renderShape(shape, centerX: o.x, centerY: o.y, size: size) })
            } else {
                let shown = st.reveal >= 1 ? -1 : Int(ceil(Double(o.text.count) * max(0, st.reveal)))
                if st.reveal < 1 && shown <= 0 { continue }
                img = image(key: still + "|\(o.text)|\(String(describing: o.flair))|\(shown)", size: size, make: { OverlayRenderer.box(for: o, reveal: st.reveal) })
            }
            guard var picture = img else { continue }
            if st.x != o.x || st.y != o.y || st.scale != 1 || st.rotation != 0 {
                let c0 = CGPoint(x: o.x * size.width, y: (1 - o.y) * size.height), c1 = CGPoint(x: st.x * size.width, y: (1 - st.y) * size.height)
                var m = CGAffineTransform(translationX: -c0.x, y: -c0.y)
                m = m.concatenating(CGAffineTransform(scaleX: st.scale, y: st.scale))
                m = m.concatenating(CGAffineTransform(rotationAngle: -st.rotation * .pi / 180))        // clockwise on screen, and Core Image's y points up
                m = m.concatenating(CGAffineTransform(translationX: c1.x, y: c1.y))
                picture = picture.transformed(by: m)
            }
            out.append((picture, st.alpha))
        }
        for c in cues where t >= c.start.seconds && t < c.end.seconds {
            if let img = image(key: "c\(c.id)\(c.text)", size: size, make: { OverlayRenderer.box(for: c, style: style) }) { out.append((img, 1)) }
        }
        return out
    }
}

/// One layer (video or picture) as the compositor draws it.
struct LayerDraw {
    var spec: LayerSpec
    /// True only in a preview: the layer may then follow `LayerLive` (a drag in progress). Exports never do.
    var live = false
    /// The composition track that carries a video layer's frames; nil for a picture.
    var trackID: CMPersistentTrackID?
    var orientation: CGImagePropertyOrientation
    var image: CIImage?
    var border: CIColor
}

/// The incoming picture of a transition: which track carries it, how it is drawn, and when the transition starts and ends (seconds).
struct TransitionDraw {
    var trackID: CMPersistentTrackID
    var plan: PiecePlan
    var kind: TransitionKind
    var start: Double
    var end: Double
}

final class RecipeInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let plan: PiecePlan
    let layer: OverlayLayer
    /// Layers on screen during this stretch, lowest lane first.
    let layers: [LayerDraw]
    /// Set during a transition: the picture arriving while `trackID`'s picture leaves.
    let second: TransitionDraw?

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, plan: PiecePlan, layer: OverlayLayer, layers: [LayerDraw] = [], second: TransitionDraw? = nil) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.second = second
        self.requiredSourceTrackIDs = ([trackID] + (second.map { [$0.trackID] } ?? []) + layers.compactMap(\.trackID)).map { NSNumber(value: $0) }
        self.plan = plan
        self.layer = layer
        self.layers = layers.sorted { $0.spec.lane < $1.spec.lane }
    }
}

/// The one renderer behind both the preview and the export: crop, rotate, flip, canvas, colour, text, subtitles.
class RecipeCompositor: NSObject, AVVideoCompositing {
    static let ciContext: CIContext = {
        // No colour management: pixels pass through unchanged unless an adjustment is asked for.
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }()

    private let queue = DispatchQueue(label: "macplayer.compositor", qos: .userInitiated)

    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let inst = request.videoCompositionInstruction as? RecipeInstruction,
                      let src = request.sourceFrame(byTrackID: inst.trackID),
                      let out = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "MacPlayer.Compositor", code: 1, userInfo: [NSLocalizedDescriptionKey: "no frame to compose"]))
                    return
                }
                let size = request.renderContext.size
                let frames: [(LayerDraw, CVPixelBuffer?)] = inst.layers.map { d in (d, d.trackID.flatMap { request.sourceFrame(byTrackID: $0) }) }
                let second: (CVPixelBuffer, TransitionDraw)? = inst.second.flatMap { t in request.sourceFrame(byTrackID: t.trackID).map { ($0, t) } }
                let image = Self.render(source: src, plan: inst.plan, layer: inst.layer, time: request.compositionTime.seconds, outputSize: size, layerFrames: frames, second: second)
                Self.tagColor(of: out, like: src)          // before drawing: a 10-bit buffer is converted to YCbCr using the tags it carries
                Self.ciContext.render(image, to: out)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: Rendering (also called directly by tests)

    /// The main picture of one clip at one moment: crop, rotation, flips, canvas, colour, zoom and effects (no layers or text yet).
    static func mainPicture(source: CVPixelBuffer, plan: PiecePlan, time: Double, outputSize: CGSize) -> CIImage {
        mainPicture(base: normalized(CIImage(cvPixelBuffer: source).oriented(plan.trackOrientation)), plan: plan, time: time, outputSize: outputSize)
    }

    /// The same for a picture that is already upright (a photo, or a video frame after its orientation was applied).
    static func mainPicture(base: CIImage, plan: PiecePlan, time: Double, outputSize: CGSize) -> CIImage {
        var img = base
        let look = plan.look

        // Steadying: move the picture against the shake and enlarge it a little so the moved edge stays out of view.
        if let st = plan.stabilizer, !st.dx.isEmpty {
            let sourceTime = plan.sourceStart + (time - plan.rangeStart) * plan.speed
            let i = min(max(Int((sourceTime * st.fps).rounded()), 0), st.dx.count - 1)
            let e = img.extent
            let cx = e.midX, cy = e.midY
            var t = CGAffineTransform(translationX: -cx, y: -cy).concatenating(CGAffineTransform(scaleX: st.zoom, y: st.zoom))
            t = t.concatenating(CGAffineTransform(translationX: cx + Double(st.dx[i]) * e.width, y: cy + Double(st.dy[i]) * e.height))
            img = normalized(img.transformed(by: t).cropped(to: e))
        }

        // Crop (normalised, origin top-left) in the upright picture.
        if !look.crop.isFull {
            let c = look.crop.clamped()
            let W = img.extent.width, H = img.extent.height
            let rect = CGRect(x: c.x * W, y: (1 - c.y - c.height) * H, width: c.width * W, height: c.height * H).integral
            img = normalized(img.cropped(to: rect))
        }

        // Rotation (clockwise quarter turns), then flips.
        switch ((look.rotation % 360) + 360) % 360 {
        case 90: img = normalized(img.oriented(.right))
        case 180: img = normalized(img.oriented(.down))
        case 270: img = normalized(img.oriented(.left))
        default: break
        }
        if look.flipHorizontal { img = normalized(img.oriented(.upMirrored)) }
        if look.flipVertical { img = normalized(img.oriented(.downMirrored)) }

        // Fit or fill into the output frame, centred, on black.
        let ow = Double(outputSize.width), oh = Double(outputSize.height)
        let placed = RenderGeometry.placement(edited: PixelSize(width: Int(img.extent.width), height: Int(img.extent.height)),
                                              canvas: PixelSize(width: Int(ow), height: Int(oh)), fit: look.fit)
        let upright = img          // before it is placed: the blurred backdrop is made from this
        let k = placed.width / img.extent.width
        img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        // CI origin is bottom-left; `placed.y` is measured from the top.
        let tx = placed.x, ty = oh - placed.y - placed.height
        img = img.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        let frame = CGRect(x: 0, y: 0, width: ow, height: oh)
        let effects = plan.liveKey.flatMap { EffectsLive.effects(for: $0) } ?? look.effects
        // What is cut away (a key colour, a subject cut-out, a shape) shows the backdrop: a colour, the blurred picture, or black.
        var placedPicture = img.cropped(to: frame)
        if look.cutsOut {
            if let key = look.chromaKey { placedPicture = LookEffectsRenderer.chromaKeyed(placedPicture, key: key) }
            if look.isolateSubject, let subject = SubjectMasker.mask(for: upright, mode: plan.subjectMode) {
                let moved = subject.transformed(by: CGAffineTransform(scaleX: k, y: k)).transformed(by: CGAffineTransform(translationX: tx, y: ty))
                placedPicture = MaskRenderer.apply(moved, to: placedPicture)
            }
            if let m = look.mask { placedPicture = MaskRenderer.apply(MaskRenderer.alpha(m, size: frame.size), to: placedPicture) }
        }
        let backdrop: CIImage
        if effects.blurBackground && look.fit == .fit && !look.cutsOut {
            backdrop = LookEffectsRenderer.backdrop(of: upright, frame: frame, amount: effects.blurBackgroundAmount)
        } else if let hex = look.backdropHex {
            backdrop = CIImage(color: CompositionBuilder.ciColor(hex: hex)).cropped(to: frame)
        } else if effects.blurBackground && look.cutsOut {
            backdrop = LookEffectsRenderer.backdrop(of: upright, frame: frame, amount: effects.blurBackgroundAmount)
        } else {
            backdrop = CIImage(color: .black).cropped(to: frame)
        }
        var out = placedPicture.composited(over: backdrop)

        // Colour (the basic sliders, then curves, wheels, HSL and look files).
        let colour = plan.liveKey.flatMap { ColorLive.colour(for: $0) } ?? look.color
        if !colour.isNeutral { out = ColorGradeRenderer.apply(colour, to: out) }

        // Zoom and move over the clip.
        if !look.motion.isEmpty, let m = Motion.state(look.motion, at: max(0, time - plan.rangeStart)), m != .still {
            out = LookEffectsRenderer.zoomed(out, state: m, frame: frame)
        }

        // Filter, sharpen, blur, vignette.
        if !effects.isNeutral { out = LookEffectsRenderer.apply(effects, to: out, frame: frame) }

        return out.cropped(to: frame)
    }

    static func render(source: CVPixelBuffer, plan: PiecePlan, layer: OverlayLayer, time: Double, outputSize: CGSize, layerFrames: [(LayerDraw, CVPixelBuffer?)] = [],
                       second: (CVPixelBuffer, TransitionDraw)? = nil) -> CIImage {
        let ow = Double(outputSize.width), oh = Double(outputSize.height)
        let frame = CGRect(x: 0, y: 0, width: ow, height: oh)
        var out = mainPicture(source: source, plan: plan, time: time, outputSize: outputSize)
        if let (incoming, t) = second {
            let arriving = mainPicture(source: incoming, plan: t.plan, time: time, outputSize: outputSize)
            let progress = t.end > t.start ? min(max((time - t.start) / (t.end - t.start), 0), 1) : 1
            out = TransitionRenderer.blend(outgoing: out, incoming: arriving, kind: t.kind, progress: progress, frame: frame)
        }

        // Layers (Picture in Picture, logos), lowest lane first, over the colour-adjusted main picture.
        for (d, pb) in layerFrames {
            let spec = d.live ? (LayerLive.spec(for: d.spec.id) ?? d.spec) : d.spec
            guard let st = spec.state(at: MediaTime(seconds: time, timescale: 6000)), st.opacity > 0.001 else { continue }
            var li: CIImage
            if let pb { li = normalized(CIImage(cvPixelBuffer: pb).oriented(d.orientation)) } else if let im = d.image { li = normalized(im) } else { continue }
            guard li.extent.width > 0, li.extent.height > 0 else { continue }
            if let key = spec.transform.chromaKey { li = LookEffectsRenderer.chromaKeyed(li, key: key) }
            if spec.transform.isolateSubject, let subject = SubjectMasker.mask(for: li, mode: plan.subjectMode) { li = MaskRenderer.apply(subject, to: li) }
            if let m = spec.transform.mask { li = MaskRenderer.apply(MaskRenderer.alpha(m, size: li.extent.size), to: li) }
            let r = OverlayRect.rect(for: st, outputWidth: ow, outputHeight: oh, aspect: Double(li.extent.width / li.extent.height))
            let k = r.width / Double(li.extent.width)
            li = li.transformed(by: CGAffineTransform(scaleX: k, y: k))
            // CI origin is bottom-left; `r.y` is measured from the top.
            li = li.transformed(by: CGAffineTransform(translationX: r.x, y: oh - r.y - r.height))
            let bw = spec.transform.borderWidth * oh
            if bw > 0.5 {
                let edge = CIImage(color: d.live ? CompositionBuilder.ciColor(hex: spec.transform.borderHex) : d.border).cropped(to: li.extent.insetBy(dx: -bw, dy: -bw))
                li = li.composited(over: edge)
            }
            if st.rotation != 0 {
                let c = CGPoint(x: r.x + r.width / 2, y: oh - r.y - r.height / 2)
                li = li.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(rotationAngle: -st.rotation * .pi / 180)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            }
            if st.opacity < 0.999 { li = li.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: st.opacity)]) }
            if let blend = spec.transform.blend.filterName {
                out = li.applyingFilter(blend, parameters: [kCIInputBackgroundImageKey: out]).cropped(to: frame)
            } else {
                out = li.composited(over: out).cropped(to: frame)
            }
        }

        // Text and subtitles.
        if !layer.isEmpty {
            for (overlay, alpha) in layer.visible(at: time, size: outputSize) {
                let o = alpha >= 1 ? overlay : overlay.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                out = o.composited(over: out)
            }
        }
        return out.cropped(to: frame)
    }

    /// Gives the output the same colour description as the frame it came from. Without it, the encoder and the
    /// preview guess differently and the picture shifts by several levels. Untagged sources get BT.709 (HD) or
    /// BT.601 (SD), the usual assumption of the system decoders.
    static func tagColor(of out: CVPixelBuffer, like src: CVPixelBuffer) {
        if ProcessInfo.processInfo.environment["MACPLAYER_DEBUG_TAGS"] != nil { print("compositor source tags: \(CVBufferCopyAttachments(src, .shouldPropagate) ?? [:] as CFDictionary), format \(CVPixelBufferGetPixelFormatType(src))") }
        func get(_ key: CFString) -> CFTypeRef? { CVBufferCopyAttachment(src, key, nil) }
        let hd = CVPixelBufferGetWidth(out) >= 1280 || CVPixelBufferGetHeight(out) >= 720
        let primaries = get(kCVImageBufferColorPrimariesKey) ?? (hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C)
        let transfer = get(kCVImageBufferTransferFunctionKey) ?? kCVImageBufferTransferFunction_ITU_R_709_2
        let matrix = get(kCVImageBufferYCbCrMatrixKey) ?? (hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }

    /// Moves the image's extent to the origin (rotations and crops leave it elsewhere).
    static func normalized(_ i: CIImage) -> CIImage {
        let e = i.extent
        return (e.origin == .zero) ? i : i.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = Int(t.a.rounded()), b = Int(t.b.rounded()), c = Int(t.c.rounded()), d = Int(t.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right
        case (-1, 0, 0, -1): return .down
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .rightMirrored
        case (0, -1, -1, 0): return .leftMirrored
        default: return .up
        }
    }
}

/// `OverlayAnimating.rect` reached through a plain name (a protocol's static helper cannot be called on the protocol itself).
enum OverlayRect {
    static func rect(for s: OverlayState, outputWidth: Double, outputHeight: Double, aspect: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        OverlayClip.rect(for: s, outputWidth: outputWidth, outputHeight: outputHeight, aspect: aspect)
    }
}

/// Layer settings that follow a drag in progress, so the preview can show it without rebuilding the whole composition.
/// Only previews read it (`LayerDraw.live`); an export always draws exactly the spec it was given.
/// The filter and effect settings of the clip being edited, handed to a preview that is already playing so that a click on a filter shows at
/// the next frame without building the whole preview again. Only previews read it; an export always uses the settings it was given.
public enum EffectsLive {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [UUID: LookEffects] = [:]

    public static func set(_ effects: LookEffects, for key: UUID) { lock.lock(); overrides[key] = effects; lock.unlock() }
    public static func clear() { lock.lock(); overrides.removeAll(); lock.unlock() }
    static func effects(for key: UUID) -> LookEffects? { lock.lock(); defer { lock.unlock() }; return overrides[key] }
}

public enum LayerLive {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [UUID: LayerSpec] = [:]

    public static func set(_ spec: LayerSpec) { lock.lock(); overrides[spec.id] = spec; lock.unlock() }
    public static func clear() { lock.lock(); overrides.removeAll(); lock.unlock() }
    static func spec(for id: UUID) -> LayerSpec? { lock.lock(); defer { lock.unlock() }; return overrides[id] }
}


/// The same renderer working on 10-bit pictures, for an HDR export: the pictures keep their HLG or PQ values end to end instead of being
/// tone-mapped to 8-bit SDR on the way in.
final class RecipeCompositor10: RecipeCompositor {
    override var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] }
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] }
}
