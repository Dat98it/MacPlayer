import Foundation
import Testing
@testable import MacPlayerCore

struct HighlightTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 6000) }

    /// 60 s of a calm picture sampled every 0.2 s from source second `start`, with a little noise so the clip has a spread.
    private func calm(start: Double = 0, seconds: Double = 60) -> HighlightSignals {
        let n = Int(seconds / 0.2)
        return HighlightSignals(start: start, step: 0.2,
                                motion: (0..<n).map { 0.01 + 0.004 * sin(Double($0) * 1.7) },
                                loudness: (0..<n).map { -30 + 1.5 * sin(Double($0) * 2.3) },
                                people: (0..<n).map { _ in 0.05 },
                                personSpeed: (0..<n).map { 0.02 + 0.01 * sin(Double($0) * 0.9) })
    }

    private func burst(_ x: inout HighlightSignals, from a: Double, to b: Double, motion m: Double = 0.06, speed: Double = 0.5, cheer: Double = 0) {
        for i in 0..<x.count where x.time(i) >= a && x.time(i) < b {
            x.motion[i] = m; x.personSpeed[i] = speed; x.loudness[i] += cheer
        }
    }

    @Test func aShotChangeIsFoundAndIsNotAction() {
        var x = calm()
        x.motion[100] = 0.4                            // one frame utterly different from the last: a cut at 20 s
        #expect(HighlightFinder.cuts(motion: x.motion) == [100])
        #expect(HighlightFinder.moments(x).isEmpty, "a cut alone is not a moment")
    }

    @Test func theActionIsFoundWithTimeBeforeAndAfterIt() {
        var x = calm()
        burst(&x, from: 30, to: 33, cheer: 12)
        let m = HighlightFinder.moments(x)
        #expect(m.count == 1, "\(m)")
        guard let f = m.first else { return }
        #expect(f.start <= 30 - 1.5 && f.start >= 30 - 6, "starts before the action: \(f)")
        #expect(f.end >= 33 && f.end <= 33 + 5, "ends after it: \(f)")
        #expect(f.end - f.start <= 10.01)
    }

    @Test func theBiggerActionScoresHigherAndMomentsDoNotOverlap() {
        var x = calm()
        burst(&x, from: 10, to: 12, motion: 0.04, speed: 0.3)
        burst(&x, from: 40, to: 43, motion: 0.08, speed: 0.6, cheer: 10)
        burst(&x, from: 44.5, to: 46, motion: 0.05, speed: 0.4)
        let m = HighlightFinder.moments(x)
        #expect(m.count >= 2)
        #expect(m[0].start < 41 && m[0].end > 42, "the best one is first: \(m)")
        for a in m { for b in m where a.start < b.start { #expect(a.end <= b.start + 1e-9, "\(a) overlaps \(b)") } }
    }

    @Test func aMomentStaysInTheShotOfItsPeak() {
        var x = calm()
        x.motion[145] = 0.5                            // cut at 29 s
        burst(&x, from: 30, to: 32, cheer: 10)
        let m = HighlightFinder.moments(x)
        guard let f = m.first else { Issue.record("nothing found"); return }
        #expect(abs(f.start - 29) < 0.01, "starts at the cut, not in the shot before: \(f)")
    }

    @Test func movementWithNobodyInThePictureCountsLittle() {
        // A diagram whose arrows move as much as the players do.
        var x = calm()
        burst(&x, from: 10, to: 13)
        burst(&x, from: 40, to: 43)
        for i in 0..<x.count where x.time(i) >= 36 && x.time(i) < 47 { x.people[i] = 0 }
        let m = HighlightFinder.moments(x)
        #expect(m.first.map { $0.start < 13 } == true, "the moment with people comes first: \(m)")
        let sc = HighlightFinder.scores(x)
        #expect(sc[Int(41.0 / 0.2)] < sc[Int(11.0 / 0.2)] * 0.5)
    }

    @Test func aSteadyClipHasNoMoments() {
        let n = 300
        let x = HighlightSignals(start: 0, step: 0.2, motion: Array(repeating: 0.02, count: n), loudness: Array(repeating: -20, count: n))
        #expect(HighlightFinder.moments(x).isEmpty)
    }

    @Test func choosingFillsTheWantedLengthWithTheBest() {
        func h(_ a: Double, _ len: Double, _ score: Double) -> HighlightFound {
            HighlightFound(clipID: UUID(), source: TimeSpan(start: s(a), end: s(a + len)), timeline: TimeSpan(start: s(a), end: s(a + len)), score: score)
        }
        var items = [h(0, 5, 0.9), h(10, 6, 0.5), h(20, 4, 1.0), h(30, 8, 0.7), h(50, 5, 0.2)]
        HighlightFinder.choose(&items, target: 9)
        #expect(items.filter(\.chosen).map(\.score).sorted() == [0.9, 1.0], "\(items.map(\.chosen))")
        HighlightFinder.choose(&items, target: 15)
        // 4 + 5 = 9; the 8 s one would make 17 (> 15 × 1.1), so the 6 s one: 15.
        #expect(items.filter(\.chosen).map(\.score).sorted() == [0.5, 0.9, 1.0])
        HighlightFinder.choose(&items, target: 0)
        #expect(items.allSatisfy { $0.chosen })
        let n = HighlightFinder.normalize(items)
        #expect(n.map(\.score).max() == 1 && n.map(\.timeline.start) == n.map(\.timeline.start).sorted())
    }

    @Test func keepingTheHighlightsCutsTheRestOfTheClipsLookedAt() {
        var p = Project(name: "match", kind: .video)
        let a = TimelineClip(sourceID: UUID(), sourceStart: s(100), sourceEnd: s(160), name: "First half")
        let b = TimelineClip(sourceID: UUID(), sourceStart: s(0), sourceEnd: s(30), name: "Second half")
        let intro = TimelineClip(sourceID: UUID(), sourceStart: s(0), sourceEnd: s(4), name: "Intro")
        p.timeline = [intro, a, b]
        var sa = calm(start: 100); burst(&sa, from: 120, to: 123, cheer: 10); burst(&sa, from: 150, to: 152, motion: 0.05, speed: 0.4)
        var sb = calm(start: 0, seconds: 30); burst(&sb, from: 15, to: 18, cheer: 10)
        let starts = TimelineEditor.starts(p.timeline)
        var found = HighlightFinder.normalize(HighlightFinder.found(in: a, clipStart: starts[a.id]!, signals: sa)
                                              + HighlightFinder.found(in: b, clipStart: starts[b.id]!, signals: sb))
        #expect(found.count >= 3, "\(found.map { ($0.source.start.seconds, $0.source.end.seconds) })")
        #expect(found.allSatisfy { $0.timeline.start >= starts[$0.clipID]! }, "placed on the timeline after the intro")
        HighlightFinder.choose(&found, target: 0)
        let kept = found.reduce(0) { $0 + $1.length }
        let n = TimelineCuts.keepHighlights(&p, found, clips: [a.id, b.id], ripple: true)
        #expect(n == found.count)
        #expect(p.timeline.first?.name == "Intro" && p.timeline.first?.duration.seconds == 4, "a clip not looked at stays")
        #expect(abs(p.timeline.reduce(0) { $0 + $1.duration.seconds } - (4 + kept)) < 0.01)
        // What is left of the two halves is exactly the moments (moments that touch stay one piece), in order.
        let pieces = p.timeline.dropFirst().map { ($0.sourceStart.seconds, $0.sourceEnd.seconds) }
        #expect(pieces.count <= found.count && pieces.count >= 3)
        #expect(pieces.allSatisfy { pc in found.contains { abs($0.source.start.seconds - pc.0) < 0.01 } && found.contains { abs($0.source.end.seconds - pc.1) < 0.01 } }, "\(pieces)")
    }

    @Test func aFastClipHasItsMomentsPlacedAtItsSpeed() {
        var c = TimelineClip(sourceID: UUID(), sourceStart: s(0), sourceEnd: s(60), name: "x")
        c.look.speed = 2
        var x = calm(); burst(&x, from: 30, to: 33, cheer: 10)
        let f = HighlightFinder.found(in: c, clipStart: s(5), signals: x)
        guard let m = f.first else { Issue.record("nothing found"); return }
        #expect(abs(m.timeline.start.seconds - (5 + m.source.start.seconds / 2)) < 0.01)
        #expect(abs(m.length - (m.source.end - m.source.start).seconds / 2) < 0.01)
    }
}

struct ScoreReaderTests {
    @Test func scoresAreReadAndClocksAreNot() {
        #expect(ScoreReader.parse("0 1")! == (0, 1))
        #expect(ScoreReader.parse("2-5")! == (2, 5))
        #expect(ScoreReader.parse(" 1:0 ")! == (1, 0))
        #expect(ScoreReader.parse("11:16") == nil, "a clock")
        #expect(ScoreReader.parse("FC 2003") == nil && ScoreReader.parse("25") == nil && ScoreReader.parse("2026") == nil)
    }

    private func look(_ score: String, _ t: Double, clock: String = "10:00") -> [(text: String, x: Double, y: Double)] {
        [("FC 2003", 0.77, 0.08), (score, 0.85, 0.08), ("FC 1998", 0.92, 0.08), (clock, 0.85, 0.12), ("25", 0.15, 0.6)]
    }

    @Test func aGoalIsAScoreUpByOneReadTwice() {
        var r = ScoreReader()
        let seq = ["0 0", "0 0", "0 0", "0 1", "0 1", "0 1", "0 7", "0 1", "1 1", "1 1", "1 1"]
        for (i, s) in seq.enumerated() { r.add(look(s, Double(i) * 10, clock: String(format: "%02d:%02d", i, i * 7 % 60)), at: Double(i) * 10) }
        let c = r.changes()
        #expect(c.map(\.label) == ["0-1", "1-1"], "a misread 0 7 is not a goal: \(c.map(\.label))")
        #expect(c.first?.lastOld == 20 && c.first?.firstNew == 30)
    }

    @Test func noScoreboardNoGoals() {
        var r = ScoreReader()
        for i in 0..<20 { r.add([("BUT MEDIA", 0.1, 0.1), (String(format: "%02d:%02d", i / 6, i * 10 % 60), 0.8, 0.1)], at: Double(i) * 10) }
        #expect(r.changes().isEmpty)
    }
}

struct ReplayTests {
    /// 300 s of a calm field, sampled every 0.2 s, with a green opening graphic (1.2 s) shown at the given times.
    private func broadcast(graphics: [Double], seconds: Double = 300) -> HighlightSignals {
        let n = Int(seconds / 0.2)
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.01 + 0.004 * sin(Double($0) * 1.7) },
                                 loudness: (0..<n).map { -30 + 1.5 * sin(Double($0) * 2.3) }, people: (0..<n).map { _ in 0.05 },
                                 personSpeed: (0..<n).map { 0.02 + 0.01 * sin(Double($0) * 0.9) })
        let field: [UInt8] = (0..<432).map { i in UInt8([90, 110, 70][i % 3] + (i / 3) % 7) }
        let green: [UInt8] = (0..<432).map { i in UInt8([20, 220, 60][i % 3]) }
        s.thumbs = (0..<n).map { i in
            let t = Double(i) * 0.2
            return graphics.contains(where: { t >= $0 && t < $0 + 1.2 }) ? green : field
        }
        for g in graphics { for i in 0..<n where s.time(i) >= g && s.time(i) < g + 1.2 { s.motion[i] = 0.2 } }
        return s
    }

    @Test func pairsOfARepeatedGraphicAreReplays() {
        let s = broadcast(graphics: [40, 48.2, 120, 135.4, 200, 208.2])
        let r = HighlightFinder.replays(s)
        #expect(r.count == 3, "\(r)")
        #expect(abs((r.first?.start ?? 0) - 40) < 0.3 && abs((r.first?.end ?? 0) - 49.4) < 0.4)
    }

    @Test func aViewThatStaysIsNotAReplayGraphic() {
        var s = broadcast(graphics: [])
        // A second camera cut to four times, staying 20 s each time.
        let other: [UInt8] = (0..<432).map { i in UInt8([30, 40, 200][i % 3]) }
        for c in [30.0, 90, 150, 210] { for i in 0..<s.count where s.time(i) >= c && s.time(i) < c + 20 { s.thumbs[i] = other; if s.time(i) < c + 0.4 { s.motion[i] = 0.3 } } }
        #expect(HighlightFinder.replays(s).isEmpty)
    }

    @Test func theGoalIsTheActionBeforeItsReplayAndComesFirst() {
        var s = broadcast(graphics: [100, 115.4, 200, 208.2])
        s.goals = [ScoreChange(from: (0, 0), to: (0, 1), lastOld: 90, firstNew: 130)]
        let m = HighlightFinder.moments(s)
        let goal = m.first { $0.goal == "0-1" }
        #expect(goal.map { abs($0.end - 116.6) < 0.3 && abs($0.start - 73.8) < 0.3 } == true, "25 s before the replay, and the replay: \(String(describing: goal))")
        #expect(m.contains { $0.replayed && $0.goal == nil && abs($0.end - 209.4) < 0.3 }, "the other replay gives a moment too")
        #expect(m.filter { $0.start < 116 && $0.end > 101 }.count == 1, "nothing else inside a replay")
        let short = HighlightFinder.moments(s, withReplays: false).first { $0.goal == "0-1" }
        #expect(short.map { abs($0.end - 98.8) < 0.3 } == true, "without replays the goal ends before the replay")
        var found = m.map { HighlightFound(clipID: UUID(), source: TimeSpan(start: MediaTime(seconds: $0.start), end: MediaTime(seconds: $0.end)),
                                          timeline: TimeSpan(start: MediaTime(seconds: $0.start), end: MediaTime(seconds: $0.end)), score: $0.score, goal: $0.goal, replayed: $0.replayed) }
        HighlightFinder.choose(&found, target: 5)
        #expect(found.filter(\.chosen).contains { $0.goal == "0-1" }, "a goal goes in even when the length is short")
    }
}

struct MatchReadingTests {
    private func clockLook(_ seconds: Int, at t: Double) -> [(text: String, x: Double, y: Double)] {
        [("FC A", 0.7, 0.08), ("0 0", 0.85, 0.08), (String(format: "%02d:%02d", seconds / 60, seconds % 60), 0.85, 0.12)]
    }

    @Test func theClockGivesKickOffsAndWhistles() {
        var c = ClockReader()
        var t = 100.0
        // Standing at 00:00 for a while, kick-off at 163 (between two looks), half until 1963, standing at 30:00, second half from 2400.
        while t < 2600 {
            let s: Int
            if t < 163 { s = 0 } else if t < 1963 { s = Int(t - 163) } else if t < 2400 { s = 1800 } else { s = 1800 + Int(t - 2400) }
            c.add(clockLook(s, at: t), at: t); t += 10
        }
        let p = c.periods()
        #expect(p.count == 2 && p.allSatisfy(\.kickoffSeen), "\(p)")
        #expect(abs((p.first?.kickoff ?? 0) - 163) <= 1 && abs((p.first?.end ?? 0) - 1963) <= 10, "\(p)")
        #expect(abs((p.last?.kickoff ?? 0) - 2400) <= 1)
        #expect(ClockReader.parse("11:16") == 676 && ClockReader.parse("0 1") == nil && ClockReader.parse("11:76") == nil)
    }

    @Test func cardsAndChecksAreReadInWords() {
        #expect(MatchWord.find(in: "THẺ VÀNG số 7") == .yellowCard)
        #expect(MatchWord.find(in: "Yellow card") == .yellowCard)
        #expect(MatchWord.find(in: "THẺ ĐỎ") == .redCard)
        #expect(MatchWord.find(in: "CHECK VAR") == .check)
        #expect(MatchWord.find(in: "THAY NGƯỜI") == .substitution && MatchWord.find(in: "Substitution") == .substitution)
        #expect(MatchWord.find(in: "VARIETY SHOW") == nil && MatchWord.find(in: "GIẢI ĐỒNG NIÊN") == nil && MatchWord.find(in: "ĐỎ") == nil)
        var w = WordSpotter()
        for t in stride(from: 0.0, to: 50, by: 10) { w.add([("THẺ VÀNG", 0.5, 0.9)], at: t) }
        w.add([("THẺ VÀNG", 0.5, 0.9)], at: 300)
        #expect(w.events.count == 2, "one per graphic, not one per look")
    }

    @Test func peopleInARowAreCounted() {
        #expect(peopleInARow(feet: [0.60, 0.61, 0.62, 0.61, 0.60, 0.63, 0.62, 0.61, 0.30, 0.90]) == 8)
        #expect(peopleInARow(feet: [0.1, 0.25, 0.4, 0.55, 0.7, 0.85]) == 1)
    }

    @Test func thePartsOfTheMatchAreAllKept() {
        let n = 3000                      // 600 s at 0.2 s
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.01 + 0.004 * sin(Double($0) * 1.7) },
                                 loudness: (0..<n).map { -30 + 1.5 * sin(Double($0) * 2.3) })
        s.periods = [MatchPeriod(kickoff: 120, end: 300), MatchPeriod(kickoff: 360, end: 560)]
        s.lineups = [60, 62, 64, 80, 82, 84, 86, 570, 572]
        s.marks = [WordMark(kind: .yellowCard, time: 200), WordMark(kind: .substitution, time: 450)]
        let m = HighlightFinder.moments(s)
        func one(_ k: MatchEventKind) -> HighlightFinder.Moment? { m.first { $0.event == k } }
        #expect(one(.walkout).map { abs($0.start - 57) < 0.01 } == true)
        #expect(one(.lineup).map { abs($0.start - 79) < 0.01 && abs($0.end - 110) < 0.01 } == true, "a minute after the last row look, before the kick-off: \(String(describing: one(.lineup)))")
        // With the loudspeaker falling silent at 100 s, the line-up ends there.
        var q = s
        for i in 0..<n where (q.time(i) >= 92 && q.time(i) < 95) || (q.time(i) >= 100 && q.time(i) < 108) { q.loudness[i] = -60 }
        let lq = HighlightFinder.moments(q).first { $0.event == .lineup }
        #expect(lq.map { abs($0.end - 100) < 0.3 } == true, "a 3 s pause between names is not the end: \(String(describing: lq))")
        #expect(m.filter { $0.event == .kickoff }.count == 2 && one(.halfTime) != nil && one(.fullTime) != nil && !m.contains { $0.start > 566 })
        #expect(one(.yellowCard).map { $0.start < 200 && $0.end > 200 } == true, "the foul before the card graphic")
        #expect(one(.substitution).map { $0.start < 450 && $0.end > 455 } == true)
        var found = m.map { HighlightFound(clipID: UUID(), source: TimeSpan(start: MediaTime(seconds: $0.start), end: MediaTime(seconds: $0.end)),
                                          timeline: TimeSpan(start: MediaTime(seconds: $0.start), end: MediaTime(seconds: $0.end)), score: $0.score, event: $0.event) }
        HighlightFinder.choose(&found, target: 10)
        #expect(found.filter(\.chosen).count >= 7, "every part of the match is kept, whatever the length")
    }
}

struct EvenSoundTests {
    @Test func loudPartsAreTurnedDownAndQuietOnesUp() {
        let n = 500
        let s = HighlightSignals(start: 100, step: 0.2, motion: Array(repeating: 0.01, count: n), loudness: (0..<n).map { $0 < 250 ? -10 : -30 })
        #expect(abs((HighlightFinder.evenGain(s, from: 100, to: 140) ?? 0) - (-10)) < 0.01 || HighlightFinder.evenGain(s, from: 100, to: 140) == -9)
        #expect(abs((HighlightFinder.evenGain(s, from: 160, to: 190) ?? 0) - 4) < 0.01, "at most +4 dB")
        #expect(HighlightFinder.evenGain(HighlightSignals(start: 0, step: 0.2, motion: [0, 0, 0]), from: 0, to: 0.6) == nil)
    }

    @Test func aRaisedClipNeverClips() {
        // Quiet on average (-26 dB) but the crowd peaks at -0.5 dBFS (the VSC match): +4 dB would push it past 0 dBFS.
        let n = 500
        var s = HighlightSignals(start: 0, step: 0.2, motion: Array(repeating: 0.01, count: n), loudness: Array(repeating: -26, count: n))
        s.peaks = (0..<n).map { $0 == 300 ? -0.5 : -12 }
        #expect(abs((HighlightFinder.evenGain(s, from: 50, to: 70) ?? 0) + 1.5) < 0.01, "peak -0.5 dB: at most -1.5 dB, so it stays under -2 dBFS")
        #expect(abs((HighlightFinder.evenGain(s, from: 0, to: 40) ?? 0) - 4) < 0.01, "peaks of -12 dB leave room for +4 dB")
    }
}

struct PartialMatchTests {
    private func look(_ s: Int, _ score: String) -> [(text: String, x: Double, y: Double)] {
        [("FC A", 0.7, 0.08), (score, 0.85, 0.08), (String(format: "%02d:%02d", s / 60, s % 60), 0.85, 0.12)]
    }

    /// A stream that joined the match at 23:00 with the score at 2-1, saw one more goal, and stopped while play went on.
    @Test func aVideoStartingLateAndCutShortStillGivesAHighlight() {
        var clock = ClockReader(), board = ScoreReader()
        for i in 0..<60 {
            let t = Double(i) * 10, score = t < 300 ? "2 1" : "3 1"
            clock.add(look(1380 + Int(t), score), at: t); board.add(look(1380 + Int(t), score), at: t)
        }
        let periods = clock.periods()
        #expect(periods.count == 1 && periods.first?.kickoffSeen == false, "joined after the kick-off: \(periods)")
        #expect(board.changes().map(\.label) == ["3-1"], "2-1 at the start is not a goal")
        let n = 3000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.01 + 0.004 * sin(Double($0) * 1.7) },
                                 loudness: (0..<n).map { -30 + 1.5 * sin(Double($0) * 2.3) })
        for i in 0..<n where (s.time(i) >= 280 && s.time(i) < 284) || (s.time(i) >= 450 && s.time(i) < 454) { s.motion[i] = 0.08 }
        s.periods = periods; s.goals = board.changes(); s.lineups = [5, 7, 9, 30, 32]
        let m = HighlightFinder.moments(s)
        #expect(!m.contains { [.kickoff, .walkout, .lineup, .halfTime, .fullTime].contains($0.event) }, "\(m.compactMap(\.event))")
        #expect(m.contains { $0.event == .goal }, "the goal is still found")
        #expect(m.contains { $0.event == nil && $0.start < 452 && $0.end > 452 }, "and the other action")
    }

    @Test func aVideoStartingAtTheKickOffHasItButNoWalkOut() {
        var clock = ClockReader()
        for i in 0..<60 { let t = Double(i) * 10 + 4; clock.add(look(Int(t) + 2, "0 0"), at: t) }
        let p = clock.periods()
        #expect(p.first?.kickoffSeen == true && abs((p.first?.kickoff ?? 99) - (-2)) < 0.5, "counted back from 00:06: \(p)")
        let n = 3000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.01 + 0.004 * sin(Double($0) * 1.7) })
        s.periods = [MatchPeriod(kickoff: 1, end: 590, kickoffSeen: true)]
        let m = HighlightFinder.moments(s)
        #expect(m.contains { $0.event == .kickoff } && !m.contains { $0.event == .walkout || $0.event == .fullTime }, "\(m.compactMap(\.event))")
    }
}

struct SecondHalfClockTests {
    @Test func aSecondHalfFromThirtyMinutesIsAKickOff() {
        var c = ClockReader()
        func look(_ v: Int, _ t: Double) { c.add([(String(format: "%02d:%02d", v / 60, v % 60), 0.85, 0.12)], at: t) }
        var t = 0.0
        while t < 400 { look(Int(t) + 1540, t); t += 10 }        // first half, joined at 25:40 (no kick-off seen)
        // half-time: no clock on the board (it says "HIỆP 1"), then the second half counted from 30:00, starting at 800.
        t = 807
        while t < 1200 { look(1800 + Int(t - 800), t); t += 10 }
        let p = c.periods()
        #expect(p.count == 2 && p[0].kickoffSeen == false && p[1].kickoffSeen && abs(p[1].kickoff - 800) < 0.5, "\(p)")
    }
}

struct WhistleTalkTests {
    /// Talk after a whistle at 300 s: a first sentence to 304, a pause of 0.4 s, the score read to 316, then quiet.
    private func signals(halfAndFull: Bool) -> HighlightSignals {
        let n = 3000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.01 + 0.004 * sin(Double($0) * 1.7) },
                                 loudness: (0..<n).map { _ in -12 })
        for i in 0..<n where (s.time(i) >= 304 && s.time(i) < 304.4) || (s.time(i) >= 316 && s.time(i) < 319) { s.loudness[i] = -55 }
        s.periods = halfAndFull ? [MatchPeriod(kickoff: 20, end: 300), MatchPeriod(kickoff: 400, end: 560)] : [MatchPeriod(kickoff: 20, end: 300)]
        return s
    }

    @Test func halfTimeKeepsOnlyTheFirstSentence() {
        let half = HighlightFinder.moments(signals(halfAndFull: true)).first { $0.event == .halfTime }
        #expect(half.map { abs($0.start - 290) < 0.01 && abs($0.end - 304) < 0.3 } == true, "\(String(describing: half))")
    }

    @Test func fullTimeKeepsTheResultReadOut() {
        let full = HighlightFinder.moments(signals(halfAndFull: false)).first { $0.event == .fullTime }
        #expect(full.map { abs($0.end - 316) < 0.3 } == true, "the 0.4 s pause is not the end: \(String(describing: full))")
    }
}

struct AutoChooseTests {
    private func item(_ start: Double, _ len: Double, _ score: Double, event: MatchEventKind? = nil, replayed: Bool = false) -> HighlightFound {
        HighlightFound(clipID: UUID(), source: TimeSpan(start: MediaTime(seconds: start), end: MediaTime(seconds: start + len)),
                       timeline: TimeSpan(start: MediaTime(seconds: start), end: MediaTime(seconds: start + len)), score: score, replayed: replayed, event: event)
    }

    @Test func aMatchKeepsItsPartsThenWhatWasReplayedThenClearAction() {
        var items = [item(10, 25, 0.93, event: .walkout), item(500, 40, 1, event: .goal), item(900, 20, 0.8, replayed: true)]
        items += (0..<300).map { item(1000 + Double($0) * 10, 5, 0.1 + Double($0 % 50) / 100) }
        HighlightFinder.autoChoose(&items, seconds: 5000)
        let chosen = items.filter(\.chosen)
        #expect(chosen.contains { $0.event == .walkout } && chosen.contains { $0.event == .goal } && chosen.contains { $0.replayed })
        let play = chosen.filter { $0.event == nil }.reduce(0) { $0 + $1.length }
        // 8 min in all for an 83-minute video, 65 s of it the parts of the match.
        #expect(play <= 415 * 1.1 && play >= 415 * 0.9 - 5, "the rest of 8 min goes to play: \(play)")
        var crowded = [item(0, 470, 1, event: .goal)] + (0..<40).map { item(1000 + Double($0) * 30, 20, 0.8, replayed: true) }
        HighlightFinder.autoChoose(&crowded, seconds: 5000)
        let extra = crowded.filter { $0.chosen && $0.event == nil }.reduce(0) { $0 + $1.length }
        #expect(extra >= 40 && extra <= 66, "parts filling 8 min still leave about a minute of chances: \(extra)")
        #expect(chosen.filter { $0.event == nil && !$0.replayed }.allSatisfy { $0.score >= 0.29 }, "only clear action")
        let list = HighlightFinder.shortlist(items)
        #expect(list.count == chosen.count + 15, "the chosen ones and 15 more, not 300")
        #expect(list.map(\.timeline.start) == list.map(\.timeline.start).sorted())
    }

    @Test func aShortTrainingVideoGetsAShortHighlight() {
        var items = (0..<30).map { item(Double($0) * 12, 4, Double($0 % 10) / 10 + 0.05) }
        HighlightFinder.autoChoose(&items, seconds: 346)
        let total = items.filter(\.chosen).reduce(0) { $0 + $1.length }
        #expect(total >= 28 && total <= 39, "about a tenth of 346 s: \(total)")
    }
}

struct SetPieceTests {
    /// 300 s of play (the picture always changing), sampled every 0.2 s, with play standing still from `stop` for `still` seconds and
    /// the kick right after (a burst of 2 s, then action).
    private func play(stops: [(stop: Double, still: Double, burst: Double)], weak: Set<Double> = [], attacks: [Double] = []) -> HighlightSignals {
        let n = 1500
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { -25 + 1.5 * sin(Double($0) * 2.1) }, people: (0..<n).map { _ in 0.02 },
                                 personSpeed: (0..<n).map { 0.05 + 0.02 * sin(Double($0) * 0.7) })
        for st in stops {
            for i in 0..<n {
                let t = s.time(i)
                if t >= st.stop && t < st.stop + st.still { s.motion[i] = 0.006; s.personSpeed[i] = 0.005 }
                if t >= st.stop + st.still && t < st.stop + st.still + 2 { s.motion[i] = st.burst; if !weak.contains(st.stop) { s.personSpeed[i] = 0.4; s.loudness[i] += 12 } }
            }
        }
        for a in attacks { for i in 0..<n where s.time(i) >= a && s.time(i) < a + 4 { s.motion[i] = 0.2; s.personSpeed[i] = 0.6; s.loudness[i] += 15 } }
        return s
    }

    @Test func aStillnessThenAKickIsASetPiece() {
        let s = play(stops: [(100, 9, 0.12), (200, 3, 0.12)])
        let k = HighlightFinder.setPieceKicks(s)
        #expect(k.count == 1 && abs(k[0] - 109) <= 1, "only the 9 s wait counts, not a 3 s pause: \(k)")
    }

    @Test func dangerousSetPiecesAreKeptAndTheRestartAfterAGoalIsNot() {
        // A free kick at 38 s, an attack and a goal at 128 s (the score read at 150 s), the restart at 168 s, a weak free kick at 248 s.
        var s = play(stops: [(30, 8, 0.15), (160, 8, 0.15), (240, 8, 0.06)], weak: [240], attacks: [128])
        s.periods = [MatchPeriod(kickoff: 0, end: 299)]
        s.goals = [ScoreChange(from: (0, 0), to: (0, 1), lastOld: 140, firstNew: 150)]
        let m = HighlightFinder.moments(s)
        let pieces = m.filter(\.setPiece)
        #expect(pieces.contains { $0.event == .setPiece && $0.start < 38 && $0.end > 45 }, "the free kick at 38 s, with its setting up and outcome: \(pieces)")
        #expect(!pieces.contains { $0.start > 150 && $0.start < 175 }, "the restart after the goal is not a set piece")
        #expect(pieces.contains { $0.start > 235 && $0.event == nil }, "a weak one is only a suggestion")
    }

    @Test func touchingMomentsBecomeClipsOfTheirOwnWithTheirNames() {
        var p = Project(name: "match", kind: .video)
        let c = TimelineClip(sourceID: UUID(), sourceStart: MediaTime(seconds: 0), sourceEnd: MediaTime(seconds: 100), name: "Full match.mp4")
        p.timeline = [c]
        func found(_ a: Double, _ b: Double) -> HighlightFound {
            var h = HighlightFound(clipID: c.id, source: TimeSpan(start: MediaTime(seconds: a), end: MediaTime(seconds: b)),
                                   timeline: TimeSpan(start: MediaTime(seconds: a), end: MediaTime(seconds: b)), score: 1)
            h.chosen = true
            return h
        }
        let a = found(10, 20), b = found(20, 30), d = found(50, 55)
        TimelineCuts.keepHighlights(&p, [a, b, d], clips: [c.id], ripple: true, names: [a.id: "Goal 0-1", b.id: "Replay", d.id: "Set piece 1"])
        #expect(p.timeline.map(\.name) == ["Goal 0-1", "Replay", "Set piece 1"], "\(p.timeline.map(\.name))")
        #expect(abs(p.timeline.reduce(0) { $0 + $1.duration.seconds } - 25) < 0.01)
    }
}

struct SetPieceCrowdTests {
    @Test func aCrowdedSetPieceIsDangerousAndAGoalKickIsNot() {
        let n = 1500
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { _ in -25 }, people: (0..<n).map { _ in 0.02 })
        for st in [60.0, 160.0] { for i in 0..<n where s.time(i) >= st && s.time(i) < st + 8 { s.motion[i] = 0.006 }
                                  for i in 0..<n where s.time(i) >= st + 8 && s.time(i) < st + 10 { s.motion[i] = 0.15 } }
        let kicks = HighlightFinder.setPieceKicks(s)
        #expect(kicks.count == 2)
        s.kickCrowd = [kicks[0]: 3, kicks[1]: 9]
        let m = HighlightFinder.moments(s).filter(\.setPiece)
        #expect(m.first { $0.start < 70 }?.event == nil, "a goal kick (3 people) is only a suggestion")
        #expect(m.first { $0.start > 150 }?.event == .setPiece, "a free kick with a wall (9 people) is kept")
    }
}

struct ReplayedSetPieceTests {
    @Test func aReplayedFreeKickIsCalledOneAndKeepsItsSettingUp() {
        // Play, a free kick set up from 92 s and kicked at 100 s, its replay opening at 106 s (graphic shown twice, 8 s apart).
        let n = 1500
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { _ in -25 }, people: (0..<n).map { _ in 0.02 })
        let field: [UInt8] = (0..<432).map { i in UInt8([90, 110, 70][i % 3] + (i / 3) % 7) }
        let green: [UInt8] = (0..<432).map { i in UInt8([20, 220, 60][i % 3]) }
        let graphics = [106.0, 114.2, 200, 208.2, 250, 258.2]
        s.thumbs = (0..<n).map { i in graphics.contains { s.time(i) >= $0 && s.time(i) < $0 + 1.2 } ? green : field }
        for g in graphics { for i in 0..<n where s.time(i) >= g && s.time(i) < g + 1.2 { s.motion[i] = 0.3 } }
        for i in 0..<n where s.time(i) >= 92 && s.time(i) < 100 { s.motion[i] = 0.006 }
        for i in 0..<n where s.time(i) >= 100 && s.time(i) < 102 { s.motion[i] = 0.15 }
        s.kickCrowd = [100: 9]
        let m = HighlightFinder.moments(s)
        let fk = m.first { $0.replayed && $0.start < 106 && $0.end > 106 }
        #expect(fk?.setPiece == true && fk?.event == .setPiece, "\(String(describing: fk))")
        #expect(fk.map { $0.start <= 94.01 } == true, "the setting up (6 s before the kick) is in: \(String(describing: fk))")
        #expect(m.filter { $0.replayed && $0.start > 150 }.allSatisfy { $0.setPiece == false }, "a replay with no set piece before it stays a dangerous moment")
        #expect(m.filter(\.setPiece).count == 1, "the free kick is not there twice")
    }
}

struct FarFreeKickTests {
    /// The free kick at 15:57 of the maintainer's match, as measured (change per second, 937–962 s): players walking to the wall
    /// stir the picture now and then, and the kick, filmed from far off, moves it only a little.
    @Test func aFreeKickFilmedFromFarIsFound() {
        let measured: [Double] = [0.019, 0.015, 0.017, 0.026, 0.023, 0.013, 0.012, 0.011, 0.012, 0.011, 0.011, 0.031, 0.016, 0.013, 0.022,
                                  0.025, 0.022, 0.016, 0.009, 0.008, 0.009, 0.008, 0.013, 0.028, 0.050, 0.031, 0.017]
        // A minute of ordinary play before and after (the clip's usual change about 0.03).
        let play = (0..<60).map { 0.03 + 0.01 * sin(Double($0) * 1.1) }
        let perSecond = play + measured + play
        let motion = perSecond.flatMap { Array(repeating: $0, count: 5) }
        let s = HighlightSignals(start: 877, step: 0.2, motion: motion, people: motion.map { _ in 0.02 })
        let kicks = HighlightFinder.setPieceKicks(s)
        #expect(kicks.contains { $0 >= 955 && $0 <= 961 }, "the kick at about 957–960 s: \(kicks)")
    }
}

struct FarCornerTests {
    /// The corner at 19:58 of the maintainer's match, as measured (1186–1215 s): a replay, the camera still on the corner while the
    /// teams wait (Vision finds nobody in the whole night picture), the kick at about 1203 s.
    @Test func aCornerWithNobodyFoundInTheWholePictureIsFound() {
        let measured: [Double] = [0.025, 0.035, 0.027, 0.031, 0.045, 0.086, 0.152, 0.111, 0.011, 0.010, 0.012, 0.007, 0.011, 0.012, 0.010,
                                  0.010, 0.010, 0.010, 0.064, 0.056, 0.012, 0.016, 0.036, 0.048, 0.060, 0.033, 0.052, 0.076, 0.041, 0.037]
        let play = (0..<60).map { 0.03 + 0.01 * sin(Double($0) * 1.1) }
        let motion = (play + measured + play).flatMap { Array(repeating: $0, count: 5) }
        let s = HighlightSignals(start: 1126, step: 0.2, motion: motion, people: motion.map { _ in 0 })
        let kicks = HighlightFinder.setPieceKicks(s)
        #expect(kicks.contains { $0 >= 1201 && $0 <= 1206 }, "the corner kicked at about 1203 s: \(kicks)")
    }
}

struct ManySetPiecesTests {
    @Test func everyCrowdedSetPieceIsKeptHoweverMany() {
        let n = 3000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { _ in -25 }, people: (0..<n).map { _ in 0.02 })
        let stops = stride(from: 30.0, to: 560, by: 60).map { $0 }        // nine free kicks
        for st in stops {
            for i in 0..<n where s.time(i) >= st && s.time(i) < st + 8 { s.motion[i] = 0.006 }
            for i in 0..<n where s.time(i) >= st + 8 && s.time(i) < st + 11 { s.motion[i] = 0.15 }
        }
        let kicks = HighlightFinder.setPieceKicks(s)
        #expect(kicks.count == stops.count, "\(kicks)")
        s.kickCrowd = Dictionary(uniqueKeysWithValues: kicks.map { ($0, 9) })
        let kept = HighlightFinder.moments(s).filter { $0.event == .setPiece }
        #expect(kept.count == stops.count, "all nine kept, not six: \(kept.count)")
    }
}

struct ClockPiecesTests {
    @Test func aPeriodReadInPiecesIsOnePeriod() {
        var c = ClockReader()
        func look(_ v: Int, _ t: Double) { c.add([(String(format: "%02d:%02d", v / 60, v % 60), 0.1, 0.12)], at: t) }
        // Kick-off at 1410 (clock standing at 00:00 before), the board hidden from 1525 to 1560 (a replay), then the half goes on to
        // 35:00; half-time; a second half from 35:00 at 4215.
        var t = 1380.0
        while t < 3520 {
            if t >= 1525 && t < 1560 { t += 10; continue }
            look(t < 1410 ? 0 : Int(t - 1410), t); t += 10
        }
        t = 4215
        while t < 6300 { look(2100 + Int(t - 4215), t); t += 10 }
        let p = c.periods()
        #expect(p.count == 2, "\(p)")
        #expect(abs((p.first?.kickoff ?? 0) - 1410) <= 1 && (p.first?.end ?? 0) > 3500, "\(p)")
    }
}

struct RealClockLooksTests {
    /// With MACPLAYER_CLOCK_LOOKS=<file of "seconds<TAB>mm:ss" lines>: the periods read from a real match's clock (printed, not a check).
    @Test func periodsOfARealMatch() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPLAYER_CLOCK_LOOKS"] else { return }
        var c = ClockReader()
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t"); guard f.count == 2, let t = Double(f[0]) else { continue }
            c.add([(String(f[1]), 0.1, 0.12)], at: t)
        }
        print("REAL PERIODS", c.periods().map { String(format: "%.0f–%.0f%@", $0.kickoff, $0.end, $0.kickoffSeen ? "" : "(late)") }.joined(separator: " "))
    }
}

struct GoalCallTests {
    @Test func withoutAReplayTheGoalIsWhereItIsCalled() {
        // A broadcast with no replay graphic: the ball goes in at 220 s, the call (commentator and goal sound, -4 dB against
        // -25 dB) at 230 s, the scoreboard changes at 250 s; celebrations (close-ups, much motion) until 290 s.
        let n = 2000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { -25 + 2 * sin(Double($0) * 0.7) })
        for i in 0..<n where s.time(i) >= 230 && s.time(i) < 233 { s.loudness[i] = -4 }
        for i in 0..<n where s.time(i) >= 250 && s.time(i) < 290 { s.motion[i] = 0.12 }
        s.goals = [ScoreChange(from: (0, 0), to: (0, 1), lastOld: 240, firstNew: 250)]
        let goal = HighlightFinder.moments(s).first { $0.goal == "0-1" }
        #expect(goal.map { $0.start <= 212 && $0.end >= 236 && $0.end <= 240 } == true, "the attack, the goal and the call, not only the cheering: \(String(describing: goal))")
        #expect(HighlightFinder.loudestCall(HighlightSignals(start: 0, step: 0.2, motion: [Double](repeating: 0, count: 500), loudness: [Double](repeating: -20, count: 500)), from: 0, to: 100) == nil, "no call in a steady sound")
    }

    @Test func aLateCallStillHasTheLiveGoal() {
        // The VSC case: the ball goes in at 600 s, a replay plays, and the "GOAL" call comes 50 s later, at 650 s.
        let n = 4000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { -25 + 2 * sin(Double($0) * 0.7) })
        for i in 0..<n where s.time(i) >= 650 && s.time(i) < 653 { s.loudness[i] = -4 }
        s.goals = [ScoreChange(from: (0, 0), to: (0, 1), lastOld: 640, firstNew: 655)]
        let goal = HighlightFinder.moments(s).first { $0.goal == "0-1" }
        #expect(goal.map { $0.start <= 595 && $0.end >= 656 } == true, "the live goal 50 s before the call is in: \(String(describing: goal))")
    }

    @Test func aLoneReplayGraphicKeepsTheLiveActionBeforeIt() {
        // A replay graphic seen only once (at 300 s; the broadcast's logo is small, so its other showing was missed): the action
        // shown again happened up to ~20 s before it.
        let n = 2500
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { _ in -25 })
        let field: [UInt8] = (0..<432).map { i in UInt8([90, 110, 70][i % 3] + (i / 3) % 7) }
        let green: [UInt8] = (0..<432).map { i in UInt8([20, 220, 60][i % 3]) }
        let shown = [100.0, 200.0, 300.0, 400.0]
        s.thumbs = (0..<n).map { i in shown.contains { s.time(i) >= $0 && s.time(i) < $0 + 1.2 } ? green : field }
        for g in shown { for i in 0..<n where s.time(i) >= g && s.time(i) < g + 1.2 { s.motion[i] = 0.4 } }
        let lone = HighlightFinder.replays(s).filter { $0.end - $0.start < 4 }
        #expect(!lone.isEmpty, "\(HighlightFinder.replays(s))")
        let m = HighlightFinder.moments(s).filter(\.replayed)
        for r in lone {
            #expect(m.contains { $0.start <= r.start - 20 && $0.end >= r.start + 2 && $0.end <= r.start + 5 }, "24 s before a lone graphic to 4 s after: \(r) \(m)")
        }
    }
}

struct ManyCamerasTests {
    @Test func aMultiCameraBroadcastKeepsOnlySetPiecesItReplays() {
        // 10 minutes; 60 shot changes (a multi-camera broadcast); two set pieces, both crowded; a replay graphic shown twice right
        // after the second only.
        let n = 3000
        var s = HighlightSignals(start: 0, step: 0.2, motion: (0..<n).map { 0.03 + 0.008 * sin(Double($0) * 1.3) },
                                 loudness: (0..<n).map { _ in -25 }, people: (0..<n).map { _ in 0.02 })
        for c in stride(from: 5, to: n, by: 50) where !(c > 380 && c < 470) && !(c > 1380 && c < 1520) { s.motion[c] = 0.5 }
        for st in [80.0, 280.0] {
            for i in 0..<n where s.time(i) >= st && s.time(i) < st + 8 { s.motion[i] = 0.006 }
            for i in 0..<n where s.time(i) >= st + 8 && s.time(i) < st + 11 { s.motion[i] = 0.15 }
        }
        let field: [UInt8] = (0..<432).map { i in UInt8([90, 110, 70][i % 3] + (i / 3) % 7) }
        let green: [UInt8] = (0..<432).map { i in UInt8([20, 220, 60][i % 3]) }
        let graphics = [300.0, 310.0, 400.0, 410.0, 500.0, 510.0]
        s.thumbs = (0..<n).map { i in graphics.contains { s.time(i) >= $0 && s.time(i) < $0 + 1.2 } ? green : field }
        for g in graphics { for i in 0..<n where s.time(i) >= g && s.time(i) < g + 1.2 { s.motion[i] = 0.4 } }
        let kicks = HighlightFinder.setPieceKicks(s)
        s.kickCrowd = Dictionary(uniqueKeysWithValues: kicks.map { ($0, 10) })
        #expect(HighlightFinder.cuts(motion: s.motion).count >= 30)
        let m = HighlightFinder.moments(s).filter(\.setPiece)
        #expect(m.first { $0.start < 100 }?.event == nil, "not replayed: a suggestion, however many people")
        #expect(m.contains { $0.start > 270 && $0.start < 300 && $0.event == .setPiece }, "replayed by the broadcast: kept")
    }
}
