import Foundation

/// A motion that keeps going while a text, shape, sticker or picture layer is on screen (0.16.5): it beats, bounces, floats, swings,
/// spins, shakes or blinks. It comes on top of how the thing arrives and leaves, and of its keyframes.
public enum ElementLoopKind: String, Codable, CaseIterable, Sendable {
    case pulse, heartbeat, breathe, bounce, float, sway, swing, wobble, spin, shake, blink, flash, tada
}

public struct ElementLoop: Codable, Equatable, Sendable {
    public var kind: ElementLoopKind
    /// Seconds for one round of the motion.
    public var period: Double
    /// How strong it is: 1 = the usual amount, 0.3 = gentle, 2 = strong.
    public var strength: Double
    public init(kind: ElementLoopKind, period: Double? = nil, strength: Double = 1) {
        self.kind = kind; self.period = period ?? kind.defaultPeriod; self.strength = strength
    }

    /// Values kept in a range where the motion stays visible and never wild.
    public var clamped: ElementLoop { ElementLoop(kind: kind, period: min(max(period, 0.15), 10), strength: min(max(strength, 0.1), 3)) }

    /// How the motion changes a thing's place (fractions of the picture), size, turn (degrees) and opacity, `local` seconds after it appeared.
    public func offsets(at local: Double) -> (dx: Double, dy: Double, scale: Double, rotation: Double, alpha: Double) {
        let l = clamped, P = l.period, k = l.strength, u = max(0, local)
        let f = (u / P).truncatingRemainder(dividingBy: 1)          // 0..<1 within the current round
        let w = 2 * Double.pi * u / P
        switch l.kind {
        case .pulse: return (0, 0, 1 + 0.08 * k * sin(w), 0, 1)
        case .heartbeat:
            func bump(_ c: Double) -> Double { exp(-pow((f - c) / 0.05, 2)) }
            return (0, 0, 1 + 0.14 * k * (bump(0.12) + 0.65 * bump(0.32)), 0, 1)
        case .breathe: return (0, 0, 1 + 0.05 * k * sin(w), 0, 1 - min(0.6, 0.15 * k) * (0.5 - 0.5 * cos(w)))
        case .bounce: return (0, -0.045 * k * abs(sin(Double.pi * u / P)), 1, 0, 1)
        case .float: return (0, 0.018 * k * sin(w), 1, 0, 1)
        case .sway: return (0.025 * k * sin(w), 0, 1, 0, 1)
        case .swing: return (0, 0, 1, 10 * k * sin(w), 1)
        case .wobble: return (0, 0, 1, 5 * k * sin(4 * w), 1)
        case .spin: return (0, 0, 1, 360 * f, 1)
        case .shake: return (0.008 * k * sin(10 * w), 0, 1, 0, 1)
        case .blink: return (0, 0, 1, 0, 1 - min(0.9, 0.8 * k) * (0.5 - 0.5 * cos(w)))
        case .flash: return (0, 0, 1, 0, f < 0.5 ? 1 : max(0.05, 1 - 0.9 * min(1, k)))
        case .tada:
            // A short burst once a round: a little bigger, wiggling, then still.
            guard f < 0.45 else { return (0, 0, 1, 0, 1) }
            let g = f / 0.45, env = sin(Double.pi * g)
            return (0, 0, 1 + 0.1 * k * env, 6 * k * env * sin(6 * Double.pi * g), 1)
        }
    }

    public var defaultPeriod: Double { kind.defaultPeriod }
}

public extension ElementLoopKind {
    /// Seconds for one round, by default.
    var defaultPeriod: Double {
        switch self {
        case .pulse, .breathe, .float, .sway: return 1.6
        case .heartbeat: return 1.1
        case .bounce: return 0.8
        case .swing: return 1.4
        case .wobble, .shake: return 1.0
        case .spin: return 2.5
        case .blink: return 1.2
        case .flash: return 0.6
        case .tada: return 2.0
        }
    }
}
