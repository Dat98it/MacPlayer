import Foundation
import Testing
@testable import MacPlayerCore

struct EasingAnimationTests {
    @Test func everyEasingStartsAtZeroAndEndsAtOne() {
        for e in Easing.allCases {
            #expect(abs(e.apply(0)) < 1e-9 && abs(e.apply(1) - 1) < 1e-9, "\(e)")
            #expect(e.apply(-3) == e.apply(0) && e.apply(5) == e.apply(1), "outside 0...1 it holds: \(e)")
        }
    }

    @Test func easeInStartsSlowEaseOutStartsFastAndTheMiddleIsBalanced() {
        #expect(Easing.easeIn.apply(0.3) < 0.3 && Easing.easeOut.apply(0.3) > 0.3)
        #expect(abs(Easing.easeInOut.apply(0.5) - 0.5) < 1e-9)
        #expect(Easing.easeInOut.apply(0.2) < 0.2 && Easing.easeInOut.apply(0.8) > 0.8)
        for e in [Easing.easeIn, .easeOut, .easeInOut] {
            var last = -1.0
            for i in 0...100 { let v = e.apply(Double(i) / 100); #expect(v >= last - 1e-12, "\(e) never goes back"); last = v }
        }
    }

    @Test func overshootGoesPastOneAndBounceStaysInside() {
        #expect((0..<100).contains { Easing.overshoot.apply(Double($0) / 100) > 1.02 })
        #expect((0...100).allSatisfy { Easing.bounce.apply(Double($0) / 100) <= 1.0001 })
    }

    // MARK: Keyframes use it

    func layer(_ keyframes: [OverlayKeyframe], duration: Double = 4) -> OverlayClip {
        OverlayClip(name: "x", kind: .image(path: "p", bookmark: nil), start: .zero, duration: MediaTime(seconds: duration), keyframes: keyframes)
    }

    @Test func aLayerKeyframesEasingShapesTheStretchThatLeavesIt() {
        var a = OverlayKeyframe(time: .zero, centerX: 0, centerY: 0.5, width: 0.3, opacity: 1)
        let b = OverlayKeyframe(time: MediaTime(seconds: 2), centerX: 1, centerY: 0.5, width: 0.3, opacity: 1)
        let straight = layer([a, b]).state(at: MediaTime(seconds: 0.5))!.centerX
        a.easing = .easeIn
        let slow = layer([a, b]).state(at: MediaTime(seconds: 0.5))!.centerX
        a.easing = .easeOut
        let fast = layer([a, b]).state(at: MediaTime(seconds: 0.5))!.centerX
        #expect(abs(straight - 0.25) < 1e-6 && slow < straight && fast > straight)
    }

    @Test func aLayerCanTurnBetweenKeyframes() {
        let a = OverlayKeyframe(time: .zero, centerX: 0.5, centerY: 0.5, width: 0.3, opacity: 1, rotation: 0)
        let b = OverlayKeyframe(time: MediaTime(seconds: 2), centerX: 0.5, centerY: 0.5, width: 0.3, opacity: 1, rotation: 90)
        #expect(abs(layer([a, b]).state(at: MediaTime(seconds: 1))!.rotation - 45) < 1e-6)
        var plain = layer([]); plain.transform.rotation = 30
        #expect(plain.state(at: MediaTime(seconds: 1))!.rotation == 30, "a layer without keyframes keeps its base turn")
    }

    @Test func aLayerArrivesAndLeavesWithAnAnimation() {
        var c = layer([])
        c.transform.centerX = 0.5; c.transform.width = 0.4
        c.animationIn = ElementAnimation(kind: .slideLeft, duration: 1)
        c.animationOut = ElementAnimation(kind: .zoom, duration: 1)
        let start = c.state(at: MediaTime(seconds: 0.01))!, middle = c.state(at: MediaTime(seconds: 2))!, endish = c.state(at: MediaTime(seconds: 3.95))!
        #expect(start.centerX > 0.6 && start.opacity < 0.3, "arrives from the right, nearly invisible")
        #expect(middle.centerX == 0.5 && middle.opacity == 1 && middle.width == 0.4, "in the middle nothing is moved")
        #expect(endish.width > 0.4 && endish.opacity < 0.3, "leaving: bigger and fading")
        let settled = c.state(at: MediaTime(seconds: 1.0))!
        #expect(abs(settled.centerX - 0.5) < 1e-6 && settled.opacity == 1, "the arrival is over after its time")
    }

    @Test func editingShowsTheLayerWithoutItsArrivalMoves() {
        var c = layer([])
        c.animationIn = ElementAnimation(kind: .slideLeft, duration: 1); c.transform.centerX = 0.4
        let s = OverlayEditor.editableState(c, at: .zero)
        #expect(s.centerX == 0.4 && s.opacity == 1, "what a slider changes is the layer's own place, not a frame of its animation")
    }

    @Test func settingAKeyframeKeepsItsEasingAndItsTurn() {
        var c = layer([OverlayKeyframe(time: .zero, centerX: 0.1, centerY: 0.5, width: 0.3, opacity: 1, rotation: 0, easing: .bounce)])
        OverlayEditor.setKeyframe(&c, at: .zero, to: OverlayState(centerX: 0.9, centerY: 0.5, width: 0.3, opacity: 1, rotation: 45))
        #expect(c.keyframes.count == 1 && c.keyframes[0].centerX == 0.9 && c.keyframes[0].rotation == 45 && c.keyframes[0].easing == .bounce)
    }

    @Test func zoomAndMoveKeyframesCanTurnAndEase() {
        var a = MotionKeyframe(time: 0, scale: 1, rotation: 0), b = MotionKeyframe(time: 2, scale: 1, rotation: 10)
        #expect(abs(Motion.state([a, b], at: 1)!.rotation - 5) < 1e-9)
        a.easing = .easeIn
        #expect(Motion.state([a, b], at: 0.5)!.rotation < 2.5)
        b.rotation = 0
        #expect(Motion.state([a, b], at: 1)!.rotation == 0)
    }

    @Test func oldProjectsOpenWithStraightUnturnedKeyframes() throws {
        let id = UUID().uuidString
        let overlay = #"{"id":"\#(id)","time":{"value":60,"timescale":600},"centerX":0.5,"centerY":0.5,"width":0.3,"opacity":1}"#.data(using: .utf8)!
        let k = try JSONDecoder().decode(OverlayKeyframe.self, from: overlay)
        #expect(k.rotation == 0 && k.easing == .linear && k.centerX == 0.5)
        let motion = #"{"id":"\#(id)","time":1.5,"scale":2,"x":0.5,"y":0.5}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(MotionKeyframe.self, from: motion)
        #expect(m.rotation == 0 && m.easing == .linear && m.scale == 2)
        let element = #"{"id":"\#(id)","time":1,"x":0.5,"y":0.5,"scale":1,"rotation":0,"opacity":1}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ElementKeyframe.self, from: element).easing == .linear)
        var withNew = OverlayKeyframe(time: MediaTime(seconds: 1), centerX: 0.1, centerY: 0.2, width: 0.3, opacity: 0.4, rotation: 12, easing: .overshoot)
        withNew.id = UUID()
        #expect(try JSONDecoder().decode(OverlayKeyframe.self, from: try JSONEncoder().encode(withNew)) == withNew)
        let clipJSON = try JSONEncoder().encode(layer([]))
        #expect(try JSONDecoder().decode(OverlayClip.self, from: clipJSON).animationIn == nil)
    }
}

struct VolumeCurveTests {
    @Test func theCurveIsStraightBetweenPointsAndHeldAtTheEnds() {
        let pts = [VolumePoint(time: 1, gainDB: -10), VolumePoint(time: 3, gainDB: 0)]
        #expect(VolumeCurve.gainDB(pts, at: 0) == -10 && VolumeCurve.gainDB(pts, at: 5) == 0)
        #expect(abs(VolumeCurve.gainDB(pts, at: 2) + 5) < 1e-9)
        #expect(VolumeCurve.gainDB([], at: 2) == 0)
    }

    @Test func pointsAreTidied() {
        let c = VolumeCurve.cleaned([VolumePoint(time: 9, gainDB: 50), VolumePoint(time: -1, gainDB: -99), VolumePoint(time: 0.01, gainDB: -5)], length: 4)
        #expect(c.count == 2 && c[0].time == 0.01 && c[0].gainDB == -5, "two points almost together become one (the later wins)")
        #expect(c[1].time == 4 && c[1].gainDB == 12)
    }

    @Test func aPieceOfTheSoundKeepsTheVolumeItHadThere() {
        let pts = [VolumePoint(time: 0, gainDB: -20), VolumePoint(time: 4, gainDB: 0)]
        let shifted = VolumeCurve.shifted(pts, by: 2)
        #expect(abs(shifted[0].time) < 1e-9 && abs(shifted[0].gainDB + 10) < 1e-9, "starts at what the volume was 2 s in")
        #expect(abs(shifted.last!.time - 2) < 1e-9 && shifted.last!.gainDB == 0)
        var clip = SoundClip(name: "m", path: "/x", start: .zero, duration: MediaTime(seconds: 4))
        clip.volumeCurve = pts
        let part = clip.cropped(to: TimeSpan(start: MediaTime(seconds: 2), end: MediaTime(seconds: 4)))!
        #expect(abs(VolumeCurve.gainDB(part.volumeCurve!, at: 0) + 10) < 1e-6)
    }

    @Test func theEnvelopeMultipliesTheDrawnCurveIntoTheGain() {
        let plain = VolumeEnvelope.points(start: 0, end: 4, gain: 1, fadeIn: 0, fadeOut: 0)
        let drawn = VolumeEnvelope.points(start: 0, end: 4, gain: 1, fadeIn: 0, fadeOut: 0, curve: [(time: 0, gain: 1), (time: 2, gain: 0.25), (time: 4, gain: 1)])
        #expect(plain.allSatisfy { $0.gain == 1 })
        #expect(abs(VolumeEnvelope.gain(at: 2, in: drawn) - 0.25) < 1e-6, "dips to a quarter in the middle")
        #expect(abs(VolumeEnvelope.gain(at: 0, in: drawn) - 1) < 1e-6)
        let fadedAndDrawn = VolumeEnvelope.points(start: 0, end: 4, gain: 2, fadeIn: 1, fadeOut: 0, curve: [(time: 0, gain: 0.5), (time: 4, gain: 0.5)])
        #expect(abs(VolumeEnvelope.gain(at: 2, in: fadedAndDrawn) - 1) < 1e-6, "gain 2 × curve 0.5 = 1")
    }

    @Test func oldSoundsOpenWithNoCurveAndNoEffect() throws {
        var c = SoundClip(name: "m", path: "/x", start: .zero, duration: MediaTime(seconds: 4))
        #expect(c.volumeCurve == nil && c.fx == nil)
        c.volumeCurve = [VolumePoint(time: 1, gainDB: -6)]; c.fx = SoundFX.Preset.hall.fx
        #expect(try JSONDecoder().decode(SoundClip.self, from: try JSONEncoder().encode(c)) == c)
    }
}
