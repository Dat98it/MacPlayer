import Foundation
import Testing
@testable import MacPlayerCore

struct SpeedRampTests {
    let src = UUID()
    func clip(_ a: Double, _ b: Double, speed: Double = 1) -> TimelineClip {
        var c = TimelineClip(sourceID: src, sourceStart: MediaTime(seconds: a), sourceEnd: MediaTime(seconds: b), name: "C")
        c.look.speed = speed
        return c
    }

    @Test func everyCurveStaysInASaneRangeAndHasItsShape() {
        for p in SpeedRamp.Preset.allCases {
            for i in 0...20 {
                let s = SpeedRamp.speed(p, at: Double(i) / 20)
                #expect(s >= 0.15 && s <= 3.1, "\(p) at \(i): \(s)")
            }
        }
        #expect(SpeedRamp.speed(.montage, at: 0.5) < SpeedRamp.speed(.montage, at: 0), "montage is slowest in the middle")
        #expect(SpeedRamp.speed(.bullet, at: 0.5) < 0.3, "bullet time is slow motion")
        #expect(SpeedRamp.speed(.hero, at: 0.5) > SpeedRamp.speed(.hero, at: 0), "hero bursts forward in the middle")
        #expect(SpeedRamp.speed(.flashIn, at: 0) < SpeedRamp.speed(.flashIn, at: 1) && SpeedRamp.speed(.flashOut, at: 0) > SpeedRamp.speed(.flashOut, at: 1))
    }

    @Test func aRampCutsTheClipIntoPartsThatCoverItExactly() throws {
        var clips = [clip(2, 12), clip(0, 5)]
        let ids = try #require(TimelineEditor.applySpeedRamp(&clips, clipID: clips[0].id, preset: .montage, parts: 10))
        #expect(ids.count == 10 && clips.count == 11)
        let parts = Array(clips[0..<10])
        #expect(parts.first?.sourceStart == MediaTime(seconds: 2) && parts.last?.sourceEnd == MediaTime(seconds: 12))
        for (a, b) in zip(parts, parts.dropFirst()) { #expect(a.sourceEnd == b.sourceStart, "no gap and no overlap") }
        #expect(parts.map(\.look.speed).min()! < 1 && parts.map(\.look.speed).max()! > 1)
        #expect(clips[10].sourceEnd == MediaTime(seconds: 5), "the next clip is untouched")
        let played = parts.reduce(0.0) { $0 + $1.duration.seconds }
        let expected = SpeedRamp.playedLength(SpeedRamp.parts(.montage, sourceLength: 10, count: 10))
        #expect(abs(played - expected) < 0.01, "the timeline length is what the curve says: \(played) vs \(expected)")
    }

    @Test func aRampMultipliesTheClipsOwnSpeedAndKeepsItsLook() throws {
        var c = clip(0, 10, speed: 2); c.look.effects.filter = .noir
        var clips = [c]
        TimelineEditor.applySpeedRamp(&clips, clipID: c.id, preset: .flashIn, parts: 5)
        #expect(clips.allSatisfy { $0.look.effects.filter == .noir })
        #expect(clips.first!.look.speed < clips.last!.look.speed)
        #expect(abs(clips.first!.look.speed - 2 * SpeedRamp.speed(.flashIn, at: 0.1)) < 1e-9)
    }

    @Test func aClipThatIsTooShortIsRefused() {
        var clips = [clip(0, 1)]
        #expect(TimelineEditor.applySpeedRamp(&clips, clipID: clips[0].id, preset: .bullet, parts: 10) == nil && clips.count == 1)
    }

    @Test func aFreezeFrameSitsBetweenTheTwoHalves() throws {
        var clips = [clip(0, 10)]
        let id = try #require(TimelineEditor.freezeFrame(&clips, clipID: clips[0].id, atSourceTime: MediaTime(seconds: 4), frameDuration: MediaTime(value: 1, timescale: 30), hold: 3))
        #expect(clips.count == 3 && clips[1].id == id)
        #expect(clips[0].sourceEnd == MediaTime(seconds: 4) && clips[2].sourceStart == MediaTime(seconds: 4))
        #expect(clips[1].audio.muted && abs(clips[1].duration.seconds - 3) < 0.01, "held for 3 s: \(clips[1].duration.seconds)")
        #expect(clips[1].sourceEnd - clips[1].sourceStart == MediaTime(value: 1, timescale: 30), "one frame")
        let total = clips.reduce(0.0) { $0 + $1.duration.seconds }
        #expect(abs(total - 13) < 0.02, "the video is 3 s longer: \(total)")
    }

    @Test func aFreezeAtTheFirstFrameGoesInFrontAndTheClipKeepsItsId() throws {
        var c = clip(0, 6); c.look.transitionIn = ClipTransition(kind: .dissolve, duration: 1)
        var clips = [c]
        TimelineEditor.freezeFrame(&clips, clipID: c.id, atSourceTime: .zero, frameDuration: MediaTime(value: 1, timescale: 30), hold: 2)
        #expect(clips.count == 2 && clips[1].id == c.id && clips[1].sourceStart == .zero)
        #expect(clips[0].look.transitionIn != nil && clips[1].look.transitionIn == nil, "the clip's arrival now belongs to the frozen part")
    }

    @Test func aFreezeOutsideTheClipOrOfNoLengthIsRefused() {
        var clips = [clip(0, 6)]
        #expect(TimelineEditor.freezeFrame(&clips, clipID: clips[0].id, atSourceTime: MediaTime(seconds: 7), frameDuration: MediaTime(value: 1, timescale: 30), hold: 2) == nil)
        #expect(TimelineEditor.freezeFrame(&clips, clipID: clips[0].id, atSourceTime: MediaTime(seconds: 3), frameDuration: MediaTime(value: 1, timescale: 30), hold: 0) == nil)
        #expect(clips.count == 1)
    }

    @Test func splittingAndTrimmingKeepTheZoomAnimationInStep() {
        var c = clip(0, 8)
        c.look.motion = Motion.keyframes(for: .zoomIn, duration: 8)
        var clips = [c]
        TimelineEditor.split(&clips, clipID: c.id, atSourceTime: MediaTime(seconds: 4))
        #expect(abs((Motion.state(clips[1].look.motion, at: 0)?.scale ?? 0) - (Motion.state(c.look.motion, at: 4)?.scale ?? 1)) < 1e-9, "the second half starts where the first ended")
        #expect(abs((Motion.state(clips[1].look.motion, at: 4)?.scale ?? 0) - 1.35) < 1e-9)
        var t = [c]
        TimelineEditor.trim(&t, clipID: c.id, start: MediaTime(seconds: 2), sourceDuration: MediaTime(seconds: 20))
        #expect(abs((Motion.state(t[0].look.motion, at: 0)?.scale ?? 0) - (Motion.state(c.look.motion, at: 2)?.scale ?? 1)) < 1e-9, "trimming the start keeps the animation where it was")
    }
}
