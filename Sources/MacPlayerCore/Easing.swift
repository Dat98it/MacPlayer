import Foundation

/// How a value changes between two keyframes: in a straight line, or starting slowly, ending slowly, overshooting a little, bouncing.
/// A keyframe's easing shapes the stretch that leaves it, towards the next keyframe.
public enum Easing: String, Codable, CaseIterable, Sendable {
    case linear, easeIn, easeOut, easeInOut, overshoot, bounce

    /// Maps progress 0...1 to the share of the change that has happened (0 and 1 map to 0 and 1).
    public func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: let u = 1 - x; return 1 - u * u * u
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .overshoot:
            let c1 = 1.70158, c3 = c1 + 1, q = x - 1
            return 1 + c3 * q * q * q + c1 * q * q
        case .bounce:
            let n1 = 7.5625, d1 = 2.75
            if x < 1 / d1 { return n1 * x * x }
            if x < 2 / d1 { let y = x - 1.5 / d1; return n1 * y * y + 0.75 }
            if x < 2.5 / d1 { let y = x - 2.25 / d1; return n1 * y * y + 0.9375 }
            let y = x - 2.625 / d1; return n1 * y * y + 0.984375
        }
    }
}
