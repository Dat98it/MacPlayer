import Foundation

/// Position, size, opacity and edge of a layer, in the output picture's own terms so they survive a size change.
public struct OverlayTransform: Codable, Equatable, Sendable {
    /// Centre of the layer, 0...1 from the top-left of the output picture.
    public var centerX = 0.8
    public var centerY = 0.78
    /// Width as a fraction of the output width (the height follows the layer's own aspect ratio).
    public var width = 0.3
    public var opacity = 1.0
    /// Border thickness as a fraction of the output height (0 = none).
    public var borderWidth = 0.0
    public var borderHex = "#FFFFFF"
    /// A colour made see-through (green screen). Nil = none.
    public var chromaKey: ChromaKey?
    /// Keeps only a shape of the layer's picture. Nil = the whole picture.
    public var mask: MaskSpec?
    /// How the layer's colours mix with the picture under it.
    public var blend: LayerBlend = .normal
    /// Cuts the person (or the main subject) out of the layer's picture and drops the background.
    public var isolateSubject = false
    /// Degrees, clockwise.
    public var rotation = 0.0
    public init() {}

    /// Keeps every value in a range that cannot produce an invisible or absurd layer.
    public func clamped() -> OverlayTransform {
        var t = self
        t.centerX = min(max(centerX, -0.5), 1.5); t.centerY = min(max(centerY, -0.5), 1.5)
        t.width = min(max(width, 0.02), 2); t.opacity = min(max(opacity, 0), 1); t.borderWidth = min(max(borderWidth, 0), 0.05)
        t.mask = mask?.clamped()
        t.rotation = min(max(rotation, -720), 720)
        return t
    }
}

extension OverlayTransform {
    enum CodingKeys: String, CodingKey { case centerX, centerY, width, opacity, borderWidth, borderHex, chromaKey, mask, blend, isolateSubject, rotation }

    /// Projects saved before masks and blending existed have none of those keys: they open with none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.8
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.78
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.3
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        borderHex = try c.decodeIfPresent(String.self, forKey: .borderHex) ?? "#FFFFFF"
        chromaKey = try c.decodeIfPresent(ChromaKey.self, forKey: .chromaKey)
        mask = try c.decodeIfPresent(MaskSpec.self, forKey: .mask)
        blend = try c.decodeIfPresent(LayerBlend.self, forKey: .blend) ?? .normal
        isolateSubject = try c.decodeIfPresent(Bool.self, forKey: .isolateSubject) ?? false
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }
}

/// The animated values at one instant (what the compositor draws).
public struct OverlayState: Equatable, Sendable {
    public var centerX: Double, centerY: Double, width: Double, opacity: Double
    /// Degrees, clockwise.
    public var rotation: Double
    public init(centerX: Double, centerY: Double, width: Double, opacity: Double, rotation: Double = 0) {
        self.centerX = centerX; self.centerY = centerY; self.width = width; self.opacity = opacity; self.rotation = rotation
    }
}

/// A keyframe: the layer's position, size, turn and opacity at a time counted from the layer's own start.
public struct OverlayKeyframe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: MediaTime
    public var centerX: Double, centerY: Double, width: Double, opacity: Double
    public var rotation: Double
    /// How the values move on from this keyframe to the next.
    public var easing: Easing
    public init(id: UUID = UUID(), time: MediaTime, centerX: Double, centerY: Double, width: Double, opacity: Double, rotation: Double = 0, easing: Easing = .linear) {
        self.id = id; self.time = time; self.centerX = centerX; self.centerY = centerY; self.width = width; self.opacity = opacity; self.rotation = rotation; self.easing = easing
    }

    enum CodingKeys: String, CodingKey { case id, time, centerX, centerY, width, opacity, rotation, easing }

    /// Projects saved before turning and easing existed open with a straight, unturned animation.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); time = try c.decode(MediaTime.self, forKey: .time)
        centerX = try c.decode(Double.self, forKey: .centerX); centerY = try c.decode(Double.self, forKey: .centerY)
        width = try c.decode(Double.self, forKey: .width); opacity = try c.decode(Double.self, forKey: .opacity)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .linear
    }
}

/// What the animation maths needs from a layer. Shared by the project's clip and the render job's spec,
/// so the preview and the export interpolate identically.
public protocol OverlayAnimating {
    var transform: OverlayTransform { get }
    var keyframes: [OverlayKeyframe] { get }
    var start: MediaTime { get }
    var duration: MediaTime { get }
    var fadeIn: Double { get }
    var fadeOut: Double { get }
    /// How the layer arrives and leaves (slide, zoom, pop...), on top of its keyframes. Nil = none.
    var animationIn: ElementAnimation? { get }
    var animationOut: ElementAnimation? { get }
}

extension OverlayAnimating {
    public var end: MediaTime { start + duration }

    /// Values at timeline time `t`, or nil when the layer is not on screen then. Between keyframes the values change in a
    /// straight line; before the first and after the last they hold. Fades multiply the opacity.
    public func state(at t: MediaTime) -> OverlayState? {
        guard t >= start, t < end else { return nil }
        let rel = (t - start).seconds
        var s = OverlayState(centerX: transform.centerX, centerY: transform.centerY, width: transform.width, opacity: transform.opacity, rotation: transform.rotation)
        let kfs = keyframes.sorted { $0.time < $1.time }
        if let first = kfs.first, let last = kfs.last {
            if rel <= first.time.seconds { s = Self.state(first) }
            else if rel >= last.time.seconds { s = Self.state(last) }
            else if let i = kfs.indices.dropLast().first(where: { rel < kfs[$0 + 1].time.seconds }) {
                let a = kfs[i], b = kfs[i + 1]
                let span = b.time.seconds - a.time.seconds
                let f = a.easing.apply(span > 0 ? (rel - a.time.seconds) / span : 0)
                func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
                s = OverlayState(centerX: mix(a.centerX, b.centerX), centerY: mix(a.centerY, b.centerY), width: mix(a.width, b.width), opacity: mix(a.opacity, b.opacity),
                                 rotation: mix(a.rotation, b.rotation))
            }
        }
        var fade = 1.0
        if fadeIn > 0 { fade = min(fade, rel / fadeIn) }
        if fadeOut > 0 { fade = min(fade, (duration.seconds - rel) / fadeOut) }
        s.opacity = min(max(s.opacity * max(0, min(1, fade)), 0), 1)
        // Arriving and leaving: the same moves text uses, applied to the layer's place, size, turn and opacity.
        let total = duration.seconds
        if let a = animationIn, a.kind != .none, a.kind != .typewriter, a.duration > 0, rel < a.duration { Self.animate(a.kind, progress: rel / a.duration, leaving: false, on: &s) }
        if let a = animationOut, a.kind != .none, a.kind != .typewriter, a.duration > 0, total - rel < a.duration { Self.animate(a.kind, progress: (total - rel) / a.duration, leaving: true, on: &s) }
        s.opacity = min(max(s.opacity, 0), 1)
        return s
    }

    private static func animate(_ kind: ElementAnimationKind, progress: Double, leaving: Bool, on s: inout OverlayState) {
        var e = ElementState(x: s.centerX, y: s.centerY, scale: 1, rotation: s.rotation, alpha: 1)
        ElementAnimator.apply(kind, progress: progress, leaving: leaving, to: &e)
        s.centerX = e.x; s.centerY = e.y; s.width *= e.scale; s.rotation = e.rotation; s.opacity *= e.alpha
    }

    static func state(_ k: OverlayKeyframe) -> OverlayState { OverlayState(centerX: k.centerX, centerY: k.centerY, width: k.width, opacity: k.opacity, rotation: k.rotation) }

    /// Where the layer sits in an output of `outputWidth` x `outputHeight`, for a layer picture of the given aspect ratio.
    /// Rectangle with the origin at the top-left.
    public static func rect(for s: OverlayState, outputWidth: Double, outputHeight: Double, aspect: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = s.width * outputWidth, h = w / max(0.01, aspect)
        return (s.centerX * outputWidth - w / 2, s.centerY * outputHeight - h / 2, w, h)
    }
}

public enum OverlayKind: Codable, Equatable, Sendable {
    case video(sourceID: UUID, sourceStart: MediaTime, sourceEnd: MediaTime)
    case image(path: String, bookmark: Data?)
}

/// A video or picture laid over the main timeline (Picture in Picture, logo, watermark).
public struct OverlayClip: Codable, Identifiable, Equatable, Sendable, OverlayAnimating {
    public static let laneCount = 3

    public var id: UUID
    public var name: String
    public var kind: OverlayKind
    /// 0 = lowest layer; higher lanes are drawn on top.
    public var lane: Int
    /// Where it starts on the main timeline, and how long it stays.
    public var start: MediaTime
    public var duration: MediaTime
    public var transform: OverlayTransform
    public var keyframes: [OverlayKeyframe]
    public var audio: AudioSettings
    public var fadeIn: Double
    public var fadeOut: Double
    public var animationIn: ElementAnimation?
    public var animationOut: ElementAnimation?
    /// Layers and elements with the same group move and get selected together (0.12).
    public var groupID: UUID?
    /// A locked layer cannot be moved, resized or deleted on the picture (0.12).
    public var locked: Bool?

    public init(id: UUID = UUID(), name: String, kind: OverlayKind, lane: Int = 0, start: MediaTime, duration: MediaTime,
                transform: OverlayTransform = OverlayTransform(), keyframes: [OverlayKeyframe] = [], audio: AudioSettings = AudioSettings(),
                fadeIn: Double = 0, fadeOut: Double = 0, animationIn: ElementAnimation? = nil, animationOut: ElementAnimation? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.lane = lane; self.start = start; self.duration = duration
        self.transform = transform; self.keyframes = keyframes; self.audio = audio; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.animationIn = animationIn; self.animationOut = animationOut
    }

    public var span: TimeSpan { TimeSpan(start: start, end: end) }
    public var isVideo: Bool { if case .video = kind { return true }; return false }
    public var sourceID: UUID? { if case .video(let id, _, _) = kind { return id }; return nil }
}

/// What the renderer needs for one layer, with paths instead of project ids. Saved with export jobs.
public struct LayerSpec: Codable, Equatable, Sendable, OverlayAnimating {
    /// The id of the project's layer this was made from (the preview uses it to follow a drag live).
    public var id: UUID
    public enum Kind: Codable, Equatable, Sendable {
        case video(path: String, sourceStart: MediaTime, sourceEnd: MediaTime)
        case image(path: String)
    }
    public var kind: Kind
    public var lane: Int
    public var start: MediaTime
    public var duration: MediaTime
    public var transform: OverlayTransform
    public var keyframes: [OverlayKeyframe]
    public var audio: AudioSettings
    public var fadeIn: Double
    public var fadeOut: Double
    public var animationIn: ElementAnimation?
    public var animationOut: ElementAnimation?

    public init(id: UUID = UUID(), kind: Kind, lane: Int, start: MediaTime, duration: MediaTime, transform: OverlayTransform = OverlayTransform(),
                keyframes: [OverlayKeyframe] = [], audio: AudioSettings = AudioSettings(), fadeIn: Double = 0, fadeOut: Double = 0,
                animationIn: ElementAnimation? = nil, animationOut: ElementAnimation? = nil) {
        self.id = id; self.kind = kind; self.lane = lane; self.start = start; self.duration = duration; self.transform = transform
        self.keyframes = keyframes; self.audio = audio; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.animationIn = animationIn; self.animationOut = animationOut
    }

    public var path: String { switch kind { case .video(let p, _, _): return p; case .image(let p): return p } }
}

public enum OverlayEditor {
    /// The lowest lane with nothing in it during `[start, start + duration)`, or nil when all lanes are busy then.
    public static func firstFreeLane(_ clips: [OverlayClip], start: MediaTime, duration: MediaTime, ignoring id: UUID? = nil) -> Int? {
        let span = TimeSpan(start: start, end: start + duration)
        for lane in 0..<OverlayClip.laneCount where !clips.contains(where: { $0.id != id && $0.lane == lane && $0.span.overlaps(span) }) { return lane }
        return nil
    }

    /// Moves a clip to a new start (never before 0, never beyond `limit`) and lane. A move that would land on another clip
    /// in the same lane is refused (returns false), so layers never silently stack on one lane.
    @discardableResult
    public static func move(_ clips: inout [OverlayClip], id: UUID, toStart: MediaTime, lane: Int? = nil, limit: MediaTime? = nil) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return false }
        var s = max(.zero, toStart)
        if let l = limit, s + clips[i].duration > l { s = max(.zero, l - clips[i].duration) }
        let target = min(max(lane ?? clips[i].lane, 0), OverlayClip.laneCount - 1)
        let span = TimeSpan(start: s, end: s + clips[i].duration)
        if clips.contains(where: { $0.id != id && $0.lane == target && $0.span.overlaps(span) }) { return false }
        clips[i].start = s; clips[i].lane = target
        return true
    }

    /// Drags an edge. Videos trim their source range (the picture, not the pace); pictures just get shorter or longer.
    /// Never shorter than a tenth of a second, never overlapping a neighbour in the lane.
    public static func trim(_ clips: inout [OverlayClip], id: UUID, leftEdge: Bool, toTimelineTime t: MediaTime, sourceDuration: MediaTime? = nil, limit: MediaTime? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let c = clips[i]
        let minLen = MediaTime(seconds: 0.1, timescale: 600)
        var newStart = c.start, newEnd = c.end
        if leftEdge { newStart = min(max(.zero, t), c.end - minLen) } else { newEnd = max(t, c.start + minLen) }
        if let l = limit { newEnd = min(newEnd, max(l, newStart + minLen)) }
        // A neighbour in the same lane stops the edge.
        for o in clips where o.id != id && o.lane == c.lane {
            if leftEdge, o.end <= c.start { newStart = max(newStart, o.end) }
            if !leftEdge, o.start >= c.end { newEnd = min(newEnd, o.start) }
        }
        var updated = c
        if case .video(let sid, let ss, let se) = c.kind {
            var ns = ss + (newStart - c.start), ne = se - (c.end - newEnd)
            ns = max(.zero, ns); if let d = sourceDuration { ne = min(ne, d) }
            guard ne - ns >= minLen else { return }
            newStart = c.start + (ns - ss); newEnd = c.end - (se - ne)
            updated.kind = .video(sourceID: sid, sourceStart: ns, sourceEnd: ne)
        }
        guard newEnd - newStart >= minLen else { return }
        updated.start = newStart; updated.duration = newEnd - newStart
        // Keyframes outside the new length are dropped; the first and last keep the clip animated.
        let len = updated.duration
        updated.keyframes = updated.keyframes.compactMap { k in
            var n = k; n.time = k.time - (newStart - c.start)
            return n.time >= .zero && n.time <= len ? n : nil
        }
        clips[i] = updated
    }

    /// Records the layer's values at `relative` time as a keyframe (replacing one at the same time).
    public static func setKeyframe(_ clip: inout OverlayClip, at relative: MediaTime, to s: OverlayState) {
        let r = min(max(relative, .zero), clip.duration)
        let k = OverlayKeyframe(time: r, centerX: s.centerX, centerY: s.centerY, width: s.width, opacity: s.opacity, rotation: s.rotation)
        if let i = clip.keyframes.firstIndex(where: { abs($0.time.seconds - r.seconds) < 1.0 / 120 }) { var n = k; n.id = clip.keyframes[i].id; n.time = clip.keyframes[i].time; n.easing = clip.keyframes[i].easing; clip.keyframes[i] = n }
        else { clip.keyframes.append(k) }
        clip.keyframes.sort { $0.time < $1.time }
    }

    /// The values to show for editing at `t` without fades: base transform, or the interpolated keyframes.
    public static func editableState(_ clip: OverlayClip, at t: MediaTime) -> OverlayState {
        var plain = clip; plain.fadeIn = 0; plain.fadeOut = 0; plain.animationIn = nil; plain.animationOut = nil
        let inside = min(max(t, clip.start), clip.end - MediaTime(value: 1, timescale: 6000))
        return plain.state(at: inside) ?? OverlayState(centerX: clip.transform.centerX, centerY: clip.transform.centerY, width: clip.transform.width, opacity: clip.transform.opacity, rotation: clip.transform.rotation)
    }

    /// Corner and centre presets for Picture in Picture.
    public enum Preset: String, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight, center, full }

    /// `outputAspect` and `layerAspect` are width / height of the output picture and of the layer's own picture; the margin
    /// is 3% of the output width on every side.
    public static func apply(_ p: Preset, to t: inout OverlayTransform, outputAspect: Double = 16.0 / 9, layerAspect: Double = 16.0 / 9) {
        let mx = 0.03, my = mx * outputAspect                       // same distance in pixels, as a fraction of each side
        let halfH = t.width * outputAspect / max(0.01, layerAspect) / 2   // half the layer's height, as a fraction of the output height
        switch p {
        case .topLeft: t.centerX = t.width / 2 + mx; t.centerY = halfH + my
        case .topRight: t.centerX = 1 - t.width / 2 - mx; t.centerY = halfH + my
        case .bottomLeft: t.centerX = t.width / 2 + mx; t.centerY = 1 - halfH - my
        case .bottomRight: t.centerX = 1 - t.width / 2 - mx; t.centerY = 1 - halfH - my
        case .center: t.centerX = 0.5; t.centerY = 0.5
        case .full: t.centerX = 0.5; t.centerY = 0.5; t.width = 1
        }
    }
}

/// The geometry of dragging a layer on the picture, in the output picture's own coordinates: x and y run 0...1 from the
/// top-left, a width is a fraction of the output width, a height a fraction of the output height. Pure, so it is tested
/// without a window; the view only turns mouse positions into these numbers.
public enum OverlayDrag {
    public enum Corner: CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

    public struct Rect: Equatable, Sendable {
        public var x0: Double, y0: Double, x1: Double, y1: Double
        public var width: Double { x1 - x0 }
        public var height: Double { y1 - y0 }
        public func corner(_ c: Corner) -> (x: Double, y: Double) {
            switch c {
            case .topLeft: return (x0, y0); case .topRight: return (x1, y0)
            case .bottomLeft: return (x0, y1); case .bottomRight: return (x1, y1)
            }
        }
    }

    /// Height as a fraction of the output height, for a layer of its own aspect ratio.
    public static func heightFraction(width: Double, outputAspect: Double, layerAspect: Double) -> Double { width * outputAspect / max(0.01, layerAspect) }

    public static func rect(_ s: OverlayState, outputAspect: Double, layerAspect: Double) -> Rect {
        let h = heightFraction(width: s.width, outputAspect: outputAspect, layerAspect: layerAspect)
        return Rect(x0: s.centerX - s.width / 2, y0: s.centerY - h / 2, x1: s.centerX + s.width / 2, y1: s.centerY + h / 2)
    }

    /// Moves the centre by a distance in output units. Kept within a range where part of the layer stays reachable.
    public static func move(_ start: OverlayState, dx: Double, dy: Double) -> OverlayState {
        var s = start
        s.centerX = min(max(start.centerX + dx, -0.2), 1.2)
        s.centerY = min(max(start.centerY + dy, -0.2), 1.2)
        return s
    }

    /// Drags one corner to `point`. The opposite corner stays where it was and the layer keeps its shape; the width comes
    /// from how far the point is from that fixed corner, never smaller than `minWidth`.
    public static func resize(_ start: OverlayState, corner: Corner, to point: (x: Double, y: Double), outputAspect: Double, layerAspect: Double,
                              minWidth: Double = 0.05, maxWidth: Double = 2) -> OverlayState {
        let r = rect(start, outputAspect: outputAspect, layerAspect: layerAspect)
        let anchor: (x: Double, y: Double)
        switch corner { case .topLeft: anchor = r.corner(.bottomRight); case .topRight: anchor = r.corner(.bottomLeft)
        case .bottomLeft: anchor = r.corner(.topRight); case .bottomRight: anchor = r.corner(.topLeft) }
        let w = min(max(abs(point.x - anchor.x), minWidth), maxWidth)
        let h = heightFraction(width: w, outputAspect: outputAspect, layerAspect: layerAspect)
        let sx: Double = (corner == .topRight || corner == .bottomRight) ? 1 : -1
        let sy: Double = (corner == .bottomLeft || corner == .bottomRight) ? 1 : -1
        var s = start
        s.width = w
        s.centerX = anchor.x + sx * w / 2
        s.centerY = anchor.y + sy * h / 2
        return s
    }

    public struct Snapped: Equatable, Sendable {
        public var state: OverlayState
        /// Lines the layer snapped to (output units), for drawing guides.
        public var guideX: Double?
        public var guideY: Double?
    }

    /// Pulls the layer onto the centre lines and onto the picture's margins and edges when it is within `tolerance`
    /// (output units). The margin matches the Picture in Picture presets: 3% of the width on every side.
    public static func snapped(_ s: OverlayState, outputAspect: Double, layerAspect: Double, tolerance: Double = 0.012, margin: Double = 0.03) -> Snapped {
        let r = rect(s, outputAspect: outputAspect, layerAspect: layerAspect)
        var out = s, gx: Double?, gy: Double?
        func best(_ options: [(shift: Double, line: Double)]) -> (shift: Double, line: Double)? {
            options.filter { abs($0.shift) <= tolerance }.min { abs($0.shift) < abs($1.shift) }
        }
        let my = margin * outputAspect
        if let b = best([(0.5 - s.centerX, 0.5), (margin - r.x0, margin), (1 - margin - r.x1, 1 - margin), (0 - r.x0, 0), (1 - r.x1, 1)]) { out.centerX += b.shift; gx = b.line }
        if let b = best([(0.5 - s.centerY, 0.5), (my - r.y0, my), (1 - my - r.y1, 1 - my), (0 - r.y0, 0), (1 - r.y1, 1)]) { out.centerY += b.shift; gy = b.line }
        return Snapped(state: out, guideX: gx, guideY: gy)
    }
}
