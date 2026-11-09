import Foundation

/// What can be done to the colour of a sound: bass, middle and treble, a higher or lower voice, a room around it, an echo. Done once, on a copy of
/// the sound (the original file is never changed), and then used by the preview and the export alike.
public struct SoundFX: Codable, Equatable, Hashable, Sendable {
    /// Gains in decibels, -12...12.
    public var bass = 0.0
    public var mid = 0.0
    public var treble = 0.0
    /// Semitones, -12...12 (negative = lower, deeper). The length of the sound does not change.
    public var pitch = 0.0
    /// 0...1: how much of a large room is added.
    public var reverb = 0.0
    /// 0...1: how loud the repeats are.
    public var echo = 0.0
    public init() {}

    public var isNeutral: Bool { self == SoundFX() }

    public func clamped() -> SoundFX {
        var f = self
        func db(_ x: Double) -> Double { min(max(x, -12), 12) }
        func unit(_ x: Double) -> Double { min(max(x, 0), 1) }
        f.bass = db(bass); f.mid = db(mid); f.treble = db(treble)
        f.pitch = min(max(pitch, -12), 12)
        f.reverb = unit(reverb); f.echo = unit(echo)
        return f
    }

    /// Ready-made looks for a voice or a sound: one tap.
    public enum Preset: String, CaseIterable, Sendable {
        case clearVoice, warm, deep, high, chipmunk, telephone, hall, echo

        public var fx: SoundFX {
            var f = SoundFX()
            switch self {
            case .clearVoice: f.bass = -3; f.mid = 3; f.treble = 3
            case .warm: f.bass = 4; f.treble = -2
            case .deep: f.pitch = -5; f.bass = 4
            case .high: f.pitch = 4; f.treble = 2
            case .chipmunk: f.pitch = 9
            case .telephone: f.bass = -12; f.mid = 6; f.treble = -12
            case .hall: f.reverb = 0.6
            case .echo: f.echo = 0.6; f.reverb = 0.1
            }
            return f
        }
    }

    /// The preset these values are exactly, if any.
    public var preset: Preset? { Preset.allCases.first { $0.fx == self } }

    /// A short text that stands for these values (for naming a cached copy).
    public var cacheKey: String {
        let c = clamped()
        return String(format: "b%.1f m%.1f t%.1f p%.1f r%.2f e%.2f", c.bass, c.mid, c.treble, c.pitch, c.reverb, c.echo)
    }
}
