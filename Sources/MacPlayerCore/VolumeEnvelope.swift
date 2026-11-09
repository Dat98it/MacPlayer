import Foundation

/// How loud a sound clip is over time: its own gain, fade in, fade out and the dips that make room for speech ("ducking").
public enum VolumeEnvelope {
    public struct Point: Equatable, Sendable { public var time: Double; public var gain: Double }

    /// Speech stretches (timeline seconds) merged when the gaps between them are too short for the music to come back up and go down again.
    public static func merged(_ ranges: [(start: Double, end: Double)], gap: Double) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) where r.end > r.start {
            if let last = out.last, r.start - last.end <= gap { out[out.count - 1].end = max(last.end, r.end) } else { out.append(r) }
        }
        return out
    }

    /// Breakpoints of the gain (linear, 1 = unchanged) between which it moves in straight lines.
    /// - Parameters:
    ///   - start/end: where the clip is on the timeline, seconds.
    ///   - speech: stretches of speech on the timeline; the clip goes down to `duckGain` over `attack` before each and back up over `release` after.
    public static func points(start: Double, end: Double, gain: Double, fadeIn: Double, fadeOut: Double,
                              speech: [(start: Double, end: Double)] = [], duckGain: Double = 1, attack: Double = 0.25, release: Double = 0.6) -> [Point] {
        guard end > start else { return [] }
        let length = end - start
        let fi = min(max(0, fadeIn), length / 2), fo = min(max(0, fadeOut), length / 2)
        // Two straight-line shapes: the fades, and the ducking dips. Their product is the gain.
        var fade: [(Double, Double)] = [(start, fi > 0 ? 0 : 1), (start + fi, 1), (end - fo, 1), (end, fo > 0 ? 0 : 1)]
        var duck: [(Double, Double)] = [(start, 1)]
        if duckGain < 1 {
            for r in merged(speech, gap: attack + release) where r.end > start && r.start < end {
                let a = max(start, r.start), b = min(end, r.end)
                let down = max(start, a - attack), up = min(end, b + release)
                duck.append((down, 1)); duck.append((a, duckGain)); duck.append((b, duckGain)); duck.append((up, 1))
            }
        }
        duck.append((end, 1))
        fade = fade.sorted { $0.0 < $1.0 }; duck = duck.sorted { $0.0 < $1.0 }
        func value(_ line: [(Double, Double)], _ t: Double) -> Double {
            guard let first = line.first, let last = line.last else { return 1 }
            if t <= first.0 { return first.1 }; if t >= last.0 { return last.1 }
            for i in 1..<line.count where t <= line[i].0 {
                let (t0, v0) = line[i - 1], (t1, v1) = line[i]
                return t1 > t0 ? v0 + (v1 - v0) * (t - t0) / (t1 - t0) : v1
            }
            return last.1
        }
        var times = Set<Double>()
        for p in fade { times.insert(p.0) }; for p in duck { times.insert(p.0) }
        var out: [Point] = []
        for t in times.sorted() {
            if let last = out.last, t - last.time < 0.001 { continue }
            out.append(Point(time: t, gain: gain * value(fade, t) * value(duck, t)))
        }
        return out
    }

    /// The gain at a moment, for checking and for the preview.
    public static func gain(at t: Double, in points: [Point]) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if t <= first.time { return first.gain }; if t >= last.time { return last.gain }
        for i in 1..<points.count where t <= points[i].time {
            let a = points[i - 1], b = points[i]
            return b.time > a.time ? a.gain + (b.gain - a.gain) * (t - a.time) / (b.time - a.time) : b.gain
        }
        return last.gain
    }
}
