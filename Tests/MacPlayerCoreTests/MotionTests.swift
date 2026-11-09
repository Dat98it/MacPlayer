import Foundation
import Testing
@testable import MacPlayerCore

struct MotionTests {
    @Test func noKeyframesLeaveThePictureAlone() {
        #expect(Motion.state([], at: 3) == nil)
    }

    @Test func itHoldsBeforeAndAfterAndMovesInAStraightLineBetween() throws {
        let k = [MotionKeyframe(time: 1, scale: 1), MotionKeyframe(time: 3, scale: 2)]
        #expect(Motion.state(k, at: 0)?.scale == 1 && Motion.state(k, at: 9)?.scale == 2)
        let mid = try #require(Motion.state(k, at: 2))
        #expect(abs(mid.scale - 1.5) < 1e-9, "half way in time is half way in value")
        let quarter = try #require(Motion.state(k, at: 1.5))
        #expect(abs(quarter.scale - 1.25) < 1e-9, "a quarter of the way in time is a quarter of the way in value")
    }

    @Test func theViewNeverLeavesThePicture() {
        let s = MotionState(scale: 2, x: 0.05, y: 0.99).clamped()
        #expect(s.x == 0.25 && s.y == 0.75)
        #expect(MotionState(scale: 0.2, x: 0.1, y: 0.9).clamped() == .still.clamped() || MotionState(scale: 0.2, x: 0.1, y: 0.9).clamped().scale == 1)
        #expect(MotionState(scale: 50, x: 0.5, y: 0.5).clamped().scale == 8)
        let k = [MotionKeyframe(time: 0, scale: 2, x: 0), MotionKeyframe(time: 1, scale: 2, x: 1)]
        #expect(Motion.state(k, at: 0)?.x == 0.25 && Motion.state(k, at: 1)?.x == 0.75, "a pan across a zoomed picture stops at its edges")
    }

    @Test func everyPresetStartsAtTimeZeroAndEndsAtTheClipsEnd() {
        for p in Motion.Preset.allCases {
            let k = Motion.keyframes(for: p, duration: 8)
            #expect(k.first?.time == 0 && k.last?.time == 8 && k.count >= 2, "\(p)")
            #expect(k.allSatisfy { $0.scale >= 1 })
        }
        #expect(Motion.keyframes(for: .zoomIn, duration: 0).last!.time >= 0.1, "a zero-length clip still gives usable keyframes")
    }

    @Test func settingAKeyframeAddsOrUpdatesNearTheSameTime() {
        var k = Motion.keyframes(for: .zoomIn, duration: 4)
        k = Motion.setting(k, at: 2, to: MotionState(scale: 1.8, x: 0.4, y: 0.5))
        #expect(k.count == 3 && k.map(\.time) == [0, 2, 4])
        k = Motion.setting(k, at: 2.01, to: MotionState(scale: 1.1, x: 0.5, y: 0.5))
        #expect(k.count == 3 && abs(k[1].scale - 1.1) < 1e-9, "within a frame it updates")
        #expect(Motion.setting([], at: -5, to: .still).first?.time == 0, "never before the start")
    }

    @Test func shiftingKeepsWhatThePictureDoesFromTheNewStart() throws {
        let k = [MotionKeyframe(time: 0, scale: 1), MotionKeyframe(time: 4, scale: 2)]
        let cut = Motion.shifted(k, by: -2)                      // the clip now starts 2 s in
        #expect(cut.first?.time == 0 && abs(cut.first!.scale - 1.5) < 1e-9 && cut.last?.time == 2 && cut.last?.scale == 2)
        for t in [0.0, 0.7, 1.4, 2.0] {
            #expect(abs(Motion.state(cut, at: t)!.scale - Motion.state(k, at: t + 2)!.scale) < 1e-9, "same picture at \(t)")
        }
        let later = Motion.shifted(k, by: 1)
        #expect(later.map(\.time) == [1, 5])
    }

    @Test func aLookWithMotionCountsAsAnEditAndSurvivesSaving() throws {
        var look = VideoLook(); look.motion = Motion.keyframes(for: .zoomIn, duration: 3)
        #expect(look.changesPicture && !look.isNeutral)
        #expect(try JSONDecoder().decode(VideoLook.self, from: JSONEncoder().encode(look)) == look)
    }
}
