import Foundation
import Testing
@testable import MacPlayerCore

struct ElementTests {
    func text(_ a: Double = 0, _ b: Double = 5) -> TextOverlay { TextOverlay(text: "Hi", start: MediaTime(seconds: a), end: MediaTime(seconds: b), x: 0.5, y: 0.5, fade: 0) }

    @Test func anElementIsOnlyThereBetweenItsStartAndEnd() {
        let o = text(2, 4)
        #expect(ElementAnimator.state(of: o, at: 1.9) == nil && ElementAnimator.state(of: o, at: 4.0) == nil)
        #expect(ElementAnimator.state(of: o, at: 2.0) != nil && ElementAnimator.state(of: o, at: 3.9) != nil)
    }

    @Test func thePlainFadeStillWorksAtBothEnds() {
        var o = text(0, 4); o.fade = 1
        #expect(abs(ElementAnimator.state(of: o, at: 0.5)!.alpha - 0.5) < 1e-9)
        #expect(ElementAnimator.state(of: o, at: 2)!.alpha == 1)
        #expect(abs(ElementAnimator.state(of: o, at: 3.75)!.alpha - 0.25) < 1e-9)
    }

    @Test func eachKindOfAnimationMovesTheElementAndEndsWhereItBelongs() throws {
        for kind in ElementAnimationKind.allCases where kind != .none {
            var o = text(0, 5); o.animationIn = ElementAnimation(kind: kind, duration: 1)
            let during = try #require(ElementAnimator.state(of: o, at: 0.25)), after = try #require(ElementAnimator.state(of: o, at: 2))
            #expect(after == ElementState(x: 0.5, y: 0.5, scale: 1, rotation: 0, alpha: 1, reveal: 1), "\(kind) has finished and left nothing behind")
            #expect(during != after, "\(kind) is doing something at 0.25 s")
        }
    }

    @Test func slidesComeFromTheRightDirection() throws {
        func at(_ k: ElementAnimationKind) -> ElementState { var o = text(); o.animationIn = ElementAnimation(kind: k, duration: 1); return ElementAnimator.state(of: o, at: 0.1)! }
        #expect(at(.slideUp).y > 0.5, "slide up starts below")
        #expect(at(.slideDown).y < 0.5, "slide down starts above")
        #expect(at(.slideLeft).x > 0.5, "slide left arrives from the right")
        #expect(at(.slideRight).x < 0.5)
    }

    @Test func leavingMirrorsArrivingAndPopOvershootsBeforeSettling() throws {
        var o = text(0, 5); o.animationOut = ElementAnimation(kind: .slideUp, duration: 1)
        #expect(ElementAnimator.state(of: o, at: 4.9)!.y < 0.5, "it leaves upwards")
        var p = text(); p.animationIn = ElementAnimation(kind: .pop, duration: 1)
        let sizes = stride(from: 0.05, through: 0.95, by: 0.05).map { ElementAnimator.state(of: p, at: $0)!.scale }
        #expect(sizes.first! < 0.6 && sizes.max()! > 1.0, "starts small and passes full size on the way: max \(sizes.max()!)")
    }

    @Test func theTypewriterRevealsMoreAndMoreOfTheText() {
        var o = text(); o.animationIn = ElementAnimation(kind: .typewriter, duration: 2)
        let r = [0.0, 0.5, 1.0, 1.5, 2.5].map { ElementAnimator.state(of: o, at: $0)!.reveal }
        #expect(r == [0, 0.25, 0.5, 0.75, 1])
    }

    @Test func keyframesMoveAndTurnTheElementInAStraightLine() throws {
        var o = text(10, 20)
        o.keyframes = [ElementKeyframe(time: 0, x: 0.2, y: 0.5, scale: 1, rotation: 0, opacity: 1), ElementKeyframe(time: 4, x: 0.8, y: 0.3, scale: 2, rotation: 90, opacity: 0.5)]
        let mid = try #require(ElementAnimator.state(of: o, at: 12))
        #expect(abs(mid.x - 0.5) < 1e-9 && abs(mid.y - 0.4) < 1e-9 && abs(mid.scale - 1.5) < 1e-9 && abs(mid.rotation - 45) < 1e-9 && abs(mid.alpha - 0.75) < 1e-9)
        let after = try #require(ElementAnimator.state(of: o, at: 19))
        #expect(after.x == 0.8 && after.rotation == 90, "it holds after the last keyframe")
    }

    @Test func settingAKeyframeAddsOrUpdates() {
        var k: [ElementKeyframe] = []
        k = ElementAnimator.setting(k, at: 1, to: ElementState(x: 0.3, y: 0.3, scale: 1, rotation: 0, alpha: 1, reveal: 1))
        k = ElementAnimator.setting(k, at: 3, to: ElementState(x: 0.7, y: 0.7, scale: 2, rotation: 10, alpha: 1, reveal: 1))
        k = ElementAnimator.setting(k, at: 1.01, to: ElementState(x: 0.4, y: 0.3, scale: 1, rotation: 0, alpha: 1, reveal: 1))
        #expect(k.count == 2 && k[0].x == 0.4 && k[1].scale == 2)
    }

    @Test func everyTemplateGivesATextALookAndKeepsItsWords() {
        for t in TextTemplate.allCases {
            var o = text(); o.text = "Xin chào"
            t.apply(to: &o)
            #expect(o.text == "Xin chào" && o.flair != nil && !o.fontName.isEmpty && o.sizeFraction > 0.02, "\(t)")
        }
        var neon = text(); TextTemplate.neon.apply(to: &neon)
        #expect(neon.flair?.shadow == true && neon.flair?.outlineWidth == 0)
        var third = text(); TextTemplate.lowerThird.apply(to: &third)
        #expect(third.alignment == .left && third.backgroundHex != nil && third.animationIn?.kind == .slideLeft)
        var typed = text(); TextTemplate.typewriter.apply(to: &typed)
        #expect(typed.animationIn?.kind == .typewriter)
        // A template replaces the previous one's animations instead of piling up.
        var o = text(); TextTemplate.comic.apply(to: &o); TextTemplate.classic.apply(to: &o)
        #expect(o.animationIn?.kind == .fade)
    }

    @Test func aShapeIsAnElementWithoutText() {
        let o = TextOverlay.shape(ShapeSpec(kind: .star), start: .zero, end: MediaTime(seconds: 3), x: 0.3, y: 0.4)
        #expect(o.isShape && o.text.isEmpty && o.x == 0.3 && o.y == 0.4)
        #expect(ElementAnimator.state(of: o, at: 1) != nil)
    }

    @Test func textSavedBeforeTheseFeaturesStillOpensAndNewOnesRoundTrip() throws {
        var o = text(); TextTemplate.neon.apply(to: &o); o.keyframes = [ElementKeyframe(time: 0, x: 0.1, y: 0.1)]; o.scale = 1.5; o.rotation = 12
        let data = try JSONEncoder().encode(o)
        #expect(try JSONDecoder().decode(TextOverlay.self, from: data) == o)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for k in ["flair", "shape", "animationIn", "animationOut", "keyframes", "scale", "rotation"] { obj.removeValue(forKey: k) }
        let old = try JSONDecoder().decode(TextOverlay.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.flair == nil && old.shape == nil && old.keyframes == nil && old.text == "Hi")
    }
}
