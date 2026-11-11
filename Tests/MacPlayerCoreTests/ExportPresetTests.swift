import Foundation
import Testing
@testable import MacPlayerCore

@Suite struct ExportPresetTests {
    @Test func oneChoiceSetsBothQualityAndSize() {
        var o = ExportOptions(mode: .exact)
        ExportPreset.hd720.apply(to: &o)
        #expect(o.resolution == .p720 && o.quality == .medium && ExportPreset(options: o) == .hd720)
        ExportPreset.fullHD1080.apply(to: &o)
        #expect(o.resolution == .p1080 && o.quality == .high)
        #expect(Set(ExportPreset.allCases.map { "\($0.quality)-\($0.resolution)" }).count == ExportPreset.allCases.count, "no two choices are the same")
        o.quality = .small; o.resolution = .p2160
        #expect(ExportPreset(options: o) == nil, "an old mix that is none of the choices is recognised as such")
    }

    @Test func theFrameIsSetOnEveryClip() {
        var p = Project(name: "P", kind: .video)
        let a = p.addSource(SourceRef(path: "/a.mp4")), b = p.addSource(SourceRef(path: "/b.mp4"))
        p.timeline = [TimelineClip(sourceID: a, sourceStart: .zero, sourceEnd: MediaTime(seconds: 1)), TimelineClip(sourceID: b, sourceStart: .zero, sourceEnd: MediaTime(seconds: 1))]
        p.setFrame(.portrait9x16, fill: .blurredBars)
        #expect(p.timeline.allSatisfy { $0.look.canvas == .portrait9x16 && $0.look.fit == .fit && $0.look.effects.blurBackground })
        #expect(p.frameShape == .portrait9x16 && p.frameFill == .blurredBars)
        p.setFrame(.portrait4x5, fill: .fill)
        #expect(p.frameShape == .portrait4x5 && p.frameFill == .fill && p.timeline.allSatisfy { !$0.look.effects.blurBackground })
        #expect(CanvasPreset.portrait4x5.aspect == 0.8)
        let out = RenderGeometry.outputSize(source: PixelSize(width: 1920, height: 1080), look: p.timeline[0].look)
        #expect(abs(Double(out.width) / Double(out.height) - 0.8) < 0.01, "the export is 4:5 (\(out.width) × \(out.height))")
    }

    @Test func aSquareIsSquareOnAnyPicture() {
        for aspect in [16.0 / 9, 9.0 / 16, 1, 4.0 / 3] {
            let s = ShapeSpec.made(.rectangle, aspect: aspect)
            #expect(abs(s.width * aspect - s.height) < 1e-9, "a square on \(aspect): \(s.width) × \(s.height) of the picture")
        }
        let arrow = ShapeSpec.made(.arrow, width: 0.25, aspect: 16.0 / 9)
        #expect(abs(arrow.height - 0.25 * 0.5 * 16 / 9) < 1e-9, "an arrow is twice as wide as it is tall on screen")
        #expect(ShapeSpec.made(.line, aspect: 16.0 / 9).height < 0.02)
        #expect(ShapeKind.allCases.count == 16)
    }

    @Test func tallVideosAreSizedByTheirShortSide() {
        var look = VideoLook(); look.canvas = .portrait9x16
        let hd = PixelSize(width: 1920, height: 1080)
        #expect(RenderGeometry.outputSize(source: hd, look: look, maxHeight: 1080, limitsShortSide: true) == PixelSize(width: 1080, height: 1920), "9:16 at 1080p is 1080 × 1920")
        #expect(RenderGeometry.outputSize(source: hd, look: look, maxHeight: 720, limitsShortSide: true) == PixelSize(width: 720, height: 1280))
        #expect(RenderGeometry.outputSize(source: hd, look: look, maxHeight: 1080) == PixelSize(width: 608, height: 1080), "the preview still limits the height")
        let wide = VideoLook()
        #expect(RenderGeometry.outputSize(source: hd, look: wide, maxHeight: 720, limitsShortSide: true) == PixelSize(width: 1280, height: 720), "a wide video is the same as before")
        #expect(RenderGeometry.outputSize(source: PixelSize(width: 640, height: 360), look: look, maxHeight: 720, limitsShortSide: true) == PixelSize(width: 360, height: 640), "never enlarged")
    }
}

