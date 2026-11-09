import Foundation

/// The shapes a mask can have. The mask keeps what is inside the shape and hides the rest (or the other way round with `invert`).
public enum MaskShape: String, Codable, CaseIterable, Sendable {
    case ellipse, rectangle, roundedRectangle, heart, star, split
}

/// A mask over a picture: a shape with a place, a size, a turn and a soft edge. Positions and sizes are fractions of the picture the mask is
/// on (the whole frame for the main picture, the layer's own picture for a layer), so it survives a change of output size.
public struct MaskSpec: Codable, Equatable, Hashable, Sendable {
    public var shape: MaskShape = .ellipse
    /// Centre, 0...1 from the top-left.
    public var centerX = 0.5
    public var centerY = 0.5
    /// Width and height as a fraction of the picture (the shape is stretched to them).
    public var width = 0.6
    public var height = 0.6
    /// Degrees, clockwise.
    public var rotation = 0.0
    /// How soft the edge is: 0 = sharp, 1 = very soft.
    public var feather = 0.1
    /// Hides what is inside and keeps what is outside.
    public var invert = false
    public init(shape: MaskShape = .ellipse) { self.shape = shape }

    public func clamped() -> MaskSpec {
        var m = self
        m.centerX = min(max(centerX, -0.5), 1.5); m.centerY = min(max(centerY, -0.5), 1.5)
        m.width = min(max(width, 0.05), 3); m.height = min(max(height, 0.05), 3)
        m.rotation = rotation.truncatingRemainder(dividingBy: 360)
        m.feather = min(max(feather, 0), 1)
        return m
    }
}

/// How a layer's colours mix with what is under it.
public enum LayerBlend: String, Codable, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten, difference, add
    /// The Core Image filter that does it (nil for a plain layer).
    public var filterName: String? {
        switch self {
        case .normal: return nil
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"
        case .darken: return "CIDarkenBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .add: return "CIAdditionCompositing"
        }
    }
}

public enum MaskGeometry {
    /// Whether the point (px, py), both 0...1 over the picture, is inside the shape of `m` (before any soft edge or inversion).
    /// `aspect` is the picture's width / height: a turned or stretched shape has to be worked out in pixel-like units, not fractions.
    public static func contains(_ m: MaskSpec, x px: Double, y py: Double, aspect: Double) -> Bool {
        let a = max(aspect, 0.01)
        // To a frame where one unit is the picture's height, centred on the shape.
        var dx = (px - m.centerX) * a, dy = py - m.centerY
        let r = -m.rotation * Double.pi / 180
        (dx, dy) = (dx * cos(r) - dy * sin(r), dx * sin(r) + dy * cos(r))
        let hw = max(m.width * a / 2, 1e-6), hh = max(m.height / 2, 1e-6)
        let u = dx / hw, v = dy / hh                    // -1...1 across the shape
        switch m.shape {
        case .rectangle: return abs(u) <= 1 && abs(v) <= 1
        case .roundedRectangle:
            let k = 0.35                                // corner radius as a part of the half-size
            let qx = abs(u) - (1 - k), qy = abs(v) - (1 - k)
            if qx <= 0 || qy <= 0 { return abs(u) <= 1 && abs(v) <= 1 }
            return qx * qx + qy * qy <= k * k
        case .ellipse: return u * u + v * v <= 1
        case .heart:
            // The classic heart curve, scaled to fit the box: (x² + y² − 1)³ − x²y³ ≤ 0 with x, y in about -1.3...1.3.
            let x = u * 1.2, y = -v * 1.2 + 0.1
            let t = x * x + y * y - 1
            return t * t * t - x * x * y * y * y <= 0
        case .star:
            let rr = (u * u + v * v).squareRoot()
            if rr > 1 { return false }
            let ang = atan2(u, -v)                      // 0 at the top, clockwise
            let sector = 2 * Double.pi / 5, local = abs((ang + 2 * Double.pi).truncatingRemainder(dividingBy: sector) - sector / 2)
            // The outline goes between the outer point (radius 1) and the inner corner (radius 0.42).
            let t = local / (sector / 2)                // 0 at a point, 1 at an inner corner
            let edge = 1 - (1 - 0.42) * t
            return rr <= edge
        case .split: return u <= 0                       // the left half (turn it for another side)
        }
    }
}
