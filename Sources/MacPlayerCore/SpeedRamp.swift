import Foundation

/// Speed that changes inside one clip (slow motion into a jump, a flash of speed). A ramp is applied by cutting the clip into short
/// parts that each play at their own steady speed, so what is on the timeline is exactly what is played and exported.
public enum SpeedRamp {
    public enum Preset: String, CaseIterable, Sendable { case montage, bullet, hero, flashIn, flashOut, jumpCut }

    /// The speed (1 = as shot) at `u` through the clip, 0...1.
    public static func speed(_ preset: Preset, at u: Double) -> Double {
        let u = min(max(u, 0), 1)
        let edge = abs(2 * u - 1)                       // 1 at the ends, 0 in the middle
        switch preset {
        case .montage: return 0.4 + 2.2 * pow(edge, 1.5)      // fast, slow in the middle, fast
        case .bullet: return 0.2 + 1.8 * edge * edge          // normal-ish, long slow-motion in the middle
        case .hero: return 2.2 - 1.8 * pow(edge, 1.5)         // slow, a burst of speed in the middle, slow
        case .flashIn: return 0.3 + 2.4 * u * u               // slow to fast
        case .flashOut: return 2.7 - 2.4 * u * u              // fast to slow
        case .jumpCut: return u < 0.5 ? 3 : 0.7               // quick first half, then a calm second half
        }
    }

    public struct Part: Equatable, Sendable {
        public var sourceLength: Double
        public var speed: Double
    }

    /// The clip's source length cut into `count` equal parts, each at the speed of the curve at its middle.
    public static func parts(_ preset: Preset, sourceLength: Double, count: Int = 10) -> [Part] {
        let n = max(2, count)
        return (0..<n).map { i in Part(sourceLength: sourceLength / Double(n), speed: speed(preset, at: (Double(i) + 0.5) / Double(n))) }
    }

    /// How long the ramped clip plays on the timeline.
    public static func playedLength(_ parts: [Part]) -> Double { parts.reduce(0) { $0 + $1.sourceLength / max(VideoLook.minimumSpeed, $1.speed) } }
}

extension TimelineEditor {
    /// Replaces a clip with parts that play at the speeds of `preset` (multiplied into the clip's own speed). Returns the new clips' ids,
    /// or nil when the clip is too short to cut (each part needs a few frames).
    @discardableResult
    public static func applySpeedRamp(_ clips: inout [TimelineClip], clipID: UUID, preset: SpeedRamp.Preset, parts count: Int = 10) -> [UUID]? {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        let c = clips[i]
        let length = (c.sourceEnd - c.sourceStart).seconds
        guard length / Double(count) >= 0.15 else { return nil }
        let parts = SpeedRamp.parts(preset, sourceLength: length, count: count)
        var out: [TimelineClip] = []
        var t = c.sourceStart
        for (k, part) in parts.enumerated() {
            var piece = c
            piece.id = k == 0 ? c.id : UUID()
            piece.sourceStart = t
            t = k == parts.count - 1 ? c.sourceEnd : t + MediaTime(seconds: part.sourceLength, timescale: 6000)
            piece.sourceEnd = t
            piece.look.speed = min(max(c.look.speed * part.speed, 0.1), 8)
            piece.look.motion = Motion.shifted(c.look.motion, by: -((piece.sourceStart - c.sourceStart).seconds / max(VideoLook.minimumSpeed, c.look.speed)) )
            piece.look.transitionIn = k == 0 ? c.look.transitionIn : nil
            if !c.name.isEmpty { piece.name = "\(c.name) \(k + 1)" }
            out.append(piece)
        }
        clips.replaceSubrange(i...i, with: out)
        return out.map(\.id)
    }

    /// Holds one frame of the clip for `hold` seconds. The clip is cut at `t`; the held frame goes between the two halves (or before/after
    /// the clip when `t` is at an edge). The held part is the frame itself played extremely slowly, without sound.
    @discardableResult
    public static func freezeFrame(_ clips: inout [TimelineClip], clipID: UUID, atSourceTime t: MediaTime, frameDuration: MediaTime, hold: Double) -> UUID? {
        guard let i = clips.firstIndex(where: { $0.id == clipID }), hold > 0.05 else { return nil }
        let c = clips[i]
        guard t >= c.sourceStart, t < c.sourceEnd else { return nil }
        let fd = min(frameDuration, c.sourceEnd - t)
        var frozen = c
        frozen.id = UUID()
        frozen.sourceStart = t; frozen.sourceEnd = t + fd
        frozen.look.speed = max(VideoLook.minimumSpeed, fd.seconds / hold)
        frozen.look.motion = []
        frozen.look.transitionIn = nil
        frozen.audio.muted = true
        frozen.name = c.name.isEmpty ? "" : c.name + " ❄"
        var before = c, after = c
        before.sourceEnd = t
        after.sourceStart = t
        after.look.transitionIn = nil
        after.look.motion = Motion.shifted(c.look.motion, by: -((t - c.sourceStart).seconds / max(VideoLook.minimumSpeed, c.look.speed)))
        var out: [TimelineClip] = []
        if t > c.sourceStart {
            after.id = UUID()
            out = [before, frozen, after]
        } else {
            // At the clip's first frame the held frame goes in front, and the clip keeps its id (and its transition goes to the front).
            frozen.look.transitionIn = c.look.transitionIn
            out = [frozen, after]
        }
        clips.replaceSubrange(i...i, with: out)
        return frozen.id
    }
}
