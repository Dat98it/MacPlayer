import Foundation
import Testing
@testable import MacPlayerCore

/// 0.16.5: things shown in full while the editor is paused, motions that keep going, pictures stretched freely, more styles and shapes,
/// and the history list.
struct EditorAdditionsTests {
    private func sticker(fade: Double = 0, pop: Bool = true) -> TextOverlay {
        var o = TextOverlay(text: "🔥", start: MediaTime(seconds: 10), end: MediaTime(seconds: 13), sizeFraction: 0.2, x: 0.3, y: 0.3, fade: fade)
        if pop { o.animationIn = ElementAnimation(kind: .pop, duration: 0.4) }
        return o
    }

    @Test func aThingAddedAtThePlayheadIsSeenInFullWhilePaused() {
        let o = sticker(fade: 0.2)
        // At its very first instant its arrival has not started: see-through (what was drawn before 0.16.5 when paused there).
        #expect(ElementAnimator.state(of: o, at: 10)?.alpha == 0)
        // Settled (paused in the editor): in full, at its own place and size.
        let s = ElementAnimator.state(of: o, at: 10, settled: true)
        #expect(s?.alpha == 1 && s?.scale == 1 && s?.x == 0.3)
        // Outside its time it is not shown, settled or not.
        #expect(ElementAnimator.state(of: o, at: 9.99, settled: true) == nil)
        // A layer the same way.
        var c = OverlayClip(name: "logo", kind: .image(path: "/l.png", bookmark: nil), lane: 0, start: MediaTime(seconds: 10), duration: MediaTime(seconds: 5))
        c.fadeIn = 0.5; c.animationIn = ElementAnimation(kind: .zoom, duration: 0.5)
        #expect((c.state(at: MediaTime(seconds: 10))?.opacity ?? 1) < 0.01)
        #expect(c.state(at: MediaTime(seconds: 10), settled: true)?.opacity == 1)
    }

    @Test func motionsKeepGoingStayInBoundsAndRepeat() {
        for kind in ElementLoopKind.allCases {
            let l = ElementLoop(kind: kind)
            var moved = false
            for i in 0..<200 {
                let t = Double(i) * 0.037
                let o = l.offsets(at: t)
                #expect(abs(o.dx) <= 0.1 && abs(o.dy) <= 0.1 && o.scale > 0.5 && o.scale < 1.6 && o.alpha >= 0 && o.alpha <= 1, "\(kind) at \(t)")
                if abs(o.dx) > 1e-4 || abs(o.dy) > 1e-4 || abs(o.scale - 1) > 1e-4 || abs(o.rotation) > 1e-3 || abs(o.alpha - 1) > 1e-4 { moved = true }
                // One round later it is where it was (the spin by a whole turn).
                let next = l.offsets(at: t + l.period)
                #expect(abs(next.dx - o.dx) < 1e-6 && abs(next.dy - o.dy) < 1e-6 && abs(next.scale - o.scale) < 1e-6 && abs(next.alpha - o.alpha) < 1e-6, "\(kind) repeats")
            }
            #expect(moved, "\(kind) moves")
        }
        // It goes on top of the element's own place, and on a layer too.
        var o = sticker(pop: false); o.loop = ElementLoop(kind: .swing)
        let quarter = ElementAnimator.state(of: o, at: 10 + o.loop!.period / 4)
        #expect(abs((quarter?.rotation ?? 0) - 10) < 0.01)
        var c = OverlayClip(name: "logo", kind: .image(path: "/l.png", bookmark: nil), lane: 0, start: .zero, duration: MediaTime(seconds: 5))
        c.loop = ElementLoop(kind: .pulse)
        let w0 = c.transform.width, w1 = c.state(at: MediaTime(seconds: c.loop!.period / 4))?.width ?? 0
        #expect(abs(w1 - w0 * 1.08) < 1e-6)
        // Editing a layer starts from its own values, not from where its motion has it.
        #expect(OverlayEditor.editableState(c, at: MediaTime(seconds: c.loop!.period / 4)).width == w0)
    }

    @Test func aPictureIsStretchedFreelyFromItsSides() {
        let start = OverlayState(centerX: 0.5, centerY: 0.5, width: 0.2, opacity: 1)
        let oa = 16.0 / 9, own = 1.0        // a square picture on a wide frame
        let r0 = OverlayDrag.rect(start, outputAspect: oa, layerAspect: own)
        // The right side out: wider, same height, the left side stays.
        let wide = OverlayDrag.stretch(start, stretch: 1, edge: .right, to: (r0.x1 + 0.1, 0.5), outputAspect: oa, layerAspect: own)
        let r1 = OverlayDrag.rect(wide.state, outputAspect: oa, layerAspect: own / wide.stretch)
        #expect(abs(r1.x0 - r0.x0) < 1e-9 && abs(r1.height - r0.height) < 1e-9 && abs(r1.width - (r0.width + 0.1)) < 1e-9 && wide.stretch < 1)
        // The bottom down: taller, same width, the top stays.
        let tall = OverlayDrag.stretch(start, stretch: 1, edge: .bottom, to: (0.5, r0.y1 + 0.2), outputAspect: oa, layerAspect: own)
        let r2 = OverlayDrag.rect(tall.state, outputAspect: oa, layerAspect: own / tall.stretch)
        #expect(abs(r2.y0 - r0.y0) < 1e-9 && abs(r2.width - r0.width) < 1e-9 && abs(r2.height - (r0.height + 0.2)) < 1e-9 && tall.stretch > 1)
        // Never inside out.
        let thin = OverlayDrag.stretch(start, stretch: 1, edge: .left, to: (0.99, 0.5), outputAspect: oa, layerAspect: own)
        #expect(thin.state.width >= 0.03 - 1e-9)
        var t = OverlayTransform(); t.stretch = 2
        #expect(t.drawnAspect(1) == 0.5 && OverlayTransform().drawnAspect(1.5) == 1.5)
    }

    @Test func olderProjectsOpenWithoutTheNewSettings() throws {
        let t = try JSONDecoder().decode(OverlayTransform.self, from: Data(#"{"centerX":0.4,"width":0.3}"#.utf8))
        #expect(t.stretch == 1)
        var o = sticker(); o.loop = ElementLoop(kind: .bounce, period: 0.9, strength: 1.5)
        let back = try JSONDecoder().decode(TextOverlay.self, from: JSONEncoder().encode(o))
        #expect(back.loop == o.loop)
        var plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sticker())) as! [String: Any]
        plain.removeValue(forKey: "loop")
        let old = try JSONDecoder().decode(TextOverlay.self, from: JSONSerialization.data(withJSONObject: plain))
        #expect(old.loop == nil)
    }

    @Test func thereAreAtLeastThirtyStylesAndShapes() {
        #expect(TextTemplate.allCases.count >= 30)
        #expect(ShapeKind.allCases.count >= 30)
        #expect(ElementLoopKind.allCases.count >= 10)
        for t in TextTemplate.allCases { var o = TextOverlay(text: "Aa", start: .zero, end: MediaTime(seconds: 1)); t.apply(to: &o); #expect(o.sizeFraction > 0.02 && !o.fontName.isEmpty, "\(t)") }
        for k in ShapeKind.allCases { #expect(k.naturalHeightRatio > 0 && !k.defaultFillHex.isEmpty) }
    }

    @Test func theHistoryListsStepsBothWays() {
        var h = History(0)
        h.commit(1, label: "A"); h.commit(2, label: "B"); h.commit(3, label: "C")
        #expect(h.undoLabels == ["C", "B", "A"] && h.redoLabels.isEmpty)
        h.undo(); h.undo()
        #expect(h.undoLabels == ["A"] && h.redoLabels == ["B", "C"] && h.present == 1)
    }
}
