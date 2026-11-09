import AVFoundation
import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct TransitionTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 60)

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: frame) }
    private func px(_ i: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var p = [UInt8](repeating: 0, count: 4)
        ctx.render(i, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: 60 - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }
    private func blend(_ k: TransitionKind, _ p: Double) -> CIImage { TransitionRenderer.blend(outgoing: solid(1, 0, 0), incoming: solid(0, 0, 1), kind: k, progress: p, frame: frame) }

    @Test func everyKindStartsOnTheOutgoingPictureAndEndsOnTheIncomingOne() {
        for k in TransitionKind.allCases {
            let start = px(blend(k, 0), 50, 30), end = px(blend(k, 1), 50, 30)
            #expect(start.r > 240 && start.b < 15, "\(k) at 0: \(start)")
            #expect(end.b > 240 && end.r < 15, "\(k) at 1: \(end)")
        }
    }

    @Test func aDissolveMixesAndADipPassesThroughTheColour() {
        let mid = px(blend(.dissolve, 0.5), 50, 30)
        #expect(abs(mid.r - 127) < 8 && abs(mid.b - 127) < 8, "half and half: \(mid)")
        let black = px(blend(.dipBlack, 0.5), 50, 30), white = px(blend(.dipWhite, 0.5), 50, 30)
        #expect(black.r < 12 && black.b < 12, "black in the middle: \(black)")
        #expect(white.r > 243 && white.g > 243 && white.b > 243, "white in the middle: \(white)")
    }

    @Test func theSlidesPushOnePictureOutAndTheOtherIn() {
        let l = blend(.slideLeft, 0.5)
        #expect(px(l, 10, 30).r > 240 && px(l, 90, 30).b > 240, "slide left: the old on the left, the new coming from the right")
        let r = blend(.slideRight, 0.5)
        #expect(px(r, 10, 30).b > 240 && px(r, 90, 30).r > 240, "slide right")
        let u = blend(.slideUp, 0.5)
        #expect(px(u, 50, 5).r > 240 && px(u, 50, 55).b > 240, "slide up: the new picture rises from the bottom")
        let d = blend(.slideDown, 0.5)
        #expect(px(d, 50, 5).b > 240 && px(d, 50, 55).r > 240, "slide down")
    }

    @Test func aWipeUncoversTheNewPictureFromTheLeft() {
        let w = blend(.wipeRight, 0.25)
        #expect(px(w, 10, 30).b > 240 && px(w, 60, 30).r > 240)
    }

    @Test func aZoomFadesTheOldPictureAwayOverTheNewOne() {
        let m = px(blend(.zoomIn, 0.5), 50, 30)
        #expect(m.r > 90 && m.r < 170 && m.b > 90 && m.b < 170, "both show: \(m)")
    }

    @Test func theTransitionLengthIsKeptInRange() {
        #expect(ClipTransition(duration: 0.01).clampedDuration == ClipTransition.shortest)
        #expect(ClipTransition(duration: 99).clampedDuration == ClipTransition.longest)
        #expect(ClipTransition(duration: 1).clampedDuration == 1)
    }

    // MARK: Built and exported

    private func pieces(_ src: URL, transition: ClipTransition?, secondSpeed: Double = 1, secondStart: Double = 2) -> [RenderPiece] {
        var b = VideoLook(); b.transitionIn = transition; b.speed = secondSpeed
        return [RenderPiece(sourceURL: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 2))),
                RenderPiece(sourceURL: src, span: TimeSpan(start: MediaTime(seconds: secondStart), end: MediaTime(seconds: 4)), look: b)]
    }

    @Test func aTransitionKeepsTheTimelineTheSameLengthAndUsesTwoPictureTracks() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))
        let with = try await CompositionBuilder.build(pieces: pieces(src, transition: ClipTransition(kind: .dissolve, duration: 1)), includeAudio: true, frameAccurate: true, fixedGrid: true)
        let without = try await CompositionBuilder.build(pieces: pieces(src, transition: nil), includeAudio: true, frameAccurate: true, fixedGrid: true)
        #expect(abs(with.duration.seconds - without.duration.seconds) < 0.001, "same length: \(with.duration.seconds) vs \(without.duration.seconds)")
        #expect(with.composition.tracks(withMediaType: .video).count == 2 && without.composition.tracks(withMediaType: .video).count == 1)
        let instructions = (with.videoComposition?.instructions ?? []).compactMap { $0 as? RecipeInstruction }
        let blended = instructions.filter { $0.second != nil }
        #expect(!blended.isEmpty, "some stretch shows two pictures")
        let start = blended.map { $0.timeRange.start.seconds }.min()!, end = blended.map { CMTimeRangeGetEnd($0.timeRange).seconds }.max()!
        #expect(abs(start - 1.5) < 0.05 && abs(end - 2.5) < 0.05, "centred on the cut at 2.0, one second long: \(start)–\(end)")
        #expect(instructions.first!.timeRange.start == .zero && abs(CMTimeRangeGetEnd(instructions.last!.timeRange).seconds - with.duration.seconds) < 0.001, "no gaps")
    }

    @Test func aClipWithNoFootageToSpareHasNoTransitionAndStillBuilds() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))
        // The second clip starts at the very start of the source: there is nothing before it to overlap.
        var b = VideoLook(); b.transitionIn = ClipTransition(kind: .dissolve, duration: 1)
        let p = [RenderPiece(sourceURL: src, span: TimeSpan(start: MediaTime(seconds: 1), end: MediaTime(seconds: 3))),
                 RenderPiece(sourceURL: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 2)), look: b)]
        let built = try await CompositionBuilder.build(pieces: p, includeAudio: true, frameAccurate: true, fixedGrid: true)
        #expect(abs(built.duration.seconds - 4) < 0.05)
        #expect((built.videoComposition?.instructions ?? []).compactMap { $0 as? RecipeInstruction }.allSatisfy { $0.second == nil })
    }

    @Test func aTransitionIsShortenedToTheFootageThereIs() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))
        // Only 0.3 s of the source is left after the first clip (it runs to 3.7 s of 4): a 2 s transition can only be 0.6 s long, 0.3 each side.
        let p = pieces(src, transition: ClipTransition(kind: .dissolve, duration: 2), secondStart: 2)
        var first = p[0]; first.span = TimeSpan(start: .zero, end: MediaTime(seconds: 3.7))
        let built = try await CompositionBuilder.build(pieces: [first, p[1]], includeAudio: true, frameAccurate: true, fixedGrid: true)
        let blended = (built.videoComposition?.instructions ?? []).compactMap { $0 as? RecipeInstruction }.filter { $0.second != nil }
        let span = (blended.map { CMTimeRangeGetEnd($0.timeRange).seconds }.max() ?? 0) - (blended.map { $0.timeRange.start.seconds }.min() ?? 0)
        #expect(span > 0.2 && span <= 0.65, "the overlap is only as long as the spare footage allows: \(span)")
    }

    @Test func aTransitionBetweenClipsOfDifferentSpeedKeepsTheRightLength() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))
        let built = try await CompositionBuilder.build(pieces: pieces(src, transition: ClipTransition(kind: .slideLeft, duration: 0.6), secondSpeed: 2), includeAudio: true, frameAccurate: true, fixedGrid: true)
        #expect(abs(built.duration.seconds - 3) < 0.1, "2 s then 2 s at double speed: \(built.duration.seconds)")
        #expect((built.videoComposition?.instructions ?? []).compactMap { $0 as? RecipeInstruction }.contains { $0.second != nil })
    }

    @Test func anExportedTransitionBlendsAtTheCutAndLeavesTheRestAlone() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))        // frame n carries the number n
        let out = Fixtures.shared.outputURL("transition-export")
        let recipe = RenderRecipe(look: VideoLook())
        // The second clip is a different stretch of the source (3 s on), so the two pictures differ at the cut.
        try await RenderExporter().export(pieces: pieces(src, transition: ClipTransition(kind: .dissolve, duration: 1), secondStart: 3), recipe: recipe, to: out, options: ExportOptions(mode: .exact, container: .mp4, codec: .h264))
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 3) < 0.15, "2 s plus 1 s: \(info.duration.seconds)")
        func number(_ t: Double) async throws -> Int? { FrameGrabber.syntheticIndex(of: try await FrameGrabber.image(url: out, at: MediaTime(seconds: t, timescale: 600), accuracy: .exact)) }
        let before = try await number(1.0), after = try await number(2.8)
        #expect(before.map { abs($0 - 30) <= 2 } == true, "before the transition it is the first clip (source 1.0 = frame 30): \(String(describing: before))")
        #expect(after.map { abs($0 - 114) <= 2 } == true, "after it, the second clip (source 3.8 = frame 114): \(String(describing: after))")
        let middle = try await number(2.0)             // the first clip is at its frame 60 here, the second at its frame 90
        #expect(middle == nil || (abs(middle! - 60) > 4 && abs(middle! - 90) > 4), "at the middle of the cut the two pictures are mixed, so the frame is neither clip's own: \(String(describing: middle))")
    }
}
