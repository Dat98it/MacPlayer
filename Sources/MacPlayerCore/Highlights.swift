import Foundation

// MARK: Finding the best moments of a sports video (0.22)

/// What was measured along a clip's source, one sample every `step` seconds from `start` (source seconds):
/// - `motion`: how much the picture changed since the sample before (mean brightness change, 0…1);
/// - `loudness`: the sound's level in dB (empty when the clip has no sound);
/// - `people`: how much of the picture people fill (0…1), nil where nobody looked;
/// - `personSpeed`: how fast the people's middle moved (picture widths a second), 0 where not known.
public struct HighlightSignals: Equatable, Sendable {
    public var start: Double
    public var step: Double
    public var motion: [Double]
    public var loudness: [Double]
    public var people: [Double?]
    public var personSpeed: [Double]
    /// Goals read on a scoreboard (source seconds), from `ScoreReader` (0.22.1).
    public var goals: [ScoreChange]
    /// A tiny colour picture of each sample (16 × 9 RGB), to find a replay's opening graphic (0.22.1); empty when not measured.
    public var thumbs: [[UInt8]]
    /// Periods of play read from the match clock (0.22.2).
    public var periods: [MatchPeriod] = []
    /// Cards and VAR checks read in words on the picture (0.22.2).
    public var marks: [WordMark] = []
    /// When people stood in a row (two teams lined up) before the first kick-off or after the final whistle (0.22.2), source seconds.
    public var lineups: [Double] = []
    public init(start: Double, step: Double, motion: [Double], loudness: [Double] = [], people: [Double?] = [], personSpeed: [Double] = [],
                goals: [ScoreChange] = [], thumbs: [[UInt8]] = []) {
        self.start = start; self.step = step; self.motion = motion; self.loudness = loudness; self.people = people; self.personSpeed = personSpeed
        self.goals = goals; self.thumbs = thumbs
    }
    public var count: Int { motion.count }
    public func time(_ i: Int) -> Double { start + Double(i) * step }
}

/// The largest number of people standing in one row (feet within `band` of the picture's height of each other): a team lined up.
/// `feet` are the bottoms of the people found, 0…1 from the top.
public func peopleInARow(feet: [Double], band: Double = 0.05) -> Int {
    let f = feet.sorted()
    var best = 0, j = 0
    for i in f.indices { while f[i] - f[j] > band { j += 1 }; best = max(best, i - j + 1) }
    return best
}

/// What a moment is, when it is more than action: the parts of a match a highlight must have (0.22.2).
public enum MatchEventKind: String, Codable, Sendable, CaseIterable {
    case walkout, lineup, kickoff, goal, yellowCard, redCard, check, substitution, halfTime, fullTime
}

/// A card or a VAR check read on the picture, and when.
public struct WordMark: Equatable, Sendable {
    public var kind: MatchWord
    public var time: Double
    public init(kind: MatchWord, time: Double) { self.kind = kind; self.time = time }
}

/// A moment found: where it is in the source and on the timeline, how good it looked (0…1, the best of the search is 1), and whether it
/// goes into the highlight.
public struct HighlightFound: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var clipID: UUID
    public var source: TimeSpan
    public var timeline: TimeSpan
    public var score: Double
    public var chosen = false
    /// A goal read on the scoreboard ("0-1"), when the moment is one.
    public var goal: String?
    /// The broadcast showed it again.
    public var replayed = false
    /// A part of the match it is (kick-off, a goal, a card…): always kept.
    public var event: MatchEventKind?
    public init(clipID: UUID, source: TimeSpan, timeline: TimeSpan, score: Double, goal: String? = nil, replayed: Bool = false, event: MatchEventKind? = nil) {
        self.clipID = clipID; self.source = source; self.timeline = timeline; self.score = score; self.goal = goal; self.replayed = replayed
        self.event = event ?? (goal != nil ? .goal : nil)
    }
    public var length: Double { (timeline.end - timeline.start).seconds }
}

public enum HighlightFinder {
    /// How each measure compares with the rest of the clip: (x − median) / spread, kept within −2…4 so one wild value cannot rule.
    /// A measure that hardly changes gives zeros (a steady music bed says nothing).
    static func standardized(_ x: [Double]) -> [Double] {
        guard x.count > 2 else { return x.map { _ in 0 } }
        let s = x.sorted(), med = s[s.count / 2]
        let dev = x.map { abs($0 - med) }.sorted()[x.count / 2] * 1.4826
        let spread = max(dev, (s[Int(Double(s.count - 1) * 0.9)] - s[Int(Double(s.count - 1) * 0.1)]) / 2.56)
        guard spread > 1e-9 else { return x.map { _ in 0 } }
        return x.map { min(4, max(-2, ($0 - med) / spread)) }
    }

    /// Where the shot changes: a change of picture far bigger than just before and after it (and big in itself). Indices of samples.
    public static func cuts(motion m: [Double]) -> [Int] {
        guard m.count > 4 else { return [] }
        var out: [Int] = []
        for i in m.indices {
            let around = (max(0, i - 3)...min(m.count - 1, i + 3)).filter { $0 != i }.map { m[$0] }.sorted()
            let typical = around[around.count / 2]
            if m[i] > 0.08 && m[i] > 3.5 * typical + 0.02 { out.append(i) }
        }
        // One cut can show over two samples; keep the first.
        return out.enumerated().filter { $0.offset == 0 || out[$0.offset - 1] != $0.element - 1 }.map(\.element)
    }

    /// How exciting each sample is: a lot moving, the people running, the sound rising above its usual level (a cheer, a whistle, a kick).
    /// Shot changes are not movement. Where people were looked for and nobody is near, the picture counts little (a diagram, a title).
    public static func scores(_ s: HighlightSignals) -> [Double] {
        let n = s.count
        guard n > 0 else { return [] }
        var motion = s.motion
        for c in cuts(motion: motion) {
            let nb = [c - 1, c + 1].filter { $0 >= 0 && $0 < n && !(cuts(motion: motion).contains($0)) }.map { motion[$0] }
            motion[c] = nb.isEmpty ? 0 : nb.reduce(0, +) / Double(nb.count)
        }
        let zm = standardized(motion)
        let speed = s.personSpeed.count == n ? s.personSpeed : Array(repeating: 0, count: n)
        let zp = standardized(speed)
        // The sound against its own level over the 8 s around it, so a loud crowd all game long is not exciting everywhere.
        var rise = Array(repeating: 0.0, count: n)
        if s.loudness.count == n {
            let half = max(1, Int(4 / s.step))
            for i in 0..<n {
                let w = s.loudness[max(0, i - half)...min(n - 1, i + half)].sorted()
                rise[i] = s.loudness[i] - w[w.count / 2]
            }
        }
        let za = standardized(rise)
        var raw = (0..<n).map { 0.45 * zm[$0] + 0.3 * zp[$0] + 0.25 * za[$0] }
        if s.people.count == n, s.people.contains(where: { $0 != nil }) {
            let reach = max(1, Int(1.0 / s.step))
            for i in 0..<n {
                let near = s.people[max(0, i - reach)...min(n - 1, i + reach)].compactMap { $0 }
                guard !near.isEmpty else { continue }
                if near.max()! < 0.002 { raw[i] = raw[i] > 0 ? raw[i] * 0.3 : raw[i] - 0.5 }
            }
        }
        // Smoothed over about a second: an action, not a single frame.
        let k = max(1, Int(0.5 / s.step))
        return (0..<n).map { i in let w = raw[max(0, i - k)...min(n - 1, i + k)]; return w.reduce(0, +) / Double(w.count) }
    }

    /// A moment of one clip, in source seconds.
    public struct Moment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var score: Double
        /// A goal read on the scoreboard ("0-1").
        public var goal: String?
        /// The broadcast showed it again (a replay followed it).
        public var replayed = false
        public var event: MatchEventKind? = nil
    }

    /// Replays in a broadcast or a live stream: they open (and usually close) with the same short graphic, seen again and again. A
    /// graphic is a picture that comes with a burst of change, lasts under 2.5 s and is seen at least four times; a camera angle that
    /// comes back after a cut is seen as often but stays. Two showings 4–40 s apart are one replay (opening and closing); a lone one
    /// opens a replay of unknown length. Source seconds.
    public static func replays(_ s: HighlightSignals) -> [(start: Double, end: Double)] {
        let n = s.count
        guard s.thumbs.count == n, n > 50 else { return [] }
        func distance(_ a: [UInt8], _ b: [UInt8]) -> Int { var d = 0; for i in a.indices { d += abs(Int(a[i]) - Int(b[i])) }; return d / max(1, a.count) }
        // The samples with the most change (the top 2 %, at least a clear change) are where a graphic may be.
        let sorted = s.motion.sorted()
        let high = max(0.08, sorted[min(n - 1, Int(Double(n) * 0.98))])
        let candidates = (0..<n).filter { s.motion[$0] >= high }
        guard candidates.count >= 4 else { return [] }
        let apart = Int(3 / s.step)
        // Candidates that match the most others (seen elsewhere), best first.
        let matches = candidates.map { c in candidates.filter { abs($0 - c) > apart && distance(s.thumbs[c], s.thumbs[$0]) < 15 }.count }
        var tried = Set<Int>()
        for k in candidates.indices.sorted(by: { matches[$0] > matches[$1] }) where matches[k] >= 3 {
            let ref = s.thumbs[candidates[k]]
            if tried.contains(where: { distance(s.thumbs[$0], ref) < 15 }) { continue }
            tried.insert(candidates[k])
            // Every showing of it.
            var shows: [(a: Int, b: Int)] = []
            for i in 0..<n where distance(s.thumbs[i], ref) < 20 {
                if let l = shows.last, i - l.b <= Int(1 / s.step) { shows[shows.count - 1].b = i } else { shows.append((i, i)) }
            }
            // A graphic is brief every time; a view that stays is not one.
            guard shows.count >= 4, shows.allSatisfy({ Double($0.b - $0.a) * s.step <= 2.5 }) else { continue }
            var out: [(start: Double, end: Double)] = []
            var i = 0
            while i < shows.count {
                let open = s.time(shows[i].a)
                if i + 1 < shows.count {
                    let gap = s.time(shows[i + 1].a) - open
                    if gap >= 4 && gap <= 40 { out.append((open, s.time(shows[i + 1].b) + s.step)); i += 2; continue }
                }
                out.append((open, s.time(shows[i].b) + s.step))
                i += 1
            }
            return out
        }
        return []
    }

    /// The moments of one clip, best first, in source seconds: goals (read on the scoreboard), then moments the broadcast replayed, then
    /// around each peak of `scores` `before` seconds ahead of it and `after` behind (more while the excitement lasts, up to
    /// `maxLength`), never across a shot change, never overlapping another moment, never in a replay. Only peaks above `threshold` count.
    public static func moments(_ s: HighlightSignals, before: Double = 1.5, after: Double = 1.5, minLength: Double = 2.5, maxLength: Double = 12,
                               threshold: Double = 0.25, minGap: Double = 2.0, withReplays: Bool = true) -> [Moment] {
        let sc = scores(s)
        let n = sc.count
        guard n > 2 else { return [] }
        let cutTimes = cuts(motion: s.motion).map { s.time($0) }
        let first = s.time(0), last = s.time(n - 1) + s.step
        let best = max(sc.max() ?? 0, threshold)
        var taken: [Moment] = []
        func free(_ a: Double, _ b: Double) -> Bool { !taken.contains { $0.start < b && $0.end > a } }
        // Replays are the same action again: not moments of their own, but each tells which action came just before it. Moments end
        // 1.2 s before a replay's graphic is recognised: it fades in about half a second before.
        var replays = replays(s)
        var inReplay = Array(repeating: false, count: n)
        for r in replays {
            let a = max(0, Int((r.start - s.start) / s.step)), b = min(n - 1, Int((r.end - s.start) / s.step))
            if a <= b { for i in a...b { inReplay[i] = true } }
        }
        // The parts of a match: walking out, each kick-off and the whistle at its end (from the match clock), cards and VAR checks
        // (from words on the picture). Each always worth more than any action.
        func event(_ kind: MatchEventKind, _ a: Double, _ b: Double, detail: String? = nil) {
            let start = max(first, a), end = min(last, b)
            guard end - start >= minLength, free(start, end) else { return }
            taken.append(Moment(start: start, end: end, score: best * 1.4, goal: nil, replayed: false, event: kind))
        }
        // After a whistle the commentator speaks: quiet is 20 dB under the talk around the whistle; never into the next kick-off;
        // without sound, 6 s.
        func talkEnds(after e: Double, before next: Double, firstPhrase: Bool) -> Double {
            guard s.loudness.count == n else { return min(e + 6, next) }
            func at(_ t: Double) -> Int { max(0, min(n - 1, Int((t - s.start) / s.step))) }
            let around = s.loudness[at(e - 5)...at(e + 10)].sorted()
            let talk = around[around.count / 2]
            var quiet = 0
            // At half-time only the first sentence (the whistle, "end of the first half"): it ends at the first pause between words
            // (0.4 s); the score read after it is left out. At full time, until the talk stops (2 s): the final result is in.
            let pause = firstPhrase ? 0.4 : 2.0
            var t = e + (firstPhrase ? 2 : 3)
            let limit = min(last, e + (firstPhrase ? 15 : 40), next)
            while t < limit {
                if s.loudness[at(t)] < talk - 20 { quiet += 1; if Double(quiet) * s.step >= pause - 1e-9 { return max(e + 4, t - Double(quiet - 1) * s.step) } } else { quiet = 0 }
                t += s.step
            }
            return max(e + 6, limit)
        }
        // A video may start late (no walk-out, no kick-off: a stream that began after it) or stop early (a stream cut before the
        // whistle): what is not in it is simply not there, and the rest is found as usual.
        let lastPeriod = s.periods.count - 1
        for (k, p) in s.periods.enumerated() {
            if p.kickoffSeen && p.kickoff >= first - 2 { event(.kickoff, p.kickoff - 5, p.kickoff + 8) }
            // The whistle is in the video only if the video goes on after the clock stopped (else the stream ended during play).
            if k < lastPeriod || p.end <= last - 20 {
                event(k == lastPeriod ? .fullTime : .halfTime, p.end - 10, talkEnds(after: p.end, before: k < lastPeriod ? s.periods[k + 1].kickoff - 6 : .infinity, firstPhrase: k < lastPeriod))
            }
        }
        // Before the first kick-off, the times the teams stood in a row make runs (looks under 6 s apart): the first is the walk out
        // behind the referee, the next the teams lined up on the pitch (greetings, the line-ups read out).
        func runs(_ times: [Double]) -> [(a: Double, b: Double)] {
            var out: [(a: Double, b: Double)] = []
            for t in times.sorted() { if let l = out.last, t - l.b <= 6 { out[out.count - 1].b = t } else { out.append((t, t)) } }
            return out
        }
        if let p0 = s.periods.first, p0.kickoffSeen {
            let k = p0.kickoff
            let before = runs(s.lineups.filter { $0 < k - 10 && $0 > k - 900 })
            if let w = before.first { event(.walkout, w.a - 3, min(w.a + 25, k - 6, before.count > 1 ? before[1].a - 1.5 : .infinity)) }
            if before.count > 1 {
                // The line-up runs on after the last look of the row (the camera goes along the players, the handshakes, the toss):
                // until the loudspeaker falls silent (6 s at least 20 dB under its level while the teams stood there: the reader's pauses
                // between names last 2–4 s), else a minute on;
                // never into the kick-off.
                let l = before[1]
                var end = min(k - 10, l.b + 60)
                if s.loudness.count == n {
                    func at(_ t: Double) -> Int { max(0, min(n - 1, Int((t - s.start) / s.step))) }
                    let level = s.loudness[at(l.a)...at(l.b)].sorted()
                    let usual = level[level.count / 2]
                    var quiet = 0
                    var t = l.b + 3
                    while t < min(k - 10, l.b + 90) {
                        if s.loudness[at(t)] < usual - 20 { quiet += 1; if Double(quiet) * s.step >= 6 { end = t - Double(quiet) * s.step; break } } else { quiet = 0 }
                        t += s.step
                    }
                }
                event(.lineup, l.a - 1, max(end, l.a + 12))
            }
        }
        for m in s.marks {
            switch m.kind {
            // The players going off and on are shown with the graphic.
            case .substitution: event(.substitution, m.time - 8, m.time + 10)
            // The foul (or the moment checked) comes before the graphic.
            case .yellowCard: event(.yellowCard, m.time - 15, m.time + 5)
            case .redCard: event(.redCard, m.time - 15, m.time + 5)
            case .check: event(.check, m.time - 15, m.time + 5)
            }
        }
        // Goals first. With replays, the goal is the action just before the replay nearest to the moment the new score was first read
        // (from 90 s before the old score was last read: the scoreboard is put right by hand, at times a minute late): 25 s, so the
        // attack that led to it, the shot and the cheering are in. Without, the most exciting moment of the 90 s before the new score was read.
        for g in s.goals {
            var start: Double, end: Double
            if let k = replays.indices.filter({ replays[$0].start >= g.lastOld - 90 && replays[$0].start <= g.firstNew + 15 })
                .min(by: { abs(replays[$0].start - g.firstNew) < abs(replays[$1].start - g.firstNew) }) {
                start = replays[k].start - 1.2 - 25
                // With the replay: the whole of it after the goal, so a viewer who missed the action sees all of it again.
                end = withReplays ? replays[k].end : replays[k].start - 1.2
                replays.remove(at: k)
            } else {
                let a = max(0, Int(((g.firstNew - 90) - s.start) / s.step)), b = min(n - 1, Int(((g.firstNew - 3) - s.start) / s.step))
                guard a < b, let p = (a...b).filter({ !inReplay[$0] }).max(by: { sc[$0] < sc[$1] }) else { continue }
                let t = s.time(p) + s.step / 2
                start = t - 18; end = t + 6
            }
            start = max(first, start); end = min(last, end)
            guard end - start >= minLength, free(start, end) else { continue }
            taken.append(Moment(start: start, end: end, score: best * 1.5, goal: g.label, replayed: true, event: .goal))
        }
        // Then what the broadcast chose to show again: the 12 s before each other replay (and the replay).
        for r in replays {
            let end = min(last, withReplays ? r.end : r.start - 1.2), start = max(first, r.start - 1.2 - 12)
            guard end - start >= minLength, free(start, end) else { continue }
            taken.append(Moment(start: start, end: end, score: best * 1.2, goal: nil, replayed: true))
        }
        for p in sc.indices.sorted(by: { sc[$0] > sc[$1] }) {
            let peak = sc[p]
            guard peak > threshold else { break }
            let t = s.time(p) + s.step / 2
            guard !inReplay[p], !taken.contains(where: { t >= $0.start && t <= $0.end }) else { continue }
            // Only the top of a rise counts: the tail of an action that was already taken is not an action of its own.
            let reach = max(1, Int(minGap / s.step))
            guard !sc[max(0, p - reach)...min(n - 1, p + reach)].contains(where: { $0 > peak }) else { continue }
            // Grow while the excitement stays above 40 % of the peak.
            var a = p, b = p
            while a > 0 && sc[a - 1] > peak * 0.4 && s.time(p) - s.time(a - 1) < maxLength * 0.6 { a -= 1 }
            while b < n - 1 && sc[b + 1] > peak * 0.4 && s.time(b + 1) - s.time(p) < maxLength * 0.6 { b += 1 }
            // The room before and after comes from the action itself (0.22.3): back while it was building up (the run-up: above 15 %
            // of the peak, at most 6 s before the excitement), on while it dies down (the finish and the cheer: above 20 %, at most
            // 4 s), with 2 s more before (what led to it) and 1 s after; never less than `before` / `after` around the peak.
            var ra = a, rb = b
            while ra > 0 && sc[ra - 1] > peak * 0.15 && s.time(a) - s.time(ra - 1) <= 6 { ra -= 1 }
            while rb < n - 1 && sc[rb + 1] > peak * 0.2 && s.time(rb + 1) - s.time(b) <= 4 { rb += 1 }
            var start = min(t - before, s.time(ra) - 2), end = max(t + after, s.time(rb) + s.step + 1)
            if end - start > maxLength { let over = end - start - maxLength; start += over * 0.5; end -= over * 0.5 }
            // A shot change inside: the moment stays in the shot of its peak.
            if let c = cutTimes.filter({ $0 > start && $0 <= t }).max() { start = c }
            if let c = cutTimes.filter({ $0 > t && $0 < end }).min() { end = c }
            start = max(first, start); end = min(last, end)
            // Not into a moment already taken, nor into a replay.
            for o in taken {
                if o.end > start && o.end <= t { start = o.end }
                if o.start < end && o.start >= t { end = o.start }
            }
            while start < t, inReplay[max(0, min(n - 1, Int((start - s.start) / s.step)))] { start += s.step }
            while end > t, inReplay[max(0, min(n - 1, Int((end - s.start) / s.step) - 1))] { end -= s.step }
            guard end - start >= minLength else { continue }
            taken.append(Moment(start: start, end: end, score: peak, goal: nil))
        }
        return taken
    }

    /// The moments of clip `c` placed on the timeline at `clipStart` (the clip's speed taken into account). Scores are as measured;
    /// `normalize` makes the best of a search 1.
    public static func found(in c: TimelineClip, clipStart: MediaTime, signals: HighlightSignals, before: Double = 1.5, after: Double = 1.5,
                             maxLength: Double = 12, withReplays: Bool = true) -> [HighlightFound] {
        let k = max(VideoLook.minimumSpeed, c.look.speed)
        let lo = c.sourceStart.seconds, hi = c.sourceEnd.seconds
        return moments(signals, before: before, after: after, maxLength: maxLength, withReplays: withReplays).compactMap { m in
            let a = max(lo, m.start), b = min(hi, m.end)
            guard b - a >= 1 else { return nil }
            let ta = clipStart.seconds + (a - lo) / k, tb = clipStart.seconds + (b - lo) / k
            return HighlightFound(clipID: c.id, source: TimeSpan(start: MediaTime(seconds: a, timescale: 6000), end: MediaTime(seconds: b, timescale: 6000)),
                                  timeline: TimeSpan(start: MediaTime(seconds: ta, timescale: 6000), end: MediaTime(seconds: tb, timescale: 6000)), score: m.score, goal: m.goal, replayed: m.replayed, event: m.event)
        }
    }

    /// The gain (dB) that brings the sound of a piece of the source (`from`…`to`, source seconds) to `target` dB of average level, within
    /// −9…+4 dB: a highlight cut from a match jumps from a booming loudspeaker to a quiet field; evened out, the loud parts are not
    /// pushed into crackling when written again. Nil when the sound was not measured there.
    public static func evenGain(_ s: HighlightSignals, from: Double, to: Double, target: Double = -20) -> Double? {
        guard s.loudness.count == s.count, to > from else { return nil }
        let a = max(0, Int((from - s.start) / s.step)), b = min(s.count, Int((to - s.start) / s.step))
        guard b > a else { return nil }
        // The average power, not the average of dB (loud moments count as loud).
        let power = s.loudness[a..<b].reduce(0) { $0 + pow(10, $1 / 10) } / Double(b - a)
        guard power > 0 else { return nil }
        return min(4, max(-9, target - 10 * log10(power)))
    }

    /// Scores as shares of the best one, and the list in timeline order.
    public static func normalize(_ items: [HighlightFound]) -> [HighlightFound] {
        let best = items.map(\.score).max() ?? 1
        return items.map { var x = $0; x.score = best > 0 ? max(0, $0.score / best) : 0; return x }.sorted { $0.timeline.start < $1.timeline.start }
    }

    /// The highlight chosen with no setting to make (0.22.3): every part of the match (walk-out, line-up, kick-offs, goals, cards,
    /// substitutions, whistles); the whole highlight about a tenth of what was looked at (`seconds`; 30 s…8 min); what the parts leave
    /// goes to the play itself (at least 2 % of the video, up to a minute, so a match full of goals still shows a few chances): first
    /// what the broadcast replayed (it chose them), then clear action (at least half as exciting as the best moment), best first.
    public static func autoChoose(_ items: inout [HighlightFound], seconds: Double) {
        for i in items.indices { items[i].chosen = items[i].event != nil }
        let target = min(480, max(30, seconds * 0.1))
        let parts = items.filter { $0.event != nil }.reduce(0) { $0 + $1.length }
        let budget = max(target - parts, min(60, seconds * 0.02))
        let best = items.filter { $0.event == nil }.map(\.score).max() ?? 0
        var total = 0.0
        let order = items.indices.filter { items[$0].event == nil }.sorted {
            items[$0].replayed != items[$1].replayed ? items[$0].replayed : items[$0].score > items[$1].score
        }
        for i in order {
            guard total < budget * 0.9 else { break }
            guard items[i].replayed || items[i].score >= best * 0.5 else { continue }
            if total > 0 && total + items[i].length > budget * 1.1 { continue }
            items[i].chosen = true
            total += items[i].length
        }
    }

    /// What is shown to look over: the chosen moments, and only the `extras` best of the rest (a match gives hundreds of small
    /// moments; nobody wants to go through them), in time order.
    public static func shortlist(_ items: [HighlightFound], extras: Int = 15) -> [HighlightFound] {
        let more = items.filter { !$0.chosen }.sorted { $0.score > $1.score }.prefix(extras)
        return (items.filter(\.chosen) + more).sorted { $0.timeline.start < $1.timeline.start }
    }

    /// Chooses the parts of the match (kick-off, goals, cards, full time…), then the best moments until the highlight is `target` seconds long, give or take a tenth; 0 chooses all.
    public static func choose(_ items: inout [HighlightFound], target: Double) {
        guard target > 0 else { for i in items.indices { items[i].chosen = true }; return }
        var total = 0.0
        for i in items.indices { items[i].chosen = false }
        // Goals always go in.
        for i in items.indices where items[i].event != nil { items[i].chosen = true; total += items[i].length }
        for i in items.indices.sorted(by: { items[$0].score > items[$1].score }) where items[i].event == nil {
            guard total < target * 0.9 else { break }
            // A moment that would make it more than a tenth too long is passed over for a shorter one.
            if total > 0 && total + items[i].length > target * 1.1 { continue }
            items[i].chosen = true
            total += items[i].length
        }
    }
}

extension TimelineCuts {
    /// Keeps only the chosen moments of the clips in `clips` (the clips looked at): everything else of those clips is cut out, in one
    /// go; clips outside `clips` stay as they are. With `ripple`, what lies over the timeline follows. Returns how many moments are kept.
    @discardableResult
    public static func keepHighlights(_ p: inout Project, _ found: [HighlightFound], clips: Set<UUID>, ripple: Bool) -> Int {
        let chosen = found.filter(\.chosen)
        guard !chosen.isEmpty else { return 0 }
        let starts = TimelineEditor.starts(p.timeline)
        var drop: [SilenceFound] = []
        for c in p.timeline where clips.contains(c.id) {
            guard let start = starts[c.id] else { continue }
            let k = max(VideoLook.minimumSpeed, c.look.speed)
            let keep = chosen.filter { $0.clipID == c.id }.map { (max($0.source.start, c.sourceStart), min($0.source.end, c.sourceEnd)) }
                .filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
            var at = c.sourceStart
            func gap(_ a: MediaTime, _ b: MediaTime) {
                guard b > a else { return }
                let ta = start + MediaTime(seconds: (a - c.sourceStart).seconds / k, timescale: 6000)
                let tb = start + MediaTime(seconds: (b - c.sourceStart).seconds / k, timescale: 6000)
                var s = SilenceFound(clipID: c.id, source: TimeSpan(start: a, end: b), timeline: TimeSpan(start: ta, end: tb)); s.chosen = true
                drop.append(s)
            }
            for (a, b) in keep { gap(at, a); at = max(at, b) }
            gap(at, c.sourceEnd)
        }
        removeSilences(&p, drop, ripple: ripple)
        return chosen.count
    }
}
