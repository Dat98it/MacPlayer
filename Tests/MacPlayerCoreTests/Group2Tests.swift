import Foundation
import Testing
@testable import MacPlayerCore

/// 0.21: the frame following people, copying styles, cutting silences.
struct ReframeTests {
    @Test func aPathIsCalmAndFollowsAPersonWhoWalksAcross() {
        // Somebody walks from the left (0.2) to the right (0.8) between 2 s and 8 s; nobody is seen for a second in the middle.
        let samples = stride(from: 0.0, through: 10, by: 0.25).map { t -> PersonSample in
            if t >= 4.5 && t < 5.5 { return PersonSample(time: t, center: nil) }
            let x = t < 2 ? 0.2 : (t > 8 ? 0.8 : 0.2 + (t - 2) / 6 * 0.6)
            return PersonSample(time: t, center: (x, 0.5))
        }
        let k = Reframe.path(samples)
        let start = Reframe.center(k, at: 0)!, end = Reframe.center(k, at: 10)!
        #expect(abs(start.x - 0.2) < 0.05 && abs(end.x - 0.8) < 0.1, "\(start) → \(end)")
        // Never faster than the limit, and never backwards while the person walks one way.
        var last = Reframe.center(k, at: 0)!.x
        for t in stride(from: 0.1, through: 10, by: 0.1) {
            let x = Reframe.center(k, at: t)!.x
            #expect(x - last >= -0.001 && x - last <= 0.35 * 0.1 + 0.002)
            last = x
        }
        #expect(k.count < samples.count / 2, "thinned out: \(k.count) keys for \(samples.count) looks")
    }

    @Test func smallMovesInsideTheMiddleDoNotMoveTheFrame() {
        let samples = stride(from: 0.0, through: 6, by: 0.25).map { PersonSample(time: $0, center: (0.5 + 0.03 * sin($0 * 3), 0.5)) }
        let k = Reframe.path(samples)
        #expect(k.allSatisfy { abs($0.x - k[0].x) < 0.001 }, "a person fidgeting in the middle leaves the frame still")
    }

    @Test func aOneOffWrongFindDoesNotSwingTheFrame() {
        // The person stays at 0.3; one look finds somebody at 0.9.
        let samples = (0..<40).map { i in PersonSample(time: Double(i) * 0.25, center: (i == 20 ? 0.9 : 0.3, 0.5)) }
        let k = Reframe.path(samples)
        #expect(k.allSatisfy { abs($0.x - 0.3) < 0.01 }, "\(k.map(\.x))")
    }

    @Test func nobodySeenKeepsTheMiddle() {
        let k = Reframe.path((0..<10).map { PersonSample(time: Double($0), center: nil) })
        #expect(k.allSatisfy { $0.x == 0.5 && $0.y == 0.5 })
    }

    @Test func pointsFollowTheCropAndTheTurn() {
        let crop = CropRect(x: 0.25, y: 0, width: 0.5, height: 1)
        #expect(Reframe.edited((0.5, 0.5), crop: crop, rotation: 0)! == (0.5, 0.5))
        #expect(Reframe.edited((0.375, 0.2), crop: crop, rotation: 0)!.x == 0.25)
        #expect(Reframe.edited((0.0, 0.5), crop: crop, rotation: 0) == nil, "cut away by the crop")
        #expect(Reframe.edited((0, 0), crop: .full, rotation: 90)! == (1, 0), "top-left goes to the top-right")
    }

    @Test func oldLooksOpenWithoutAPath() throws {
        let l = try JSONDecoder().decode(VideoLook.self, from: JSONEncoder().encode(VideoLook()))
        #expect(l.reframe == nil)
        var w = VideoLook(); w.reframe = [ReframeKey(time: 1, x: 0.3, y: 0.5)]
        #expect(try JSONDecoder().decode(VideoLook.self, from: JSONEncoder().encode(w)).reframe?.first?.x == 0.3)
        #expect(w.changesPicture)
    }
}

struct StyleCopyTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 6000) }

    @Test func aClipStyleGoesOnTheChosenClipsAndOnlyTheChosenParts() {
        var p = Project(name: "s", kind: .video)
        let src = UUID()
        p.timeline = (0..<3).map { i in TimelineClip(sourceID: src, sourceStart: s(Double(i) * 10), sourceEnd: s(Double(i) * 10 + 10)) }
        var look = VideoLook(); look.color.saturation = 0.5; look.effects.vignette = 0.4; look.speed = 2; look.fit = .fill; look.canvas = .portrait9x16
        let style = ClipStyle(look)
        #expect(style.changedParts == [.color, .effects, .frame, .speed])
        p.overlays = [TextOverlay(text: "over 3", start: s(22), end: s(25))]
        let n = style.paste([.color, .speed], to: [p.timeline[1].id, p.timeline[2].id], in: &p, ripple: true)
        #expect(n == 2)
        #expect(p.timeline[0].look.color.saturation == 0 && p.timeline[1].look.color.saturation == 0.5)
        #expect(p.timeline[1].look.effects.vignette == 0, "effects were not chosen")
        #expect(p.timeline[2].look.speed == 2 && abs(p.timeline[2].duration.seconds - 5) < 0.001)
        // Clip 2 is 5 s now (10–15), clip 3 starts at 15: its text (2 s into it at speed 1) is now 1 s into it.
        #expect(abs(p.overlays[0].start.seconds - 16) < 0.01, "the text stayed on its picture: \(p.overlays[0].start.seconds)")
    }

    @Test func aTextStyleKeepsTheWordsAndThePlace() {
        var from = TextOverlay(text: "TITLE", start: s(0), end: s(2), fontName: "Georgia-Bold", sizeFraction: 0.1, colorHex: "#FF0000", backgroundHex: "#000000")
        from.animationIn = ElementAnimation(kind: .pop, duration: 0.4)
        var p = Project(name: "t", kind: .video)
        p.overlays = [from, TextOverlay(text: "other", start: s(5), end: s(6), x: 0.2, y: 0.3),
                      TextOverlay.shape(ShapeSpec(kind: .star), start: s(0), end: s(1))]
        let n = TextStyle(from).paste(to: Set(p.overlays.map(\.id)), in: &p)
        #expect(n == 2)
        let o = p.overlays[1]
        #expect(o.text == "other" && o.x == 0.2 && o.y == 0.3 && o.start == s(5))
        #expect(o.fontName == "Georgia-Bold" && o.colorHex == "#FF0000" && o.sizeFraction == 0.1 && o.animationIn?.kind == .pop)
        #expect(p.overlays[2].shape?.kind == .star && p.overlays[2].animationIn?.kind == .pop, "a shape only takes the animations")
    }
}

struct SilenceTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 6000) }

    /// Speech (loud) with a 2 s pause at 3–5 s and a 0.4 s pause at 7 s; frames of 0.05 s.
    private func rms() -> [Float] {
        (0..<200).map { i in let t = Double(i) * 0.05; return (t >= 3 && t < 5) || (t >= 7 && t < 7.4) ? 0.001 : Float(0.2 + 0.05 * sin(t * 13)) }
    }

    @Test func longPausesAreFoundWithRoomLeftAroundTheWords() {
        let f = SilenceFinder.silences(rms: rms(), frameSeconds: 0.05, minLength: 0.7)
        #expect(f.count == 1)
        #expect(abs(f[0].start - 3.2) < 0.06 && abs(f[0].end - 4.7) < 0.06, "\(f)")
        #expect(SilenceFinder.silences(rms: [Float](repeating: 0.2, count: 200), frameSeconds: 0.05).isEmpty, "steady sound: nothing")
    }

    @Test func cuttingASilenceSplitsTheClipAndPullsTheRestIn() {
        var p = Project(name: "talk", kind: .video)
        let c = TimelineClip(sourceID: UUID(), sourceStart: s(100), sourceEnd: s(110), name: "Talk")
        p.timeline = [c]
        p.overlays = [TextOverlay(text: "late", start: s(8), end: s(9))]
        let found = SilenceFinder.found(in: c, clipStart: .zero, rms: rms(), frameSeconds: 0.05, minLength: 0.7, sensitivity: 0.25)
        #expect(found.count == 1 && abs(found[0].timeline.start.seconds - 3.2) < 0.06)
        let n = TimelineCuts.removeSilences(&p, found, ripple: true)
        #expect(n == 1 && p.timeline.count == 2)
        #expect(p.timeline.map(\.name) == ["Talk", "Talk"])
        #expect(abs(p.timeline.reduce(0) { $0 + $1.duration.seconds } - (10 - 1.5)) < 0.06)
        #expect(abs(p.overlays[0].start.seconds - (8 - 1.5)) < 0.06, "the text after it moved in")
        var unchosen = found; unchosen[0].chosen = false
        var q = Project(name: "t", kind: .video); q.timeline = [c]
        #expect(TimelineCuts.removeSilences(&q, unchosen, ripple: true) == 0 && q.timeline.count == 1)
    }
}
