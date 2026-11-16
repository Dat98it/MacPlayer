import Foundation

// MARK: Beats of a song, and cutting to them (0.20)

/// The beats found in a sound file: the tempo and when each beat falls, in seconds from the start of the file.
public struct BeatGrid: Codable, Equatable, Sendable {
    public var bpm: Double
    public var times: [Double]
    public init(bpm: Double, times: [Double]) { self.bpm = bpm; self.times = times }
}

extension SoundClip {
    /// The beats of the part that plays, where they fall on the timeline.
    public var timelineBeats: [MediaTime] {
        guard let g = beats else { return [] }
        let a = sourceStart.seconds, b = a + duration.seconds
        return g.times.filter { $0 >= a - 0.0005 && $0 <= b + 0.0005 }.map { start + MediaTime(seconds: $0 - a, timescale: 6000) }
    }
}

/// Finds the beat in a song's onset strength (how much new sound starts in each short frame): the tempo from how the strength repeats,
/// then the beats as the chain of strong frames that keeps closest to that tempo (dynamic programming, as in Ellis 2007).
/// Pure arithmetic, so it is tested without any sound file.
public enum BeatTracker {
    /// For measuring: how strong the halfway points were against the beats in the last run.
    nonisolated(unsafe) public static var lastHalfwayRatio = 0.0
    /// `onset`: one value per frame, `hop` seconds apart. Nil when there is no steady beat to find (silence, speech, too short).
    public static func track(onset raw: [Float], hop: Double, minBPM: Double = 70, maxBPM: Double = 180) -> BeatGrid? {
        let n = raw.count
        guard n > Int(4 / hop), hop > 0 else { return nil }
        // Normalised so the strength of a loud song and a quiet one count the same.
        let mean = raw.reduce(0, +) / Float(n)
        var sd: Float = 0
        for v in raw { sd += (v - mean) * (v - mean) }
        sd = (sd / Float(n)).squareRoot()
        guard sd > 1e-6 else { return nil }
        let onset = raw.map { Double(($0 - mean) / sd) }

        // Tempo: the lag at which the strength best matches itself, preferring lags near 120 per minute (people tap around there).
        let minLag = max(2, Int((60 / maxBPM / hop).rounded(.down))), maxLag = min(n / 2, Int((60 / minBPM / hop).rounded(.up)))
        guard maxLag > minLag else { return nil }
        var best = (lag: 0, score: -Double.infinity)
        var scores: [Int: Double] = [:]
        for lag in minLag...maxLag {
            var s = 0.0
            for i in lag..<n { s += onset[i] * onset[i - lag] }
            s /= Double(n - lag)
            scores[lag] = s
            let bpm = 60 / (Double(lag) * hop)
            let weight = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            if s * weight > best.score { best = (lag, s * weight) }
        }
        // A tempo with no repeating pattern behind it is not a beat.
        guard best.lag > 0, let raw0 = scores[best.lag], raw0 > 0.05 else { return nil }
        // Finer than one frame: the peak of a parabola through the scores around the best lag.
        var period = Double(best.lag)
        if let a = scores[best.lag - 1], let c = scores[best.lag + 1] {
            let d = a - 2 * raw0 + c
            if d < 0 { period += min(max(0.5 * (a - c) / d, -0.5), 0.5) }
        }

        // A remix often has its kick on every other beat: when the beat in between is nearly as strong, the tempo is twice as fast
        // (a real 140 bpm song was found at 70, 0.20.1).
        if 60 / (period / 2 * hop) <= maxBPM, let sh = scores[Int((period / 2).rounded())], sh > 0.5 * raw0 { period /= 2 }

        // The tempo may change during the song: the period is looked for again in windows of 12 s, near the overall one, and changes
        // smoothly from window to window.
        let win = Int(12 / hop), stepW = Int(6 / hop)
        var centres: [(Int, Double)] = []
        if n > win + stepW {
            var a = 0
            while a + win <= n {
                var bestL = (period, -Double.infinity)
                let l0 = max(2, Int(period * 0.7)), l1 = min(win / 2, Int(period * 1.45) + 1)
                if l1 > l0 {
                    for lag in l0...l1 {
                        var s = 0.0
                        for i in (a + lag)..<(a + win) { s += onset[i] * onset[i - lag] }
                        s *= exp(-0.5 * pow(log2(Double(lag) / period) / 0.15, 2))
                        if s > bestL.1 { bestL = (Double(lag), s) }
                    }
                }
                centres.append((a + win / 2, bestL.0))
                a += stepW
            }
        }
        func periodAt(_ i: Int) -> Double {
            guard let first = centres.first, let last = centres.last else { return period }
            if i <= first.0 { return first.1 }
            if i >= last.0 { return last.1 }
            let k = centres.firstIndex { $0.0 >= i }!
            let (x0, y0) = centres[k - 1], (x1, y1) = centres[k]
            return y0 + (y1 - y0) * Double(i - x0) / Double(x1 - x0)
        }

        // Beats: each frame's best score is its strength plus the best earlier beat about one period back, minus how far that gap is from
        // the period there.
        let tightness = 100.0
        var score = [Double](repeating: 0, count: n), back = [Int](repeating: -1, count: n)
        for i in 0..<n {
            let p = periodAt(i)
            let lo = Int((p * 0.5).rounded()), hi = Int((p * 2).rounded())
            var bestPrev = 0.0, from = -1
            if i - lo >= 0 {
                for j in max(0, i - hi)...(i - lo) {
                    let gap = Double(i - j) / p
                    let v = score[j] - tightness * pow(log(gap), 2)
                    if from < 0 || v > bestPrev { bestPrev = v; from = j }
                }
            }
            score[i] = onset[i] + (from >= 0 ? max(0, bestPrev) : 0)
            back[i] = from >= 0 && bestPrev > 0 ? from : -1
        }
        // End on the strongest frame in the last period, then follow the chain back.
        let tail = max(0, n - Int(period.rounded()) - 1)
        var i = (tail..<n).max { score[$0] < score[$1] } ?? n - 1
        var frames: [Int] = []
        while i >= 0 { frames.append(i); i = back[i] }
        frames.reverse()
        guard frames.count >= 4 else { return nil }
        // Still half the tempo when what sounds halfway between the beats is about as strong as the beats (a real remix at 140 bpm was
        // found at 70 with nearly every halfway point on a hit, 0.20.1): the halfway points are beats too.
        func peak(_ c: Int) -> Float { raw[max(0, c - 2)...min(n - 1, c + 2)].max() ?? 0 }
        let onBeats = frames.map(peak).reduce(0, +) / Float(frames.count)
        let halfway = zip(frames, frames.dropFirst()).map { ($0 + $1) / 2 }
        let between = halfway.map(peak).reduce(0, +) / Float(max(1, halfway.count))
        lastHalfwayRatio = Double(between / max(onBeats, 1e-6))
        if 60 / (periodAt(frames[0]) / 2 * hop) <= maxBPM, between >= onBeats * 0.6 {
            frames = zip(frames, halfway + [-1]).flatMap { $1 >= 0 ? [$0, $1] : [$0] }
        }
        // Beats missing at the start (a quiet intro) are filled in at the tempo, so the grid covers the whole song.
        var times = frames.map { Double($0) * hop }
        let step = Double(frames.count > 1 ? frames[1] - frames[0] : Int(periodAt(frames[0]))) * hop
        while let f = times.first, f - step >= -step * 0.1 { times.insert(max(0, f - step), at: 0) }
        // The tempo shown: the average gap between the beats found (beats fall on whole frames, so one gap alone is rough).
        let bpm = 60 / (frames.count > 1 ? Double(frames.last! - frames.first!) * hop / Double(frames.count - 1) : step)
        return BeatGrid(bpm: (bpm * 10).rounded() / 10, times: times)
    }
}

public enum BeatSync {
    /// Every `every`-th beat of every sound that has beats (or of one sound), on the timeline, in order.
    /// `every` 0: every half beat (the beats and the points halfway between: a half-time song, 0.20.1).
    public static func timelineBeats(_ p: Project, sound: UUID? = nil, every: Int = 1) -> [MediaTime] {
        let k = max(1, every)
        let sounds = p.soundClips.filter { $0.beats != nil && (sound == nil || $0.id == sound) }
        if every == 0 {
            return sounds.flatMap { s -> [MediaTime] in
                let b = s.timelineBeats
                return b + zip(b, b.dropFirst()).map { MediaTime(seconds: ($0.seconds + $1.seconds) / 2, timescale: 6000) }
            }.sorted()
        }
        return sounds.flatMap { s in s.timelineBeats.enumerated().filter { $0.offset % k == 0 }.map(\.element) }.sorted()
    }

    /// Shortest clip a fit leaves.
    public static let minClip = 0.3

    /// Moves the end of each clip on the main track (and so the cut after it) onto the nearest beat of `beats`. A clip is made shorter, or
    /// longer when its source has more (`sourceLimit`; a photo has a minute), never shorter than `minClip`. With `ripple`, what lies over the
    /// timeline follows (TimelineRipple), except the length of sound `keep` (the song the beats come from, which must go on playing).
    /// Returns how many cuts moved.
    @discardableResult
    public static func fitClips(_ p: inout Project, beats: [MediaTime], sourceLimit: (TimelineClip) -> MediaTime?, ripple: Bool, keep: UUID? = nil, clips only: Set<UUID>? = nil) -> Int {
        guard !beats.isEmpty else { return 0 }
        let kept = p.soundClips.first { $0.id == keep }
        // A cut only moves to a beat near it (within one step of the beats used): a cut far from the song (an hour-long clip under a
        // two-minute song) is left alone instead of being dragged to the song's last beat (found on a real project, 0.20).
        let gaps = zip(beats.dropFirst(), beats).map { ($0 - $1).seconds }.sorted()
        let reach = gaps.isEmpty ? 0.5 : gaps[gaps.count / 2] + 0.001
        var moved = 0
        for id in p.timeline.map(\.id) {
            if let only, !only.contains(id) { continue }
            guard let c = p.timeline.first(where: { $0.id == id }), let t = TimelineEditor.starts(p.timeline)[id] else { continue }
            let k = max(VideoLook.minimumSpeed, c.look.speed)
            let limit = sourceLimit(c)
            let maxLength = limit.map { ($0 - c.sourceStart).seconds / k } ?? c.duration.seconds
            let end = (t + c.duration).seconds
            let candidates = beats.map(\.seconds).filter { $0 - t.seconds >= minClip && $0 - t.seconds <= maxLength + 0.0005 }
            guard let g = candidates.min(by: { abs($0 - end) < abs($1 - end) }), abs(g - end) > 0.0005, abs(g - end) <= reach else { continue }
            let before = p.timeline
            let newEnd = c.sourceStart + MediaTime(seconds: (g - t.seconds) * k, timescale: 6000)
            TimelineEditor.trim(&p.timeline, clipID: id, end: newEnd, sourceDuration: max(limit ?? c.sourceEnd, newEnd))
            if ripple { TimelineRipple.followTrim(of: id, leftEdge: false, before: before, in: &p) }
            moved += 1
        }
        if let kept, let i = p.soundClips.firstIndex(where: { $0.id == kept.id }) { p.soundClips[i].duration = kept.duration; p.soundClips[i].start = kept.start }
        return moved
    }

    /// Markers at every `every`-th beat (those already there are not added twice). Returns how many were added.
    @discardableResult
    public static func addMarkers(_ p: inout Project, beats: [MediaTime], end: MediaTime) -> Int {
        var added = 0
        for b in beats where b <= end && !p.markers.contains(where: { abs(($0.time - b).seconds) < 0.02 }) {
            p.markers.append(Marker(time: b)); added += 1
        }
        p.markers.sort { $0.time < $1.time }
        return added
    }
}
