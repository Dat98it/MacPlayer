import Foundation
import Testing
@testable import MacPlayerCore

/// 0.20: finding the beat in onset strength, and moving cuts onto beats.
struct BeatSyncTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 6000) }

    /// Onset strength with a hit every `period` seconds from `first`, a weaker off-beat, and some noise.
    private func onset(period: Double, first: Double, seconds: Double, hop: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let n = Int(seconds / hop)
        var o = (0..<n).map { _ in Float.random(in: 0...0.2, using: &rng) }
        var t = first
        while t < seconds { let i = Int((t / hop).rounded()); if i < n { o[i] += 1 }; let j = Int(((t + period / 2) / hop).rounded()); if j < n { o[j] += 0.3 }; t += period }
        return o
    }

    @Test(arguments: [(120.0, 0.25), (95.0, 0.4), (150.0, 0.1)])
    func theTempoAndBeatsOfASteadyPulseAreFound(bpm: Double, first: Double) throws {
        let hop = 256.0 / 11025, period = 60 / bpm
        let g = try #require(BeatTracker.track(onset: onset(period: period, first: first, seconds: 40, hop: hop), hop: hop))
        #expect(abs(g.bpm - bpm) < 2, "found \(g.bpm)")
        // Every beat lies on the pulse (within two frames).
        for t in g.times.dropFirst() {
            let off = (t - first).truncatingRemainder(dividingBy: period)
            #expect(min(abs(off), abs(period - off)) < hop * 2.5, "beat at \(t) is off the pulse by \(off)")
        }
        #expect(g.times.count >= Int(40 / period) - 3)
    }

    @Test func silenceAndNoiseHaveNoBeat() {
        let hop = 256.0 / 11025
        #expect(BeatTracker.track(onset: [Float](repeating: 0, count: 2000), hop: hop) == nil)
        #expect(BeatTracker.track(onset: [1, 2, 3], hop: hop) == nil)
    }

    /// Clips of 3.2 s, 2.7 s and 4.1 s; a song from 0 with beats every 0.5 s; a text over the second clip.
    private func project() -> Project {
        var p = Project(name: "Beat", kind: .video)
        let src = UUID()
        p.timeline = [TimelineClip(sourceID: src, sourceStart: s(0), sourceEnd: s(3.2)), TimelineClip(sourceID: src, sourceStart: s(10), sourceEnd: s(12.7)),
                      TimelineClip(sourceID: src, sourceStart: s(20), sourceEnd: s(24.1))]
        var song = SoundClip(name: "song", path: "/song.mp3", start: .zero, duration: s(30))
        song.beats = BeatGrid(bpm: 120, times: stride(from: 0.0, through: 60, by: 0.5).map { $0 })
        p.soundClips = [song]
        p.overlays = [TextOverlay(text: "over 2", start: s(3.5), end: s(5))]
        return p
    }

    @Test func beatsAreWhereTheSongIsOnTheTimeline() {
        var p = project()
        p.soundClips[0].start = s(1); p.soundClips[0].sourceStart = s(0.2); p.soundClips[0].duration = s(2)
        // File beats 0.5, 1.0, 1.5, 2.0 play from 0.2 s into the file, placed at 1 s: 1.3, 1.8, 2.3, 2.8.
        #expect(p.soundClips[0].timelineBeats.map { ($0.seconds * 10).rounded() / 10 } == [1.3, 1.8, 2.3, 2.8])
        #expect(BeatSync.timelineBeats(p, every: 2).count == 2)
        #expect(BeatSync.timelineBeats(p, every: 0).map { ($0.seconds * 100).rounded() / 100 } == [1.3, 1.55, 1.8, 2.05, 2.3, 2.55, 2.8], "half beats")
    }

    @Test func everyCutLandsOnABeatAndTheSongKeepsPlaying() {
        var p = project()
        let beats = BeatSync.timelineBeats(p)
        let n = BeatSync.fitClips(&p, beats: beats, sourceLimit: { _ in s(100) }, ripple: true, keep: p.soundClips[0].id)
        #expect(n == 3)
        var t = 0.0
        for c in p.timeline {
            t += c.duration.seconds
            #expect(abs((t * 2).rounded() - t * 2) < 0.002, "cut at \(t) is on a half second")
        }
        #expect(abs(p.timeline[0].duration.seconds - 3) < 0.002 && abs(p.timeline[1].duration.seconds - 2.5) < 0.002, "nearest beat: 3.2 → 3.0, 5.7 → 5.5")
        #expect(abs(p.soundClips[0].duration.seconds - 30) < 0.001 && p.soundClips[0].start == .zero, "the song is left as it was")
        #expect(abs(p.overlays[0].start.seconds - 3.3) < 0.002, "the text followed its picture (3.5 → 3.3)")
    }

    @Test func aClipIsNotMadeLongerThanItsSource() {
        var p = project()
        // Beats every 2 s: clip 1 (3.2 s, source can't grow) must end at 2.0 rather than 4.0.
        let beats = stride(from: 0.0, through: 30, by: 2).map { s($0) }
        BeatSync.fitClips(&p, beats: beats, sourceLimit: { $0.sourceEnd }, ripple: false)
        #expect(abs(p.timeline[0].duration.seconds - 2) < 0.002)
        #expect(p.overlays[0].start == s(3.5), "without following, nothing else moves")
    }

    @Test func markersGoOnBeatsOnce() {
        var p = project()
        let beats = BeatSync.timelineBeats(p, every: 4)
        #expect(BeatSync.addMarkers(&p, beats: beats, end: s(10)) == 6)
        #expect(BeatSync.addMarkers(&p, beats: beats, end: s(10)) == 0)
    }

    @Test func oldSoundsWithoutBeatsStillOpen() throws {
        let p = project()
        // What a 0.19 file holds: no beats key.
        var dict = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p.soundClips[0])) as? [String: Any])
        #expect(dict["beats"] != nil)
        dict["beats"] = nil
        let json = String(data: try JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
        #expect(try JSONDecoder().decode(SoundClip.self, from: Data(json.utf8)).beats == nil)
    }

    @Test func cutsFarFromTheSongAreLeftAlone() {
        // An hour-long clip under a two-minute song (a real project, 0.20): it must not be cut down to the song's last beat.
        var p = Project(name: "Long", kind: .video)
        p.timeline = [TimelineClip(sourceID: UUID(), sourceStart: s(0), sourceEnd: s(3600)), TimelineClip(sourceID: UUID(), sourceStart: s(0), sourceEnd: s(100))]
        var song = SoundClip(name: "song", path: "/s.m4a", start: .zero, duration: s(120))
        song.beats = BeatGrid(bpm: 120, times: stride(from: 0.0, through: 120, by: 0.5).map { $0 })
        p.soundClips = [song]
        let before = p.timeline
        #expect(BeatSync.fitClips(&p, beats: BeatSync.timelineBeats(p), sourceLimit: { $0.sourceEnd }, ripple: true, keep: song.id) == 0)
        #expect(p.timeline == before)
    }

    @Test func aSongThatSpeedsUpIsFollowed() throws {
        // 100 bpm for 30 s, then 130 bpm for 30 s.
        let hop = 256.0 / 11025
        var o = onset(period: 0.6, first: 0.2, seconds: 30, hop: hop)
        let late = onset(period: 60.0 / 130, first: 0.0, seconds: 30, hop: hop)
        o += late
        let g = try #require(BeatTracker.track(onset: o, hop: hop))
        func onPulse(_ t: Double) -> Bool {
            if t < 30 { let r = (t - 0.2).truncatingRemainder(dividingBy: 0.6); return min(abs(r), 0.6 - abs(r)) < hop * 2.5 }
            let p = 60.0 / 130, r = (t - 30).truncatingRemainder(dividingBy: p); return min(abs(r), p - abs(r)) < hop * 2.5
        }
        let early = g.times.filter { $0 > 2 && $0 < 26 }, after = g.times.filter { $0 > 34 && $0 < 58 }
        #expect(early.filter(onPulse).count >= early.count - 1 && early.count >= 36, "\(early.count) beats before the change")
        #expect(after.filter(onPulse).count >= after.count - 1 && after.count >= 48, "\(after.count) beats after the change")
    }
}
