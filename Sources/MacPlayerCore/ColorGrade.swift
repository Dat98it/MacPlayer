import Foundation

// The colour-grading settings (curves, colour wheels, per-colour HSL, a LUT) that sit next to the basic sliders in `ColorAdjust`.
// Everything here is plain values: how they are turned into pixels is in `ColorGrading`, and the renderer in the media module draws it.

public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Tone curves: one for brightness as a whole and one for each of red, green and blue. An empty list is a straight line (no change).
/// The ends (0,0) and (1,1) are always there; a list holds only the points a person added or moved.
public struct ColorCurves: Codable, Equatable, Hashable, Sendable {
    public enum Channel: String, CaseIterable, Codable, Sendable { case master, red, green, blue }
    public var master: [CurvePoint] = []
    public var red: [CurvePoint] = []
    public var green: [CurvePoint] = []
    public var blue: [CurvePoint] = []
    public init() {}

    public var isNeutral: Bool { master.isEmpty && red.isEmpty && green.isEmpty && blue.isEmpty }

    public func points(_ channel: Channel) -> [CurvePoint] {
        switch channel { case .master: return master; case .red: return red; case .green: return green; case .blue: return blue }
    }

    public mutating func setPoints(_ points: [CurvePoint], for channel: Channel) {
        let clean = CurveMath.cleaned(points)
        switch channel { case .master: master = clean; case .red: red = clean; case .green: green = clean; case .blue: blue = clean }
    }
}

public enum CurveMath {
    /// Points inside 0...1, from left to right, with points nearer than 0.015 across merged (the later one wins) and a point that lies on
    /// the straight line dropped when it is the only one.
    public static func cleaned(_ points: [CurvePoint]) -> [CurvePoint] {
        let sorted = points.map { CurvePoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for p in sorted {
            if let last = out.last, p.x - last.x < 0.015 { out[out.count - 1] = p } else { out.append(p) }
        }
        if out.count == 1, abs(out[0].x - out[0].y) < 1e-6 { return [] }
        return out
    }

    /// The nodes the curve runs through: the points, with (0,0) and (1,1) added where no point sits at the ends.
    static func nodes(_ points: [CurvePoint]) -> [CurvePoint] {
        var n = cleaned(points)
        if n.first.map({ $0.x > 1e-9 }) ?? true { n.insert(CurvePoint(x: 0, y: 0), at: 0) }
        if n.last.map({ $0.x < 1 - 1e-9 }) ?? true { n.append(CurvePoint(x: 1, y: 1)) }
        return n
    }

    /// The curve's height at `x`: a smooth curve through the nodes that never overshoots between two of them (so a curve never goes
    /// backwards and makes a strange band in the picture).
    public static func value(_ points: [CurvePoint], at x: Double) -> Double {
        if points.isEmpty { return min(max(x, 0), 1) }
        let n = nodes(points)
        return value(nodes: n, tangents: tangents(n), at: x)
    }

    /// 256 (or `size`) heights, for fast lookups.
    public static func table(_ points: [CurvePoint], size: Int = 256) -> [Double] {
        guard size > 1 else { return [0] }
        if points.isEmpty { return (0..<size).map { Double($0) / Double(size - 1) } }
        let n = nodes(points)
        let t = tangents(n)
        return (0..<size).map { value(nodes: n, tangents: t, at: Double($0) / Double(size - 1)) }
    }

    /// Slopes at the nodes for a monotone cubic (Fritsch–Carlson).
    static func tangents(_ n: [CurvePoint]) -> [Double] {
        let count = n.count
        guard count > 1 else { return [0] }
        var d = [Double](repeating: 0, count: count - 1)
        for i in 0..<(count - 1) { d[i] = (n[i + 1].y - n[i].y) / max(n[i + 1].x - n[i].x, 1e-9) }
        var m = [Double](repeating: 0, count: count)
        m[0] = d[0]; m[count - 1] = d[count - 2]
        if count > 2 { for i in 1..<(count - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(count - 1) {
            if abs(d[i]) < 1e-12 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let k = 3 / s.squareRoot(); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
        }
        return m
    }

    static func value(nodes n: [CurvePoint], tangents m: [Double], at x: Double) -> Double {
        let x = min(max(x, 0), 1)
        var i = 0
        while i < n.count - 2, x > n[i + 1].x { i += 1 }
        let h = max(n[i + 1].x - n[i].x, 1e-9), t = (x - n[i].x) / h, t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * n[i].y + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * n[i + 1].y + (t3 - t2) * h * m[i + 1]
        return min(max(y, 0), 1)
    }
}

/// One colour wheel: a tint pushed into one part of the picture (the dark parts, the middle, the light parts). The puck's place says
/// which colour and how much: its direction is the colour, its distance from the middle is the strength.
public struct ColorWheel: Codable, Equatable, Hashable, Sendable {
    public var x = 0.0
    public var y = 0.0
    /// Makes this part lighter (+) or darker (−): -1...1.
    public var luma = 0.0
    public init(x: Double = 0, y: Double = 0, luma: Double = 0) { self.x = x; self.y = y; self.luma = luma }

    public var isNeutral: Bool { abs(x) < 1e-6 && abs(y) < 1e-6 && abs(luma) < 1e-6 }

    /// The puck kept inside the circle.
    public func clamped() -> ColorWheel {
        var w = self
        let len = (x * x + y * y).squareRoot()
        if len > 1 { w.x = x / len; w.y = y / len }
        w.luma = min(max(luma, -1), 1)
        return w
    }

    /// The colour direction, 0...1 around the wheel (0 = red, going through yellow, green, cyan, blue, magenta), and the strength 0...1.
    public var hue: Double { let a = atan2(-y, x) / (2 * Double.pi); return a < 0 ? a + 1 : a }
    public var amount: Double { min((x * x + y * y).squareRoot(), 1) }
}

public struct ColorWheels: Codable, Equatable, Hashable, Sendable {
    public var shadows = ColorWheel()
    public var midtones = ColorWheel()
    public var highlights = ColorWheel()
    public init() {}
    public var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }
}

/// The eight colour ranges of the HSL tool, with the hue each is centred on.
public enum HSLBand: Int, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    public var centerDegrees: Double { [0, 30, 60, 120, 180, 225, 275, 320][rawValue] }
    /// A colour that stands for the range, for the picker's swatch (hex).
    public var swatchHex: String { ["#E0382F", "#F08A24", "#F2D024", "#3DB84A", "#2CC5C9", "#2F6BDE", "#8A4FD6", "#D64FAE"][rawValue] }
}

public struct HSLAdjust: Codable, Equatable, Hashable, Sendable {
    /// All -1...1 (0 = unchanged): hue moves the colour toward its neighbours (up to 30°), saturation and luminance make it stronger/weaker, lighter/darker.
    public var hue = 0.0
    public var saturation = 0.0
    public var luminance = 0.0
    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) { self.hue = hue; self.saturation = saturation; self.luminance = luminance }
    public var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

public struct ColorHSL: Codable, Equatable, Hashable, Sendable {
    public var bands: [HSLAdjust] = Array(repeating: HSLAdjust(), count: HSLBand.allCases.count)
    public init() {}
    public var isNeutral: Bool { bands.allSatisfy(\.isNeutral) }
    public subscript(band: HSLBand) -> HSLAdjust {
        get { band.rawValue < bands.count ? bands[band.rawValue] : HSLAdjust() }
        set { while bands.count < HSLBand.allCases.count { bands.append(HSLAdjust()) }; bands[band.rawValue] = newValue }
    }
}

/// A colour look file (`.cube`) laid over the picture. Only the place of the file and the name are kept in the project.
public struct LutRef: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var path: String
    /// How much of the look shows: 0...1.
    public var strength: Double
    public init(name: String, path: String, strength: Double = 1) { self.name = name; self.path = path; self.strength = strength }
}
