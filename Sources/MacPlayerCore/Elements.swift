import Foundation

// Text, shapes and stickers on the picture share one kind of element (`TextOverlay`), so they are saved, exported and drawn the same way.

/// Extra looks for text. Every field is optional: nil keeps what the text looked like before these existed.
public struct TextFlair: Codable, Equatable, Sendable {
    /// Outline colour and thickness (a fraction of the letter size). `outlineWidth` 0 = no outline at all.
    public var outlineHex: String?
    public var outlineWidth: Double?
    public var shadow = false
    public var shadowHex = "#000000"
    /// Space between letters, a fraction of the letter size.
    public var letterSpacing = 0.0
    public var uppercase = false
    public init() {}
}

public enum ElementAnimationKind: String, Codable, CaseIterable, Sendable {
    case none, fade, slideUp, slideDown, slideLeft, slideRight, pop, zoom, typewriter
}

public struct ElementAnimation: Codable, Equatable, Sendable {
    public var kind: ElementAnimationKind
    /// Seconds the animation takes.
    public var duration: Double
    public init(kind: ElementAnimationKind, duration: Double = 0.5) { self.kind = kind; self.duration = duration }
}

public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, roundedRectangle, ellipse, triangle, star, heart, arrow, line
    // 0.14
    case diamond, pentagon, hexagon, speechBubble, burst, checkmark, cross, ring
    // 0.16.5
    case octagon, parallelogram, trapezoid, crescent, lightning, droplet, sparkle, star6, doubleArrow, chevron, capsule, frame, ribbon, tag, shield, cloud, semicircle

    /// Shapes with an empty middle (filled with the even-odd rule).
    public var isHollow: Bool { self == .ring || self == .frame }

    /// Shapes that keep their own proportions on any picture (a square stays square on a wide picture): their height is set from their width
    /// and the picture's shape when they are made.
    public var keepsProportions: Bool { self != .line && self != .arrow }
    /// How tall it is for its width, on screen, when it is made.
    public var naturalHeightRatio: Double {
        switch self {
        case .arrow: return 0.5; case .line: return 0.04; case .speechBubble: return 0.8
        case .parallelogram: return 0.55; case .trapezoid: return 0.6; case .doubleArrow: return 0.45; case .capsule: return 0.4; case .ribbon: return 0.35
        case .tag: return 0.5; case .cloud: return 0.65; case .semicircle: return 0.5; case .droplet: return 1.3; case .shield: return 1.15
        default: return 1
        }
    }
    /// The colour it starts with.
    public var defaultFillHex: String {
        switch self {
        case .speechBubble: return "#FFFFFF"; case .checkmark: return "#34C759"; case .cross: return "#FF3B30"; case .burst: return "#FF2D55"
        case .ring: return "#FFFFFF"; case .diamond: return "#5AC8FA"
        case .octagon: return "#FF3B30"; case .crescent: return "#FFE9A8"; case .lightning: return "#FFD60A"; case .droplet: return "#0A84FF"
        case .sparkle: return "#FFFFFF"; case .star6: return "#FF9F0A"; case .doubleArrow, .chevron: return "#30D158"; case .capsule: return "#5E5CE6"
        case .frame: return "#FFFFFF"; case .ribbon: return "#FF2D55"; case .tag: return "#FF9F0A"; case .shield: return "#0A84FF"; case .cloud: return "#F2F2F7"
        case .semicircle: return "#64D2FF"; case .parallelogram: return "#BF5AF2"; case .trapezoid: return "#FF6482"
        default: return "#FFD60A"
        }
    }
}

public extension ShapeSpec {
    /// A shape `width` wide (a fraction of the picture's width) that looks as it should on a picture of `aspect` (width / height):
    /// a square is square, a circle round.
    static func made(_ kind: ShapeKind, width: Double = 0.18, aspect: Double) -> ShapeSpec {
        let w = kind == .line ? 0.3 : width
        let h = kind == .line ? 0.012 : w * kind.naturalHeightRatio * max(0.1, aspect)
        return ShapeSpec(kind: kind, width: w, height: min(0.95, h), fillHex: kind.defaultFillHex, strokeHex: nil)
    }
}

public struct ShapeSpec: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    /// Size as fractions of the picture's width and height.
    public var width: Double
    public var height: Double
    public var fillHex: String?
    public var strokeHex: String?
    /// Outline thickness as a fraction of the picture's height.
    public var strokeWidth: Double
    public init(kind: ShapeKind, width: Double = 0.2, height: Double = 0.2, fillHex: String? = "#FFD60A", strokeHex: String? = nil, strokeWidth: Double = 0.006) {
        self.kind = kind; self.width = width; self.height = height; self.fillHex = fillHex; self.strokeHex = strokeHex; self.strokeWidth = strokeWidth
    }
}

/// Where an element is, how big and how turned, at a time counted from the element's own start.
public struct ElementKeyframe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var x: Double, y: Double, scale: Double, rotation: Double, opacity: Double
    /// How the values move on from this keyframe to the next.
    public var easing: Easing
    public init(id: UUID = UUID(), time: Double, x: Double, y: Double, scale: Double = 1, rotation: Double = 0, opacity: Double = 1, easing: Easing = .linear) {
        self.id = id; self.time = time; self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.opacity = opacity; self.easing = easing
    }

    enum CodingKeys: String, CodingKey { case id, time, x, y, scale, rotation, opacity, easing }

    /// Projects saved before easing existed open with straight changes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); time = try c.decode(Double.self, forKey: .time)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        scale = try c.decode(Double.self, forKey: .scale); rotation = try c.decode(Double.self, forKey: .rotation); opacity = try c.decode(Double.self, forKey: .opacity)
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .linear
    }
}

/// What the renderer needs at one instant.
public struct ElementState: Equatable, Sendable {
    /// Centre of the element, 0...1 across the picture from the top-left.
    public var x: Double, y: Double
    public var scale: Double
    /// Degrees, clockwise.
    public var rotation: Double
    public var alpha: Double
    /// For the typewriter: how much of the text is showing, 0...1.
    public var reveal: Double
    public init(x: Double, y: Double, scale: Double = 1, rotation: Double = 0, alpha: Double = 1, reveal: Double = 1) {
        self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.alpha = alpha; self.reveal = reveal
    }
}

public enum ElementAnimator {
    /// The element's state at timeline time `t` (seconds), or nil when it is not on screen then.
    /// `settled`: as it is once it has arrived — no fade, no arriving or leaving move, the typewriter done (an editor that is paused, 0.16.5:
    /// a text or sticker added at the playhead was drawn see-through, at the very start of its animation). Keyframes and loops still apply.
    public static func state(of o: TextOverlay, at t: Double, settled: Bool = false) -> ElementState? {
        let start = o.start.seconds, end = o.end.seconds
        guard t >= start, t < end else { return nil }
        let local = t - start
        var s = ElementState(x: o.x, y: o.y, scale: o.scale ?? 1, rotation: o.rotation ?? 0, alpha: 1, reveal: 1)

        if let ks = o.keyframes?.sorted(by: { $0.time < $1.time }), let first = ks.first, let last = ks.last {
            func take(_ k: ElementKeyframe) { s.x = k.x; s.y = k.y; s.scale = k.scale; s.rotation = k.rotation; s.alpha = k.opacity }
            if local <= first.time { take(first) }
            else if local >= last.time { take(last) }
            else if let i = ks.indices.dropLast().first(where: { local < ks[$0 + 1].time }) {
                let a = ks[i], b = ks[i + 1], u = a.easing.apply((local - a.time) / max(1e-6, b.time - a.time))
                func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
                s.x = mix(a.x, b.x); s.y = mix(a.y, b.y); s.scale = mix(a.scale, b.scale); s.rotation = mix(a.rotation, b.rotation); s.alpha = mix(a.opacity, b.opacity)
            }
        }

        if !settled {
            // The plain fade at both ends (the original "fade" setting).
            if o.fade > 0 { s.alpha *= max(0, min(1, local / o.fade, (end - t) / o.fade)) }
            if let a = o.animationIn, a.kind != .none, a.duration > 0, local < a.duration { apply(a.kind, progress: local / a.duration, leaving: false, to: &s) }
            if let a = o.animationOut, a.kind != .none, a.duration > 0, end - t < a.duration { apply(a.kind, progress: (end - t) / a.duration, leaving: true, to: &s) }
        }
        if let l = o.loop {
            let m = l.offsets(at: local)
            s.x += m.dx; s.y += m.dy; s.scale *= m.scale; s.rotation += m.rotation; s.alpha *= m.alpha
        }
        s.alpha = min(max(s.alpha, 0), 1)
        return s
    }

    /// `progress` is 0 when the element is hidden and 1 when it is fully there, for both arriving and leaving.
    static func apply(_ kind: ElementAnimationKind, progress p: Double, leaving: Bool, to s: inout ElementState) {
        let p = min(max(p, 0), 1)
        let dir = leaving ? -1.0 : 1.0
        switch kind {
        case .none: break
        case .fade: s.alpha *= p
        case .slideUp: s.y += dir * (1 - p) * 0.12; s.alpha *= min(1, p * 3)
        case .slideDown: s.y -= dir * (1 - p) * 0.12; s.alpha *= min(1, p * 3)
        case .slideLeft: s.x += dir * (1 - p) * 0.18; s.alpha *= min(1, p * 3)       // arrives from the right
        case .slideRight: s.x -= dir * (1 - p) * 0.18; s.alpha *= min(1, p * 3)
        case .pop:
            let c1 = 1.70158, c3 = c1 + 1, q = p - 1
            let overshoot = 1 + c3 * q * q * q + c1 * q * q                              // eases out past 1 and settles
            s.scale *= max(0.01, 0.4 + 0.6 * overshoot); s.alpha *= min(1, p * 4)
        case .zoom: s.scale *= 1.7 - 0.7 * p; s.alpha *= p
        case .typewriter: if leaving { s.alpha *= p } else { s.reveal = p }
        }
    }

    /// Adds or updates a keyframe near `t` (seconds from the element's start).
    public static func setting(_ keyframes: [ElementKeyframe], at t: Double, to state: ElementState) -> [ElementKeyframe] {
        var k = keyframes
        if let i = k.firstIndex(where: { abs($0.time - t) < 0.02 }) { k[i].x = state.x; k[i].y = state.y; k[i].scale = state.scale; k[i].rotation = state.rotation; k[i].opacity = state.alpha }
        else { k.append(ElementKeyframe(time: max(0, t), x: state.x, y: state.y, scale: state.scale, rotation: state.rotation, opacity: state.alpha)) }
        return k.sorted { $0.time < $1.time }
    }
}

/// Ready-made looks for text: font, colour, outline, shadow, how it arrives and leaves.
public enum TextTemplate: String, CaseIterable, Sendable {
    case classic, neon, comic, cinematic, typewriter, lowerThird, highlight, pill
    // 0.14
    case headline, subtitleBox, quote, retro, elegant, handwritten, hashtag, sale, minimal
    // 0.16.5
    case impact, marker, chalk, stickerText, gold, pastel, tech, warning, news, wedding, kids, spooky, vintage, glow, yellowCaption, inverse, serif, condensed

    /// Applies the look. The text, timing and position are kept (a template that needs a position moves the text there).
    public func apply(to o: inout TextOverlay) {
        var f = TextFlair()
        o.backgroundHex = nil; o.rotation = nil
        o.animationIn = nil; o.animationOut = nil
        switch self {
        case .classic:
            o.fontName = "Helvetica-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.08
            f.outlineHex = "#000000"; f.outlineWidth = 0.06
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.3); o.animationOut = ElementAnimation(kind: .fade, duration: 0.3)
        case .neon:
            o.fontName = "AvenirNext-Heavy"; o.colorHex = "#7DF9FF"; o.sizeFraction = 0.09
            f.outlineWidth = 0; f.shadow = true; f.shadowHex = "#00E5FF"
            o.animationIn = ElementAnimation(kind: .zoom, duration: 0.4)
        case .comic:
            o.fontName = "MarkerFelt-Wide"; o.colorHex = "#FFE600"; o.sizeFraction = 0.1
            f.outlineHex = "#000000"; f.outlineWidth = 0.12; f.shadow = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.45)
        case .cinematic:
            o.fontName = "Avenir-Light"; o.colorHex = "#F2F2F2"; o.sizeFraction = 0.05
            f.outlineWidth = 0; f.letterSpacing = 0.25; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.9); o.animationOut = ElementAnimation(kind: .fade, duration: 0.9)
        case .typewriter:
            o.fontName = "Menlo-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.055; o.backgroundHex = "#000000"
            o.animationIn = ElementAnimation(kind: .typewriter, duration: 1.2)
        case .lowerThird:
            o.fontName = "Helvetica-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.05; o.backgroundHex = "#0A84FF"
            o.alignment = .left; o.x = 0.3; o.y = 0.82
            o.animationIn = ElementAnimation(kind: .slideLeft, duration: 0.4); o.animationOut = ElementAnimation(kind: .slideRight, duration: 0.4)
        case .highlight:
            o.fontName = "Helvetica-Bold"; o.colorHex = "#111111"; o.sizeFraction = 0.065; o.backgroundHex = "#FFE600"
            f.outlineWidth = 0
            o.animationIn = ElementAnimation(kind: .slideUp, duration: 0.3)
        case .pill:
            o.fontName = "HelveticaNeue-Medium"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.045; o.backgroundHex = "#000000"
            f.outlineWidth = 0
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.25); o.animationOut = ElementAnimation(kind: .fade, duration: 0.25)
        case .headline:
            o.fontName = "HelveticaNeue-CondensedBlack"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.12
            f.outlineWidth = 0; f.shadow = true; f.shadowHex = "#000000"; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.4)
        case .subtitleBox:
            o.fontName = "HelveticaNeue-Medium"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.05; o.backgroundHex = "#000000"; o.y = 0.86
            f.outlineWidth = 0
        case .quote:
            o.fontName = "Georgia-Italic"; o.colorHex = "#FFF8E7"; o.sizeFraction = 0.065
            f.outlineWidth = 0; f.shadow = true
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.8); o.animationOut = ElementAnimation(kind: .fade, duration: 0.6)
        case .retro:
            o.fontName = "Futura-Bold"; o.colorHex = "#FF9F0A"; o.sizeFraction = 0.1
            f.outlineHex = "#3A1A00"; f.outlineWidth = 0.14; f.shadow = true; f.shadowHex = "#FF375F"; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .slideUp, duration: 0.4)
        case .elegant:
            o.fontName = "Didot"; o.colorHex = "#E8C872"; o.sizeFraction = 0.07
            f.outlineWidth = 0; f.letterSpacing = 0.18; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .fade, duration: 1); o.animationOut = ElementAnimation(kind: .fade, duration: 0.8)
        case .handwritten:
            o.fontName = "BradleyHandITCTT-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.09
            f.outlineWidth = 0; f.shadow = true
            o.animationIn = ElementAnimation(kind: .typewriter, duration: 1)
        case .hashtag:
            o.fontName = "AvenirNext-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.05; o.backgroundHex = "#5E5CE6"
            f.outlineWidth = 0
            o.animationIn = ElementAnimation(kind: .slideRight, duration: 0.35)
        case .sale:
            o.fontName = "Impact"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.1; o.backgroundHex = "#FF3B30"
            f.outlineWidth = 0; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.45)
        case .minimal:
            o.fontName = "HelveticaNeue-Light"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.05
            f.outlineWidth = 0; f.letterSpacing = 0.08
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.5); o.animationOut = ElementAnimation(kind: .fade, duration: 0.5)
        case .impact:
            o.fontName = "Impact"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.11
            f.outlineHex = "#000000"; f.outlineWidth = 0.14; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.35)
        case .marker:
            o.fontName = "MarkerFelt-Thin"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.08
            f.outlineWidth = 0; f.shadow = true
            o.animationIn = ElementAnimation(kind: .slideUp, duration: 0.35)
        case .chalk:
            o.fontName = "ChalkboardSE-Bold"; o.colorHex = "#F5F5F0"; o.sizeFraction = 0.075
            f.outlineWidth = 0; f.shadow = true; f.shadowHex = "#1C3B2B"
            o.animationIn = ElementAnimation(kind: .typewriter, duration: 1)
        case .stickerText:
            o.fontName = "AvenirNext-Heavy"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.09
            f.outlineHex = "#FF2D55"; f.outlineWidth = 0.18; f.shadow = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.4)
        case .gold:
            o.fontName = "Didot-Bold"; o.colorHex = "#FFD700"; o.sizeFraction = 0.085
            f.outlineHex = "#7A5200"; f.outlineWidth = 0.05; f.shadow = true; f.letterSpacing = 0.06; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .zoom, duration: 0.6)
        case .pastel:
            o.fontName = "AvenirNext-DemiBold"; o.colorHex = "#FFB3C7"; o.sizeFraction = 0.075
            f.outlineHex = "#FFFFFF"; f.outlineWidth = 0.08
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.5)
        case .tech:
            o.fontName = "Menlo-Bold"; o.colorHex = "#32D74B"; o.sizeFraction = 0.06
            f.outlineWidth = 0; f.shadow = true; f.shadowHex = "#32D74B"; f.uppercase = true; f.letterSpacing = 0.12
            o.animationIn = ElementAnimation(kind: .typewriter, duration: 1)
        case .warning:
            o.fontName = "Impact"; o.colorHex = "#000000"; o.sizeFraction = 0.08; o.backgroundHex = "#FFD60A"
            f.outlineWidth = 0; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.35)
        case .news:
            o.fontName = "HelveticaNeue-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.05; o.backgroundHex = "#C8102E"
            f.outlineWidth = 0; f.uppercase = true
            o.alignment = .left; o.x = 0.3; o.y = 0.84
            o.animationIn = ElementAnimation(kind: .slideLeft, duration: 0.4); o.animationOut = ElementAnimation(kind: .slideRight, duration: 0.4)
        case .wedding:
            o.fontName = "SnellRoundhand-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.1
            f.outlineWidth = 0; f.shadow = true
            o.animationIn = ElementAnimation(kind: .fade, duration: 1.2); o.animationOut = ElementAnimation(kind: .fade, duration: 1)
        case .kids:
            o.fontName = "ChalkboardSE-Bold"; o.colorHex = "#FF9F0A"; o.sizeFraction = 0.1
            f.outlineHex = "#FFFFFF"; f.outlineWidth = 0.16; f.shadow = true
            o.animationIn = ElementAnimation(kind: .pop, duration: 0.5)
        case .spooky:
            o.fontName = "Copperplate-Bold"; o.colorHex = "#FF453A"; o.sizeFraction = 0.08
            f.outlineWidth = 0; f.shadow = true; f.shadowHex = "#000000"; f.letterSpacing = 0.1; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .fade, duration: 1.2)
        case .vintage:
            o.fontName = "AmericanTypewriter-Bold"; o.colorHex = "#F4E1C1"; o.sizeFraction = 0.07
            f.outlineHex = "#3A2A1A"; f.outlineWidth = 0.06
            o.animationIn = ElementAnimation(kind: .typewriter, duration: 1.1)
        case .glow:
            o.fontName = "AvenirNext-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.08
            f.outlineWidth = 0; f.shadow = true; f.shadowHex = "#FF2D55"
            o.animationIn = ElementAnimation(kind: .zoom, duration: 0.5)
        case .yellowCaption:
            o.fontName = "HelveticaNeue-Bold"; o.colorHex = "#FFE600"; o.sizeFraction = 0.055; o.y = 0.86
            f.outlineHex = "#000000"; f.outlineWidth = 0.1
        case .inverse:
            o.fontName = "Futura-Bold"; o.colorHex = "#000000"; o.sizeFraction = 0.09
            f.outlineHex = "#FFFFFF"; f.outlineWidth = 0.16; f.uppercase = true
            o.animationIn = ElementAnimation(kind: .slideDown, duration: 0.35)
        case .serif:
            o.fontName = "Baskerville-Bold"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.075
            f.outlineWidth = 0; f.shadow = true
            o.animationIn = ElementAnimation(kind: .fade, duration: 0.7)
        case .condensed:
            o.fontName = "AvenirNextCondensed-Heavy"; o.colorHex = "#FFFFFF"; o.sizeFraction = 0.1
            f.outlineWidth = 0; f.letterSpacing = 0.04; f.uppercase = true; f.shadow = true
            o.animationIn = ElementAnimation(kind: .slideUp, duration: 0.35)
        }
        o.flair = f
    }
}
