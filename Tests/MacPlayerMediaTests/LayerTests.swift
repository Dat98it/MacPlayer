import AVFoundation
import CoreGraphics
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Layers over the main picture. The main source is 320x180; a layer 0.3 wide centred at (0.8, 0.75) covers x 208...304, y 108...162.
@Suite(.serialized) struct LayerRenderTests {
    private var engaged: VideoLook { var l = VideoLook(); l.color.brightness = 0.0001; return l }
    private let box = CGRect(x: 208, y: 108, width: 96, height: 54)
    private let elsewhere = CGRect(x: 20, y: 40, width: 120, height: 60)

    private func png(_ r: Double, _ g: Double, _ b: Double, name: String) throws -> URL {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let url = Fixtures.shared.outputURL(name, ext: "png")
        try ImageWriter.write(ctx.makeImage()!, to: url, format: .png)
        return url
    }

    private func render(_ main: URL, layers: [LayerSpec], from: Int64 = 0, to: Int64 = 120, name: String = "layer") async throws -> URL {
        let out = Fixtures.shared.outputURL(name)
        let recipe = RenderRecipe(look: engaged, layers: layers)
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: main, span: span30(from, to), look: engaged)], recipe: recipe, to: out, options: ExportOptions(mode: .exact))
        return out
    }

    private func video(_ url: URL, start: Double, duration: Double, lane: Int = 0, _ f: (inout OverlayTransform) -> Void = { _ in }) -> LayerSpec {
        var t = OverlayTransform(); t.centerX = 0.8; t.centerY = 0.75; t.width = 0.3; f(&t)
        return LayerSpec(kind: .video(path: url.path, sourceStart: .zero, sourceEnd: MediaTime(seconds: 4)), lane: lane, start: MediaTime(seconds: start, timescale: 600), duration: MediaTime(seconds: duration, timescale: 600), transform: t)
    }

    @Test func aVideoLayerAppearsOnlyDuringItsTimeRangeAndOnlyInItsPlace() async throws {
        let main = try await Fixtures.shared.source()
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let base = try await render(main, layers: [], name: "layer-base")
        let out = try await render(main, layers: [video(cam, start: 1, duration: 2)], name: "layer-pip")
        let before = try await frame(out, at: 0.5).meanAbsDiff(try await frame(base, at: 0.5), in: box)
        let during = try await frame(out, at: 1.5).meanAbsDiff(try await frame(base, at: 1.5), in: box)
        let outside = try await frame(out, at: 1.5).meanAbsDiff(try await frame(base, at: 1.5), in: elsewhere)
        let after = try await frame(out, at: 3.5).meanAbsDiff(try await frame(base, at: 3.5), in: box)
        #expect(during > 8 && before < 3 && after < 3, "inside the box: before \(before), during \(during), after \(after)")
        #expect(outside < 3, "the rest of the picture is unchanged (\(outside))")
    }

    @Test func theMainPicturesFramesAreUntouchedByALayer() async throws {
        let main = try await Fixtures.shared.source()
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let out = try await render(main, layers: [video(cam, start: 0.2, duration: 0.8)], from: 30, to: 70, name: "layer-frames")
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx == Array(30..<70), "got \(idx.first ?? -1)...\(idx.last ?? -1), \(idx.count) frames")
    }

    @Test func opacityBlendsTheLayerWithWhatIsBelow() async throws {
        let main = try await Fixtures.shared.source()
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let base = try await render(main, layers: [], name: "op-base")
        let full = try await render(main, layers: [video(cam, start: 0, duration: 3)], name: "op-full")
        let half = try await render(main, layers: [video(cam, start: 0, duration: 3) { $0.opacity = 0.5 }], name: "op-half")
        let b = try await frame(base, at: 1.5)
        let dFull = try await frame(full, at: 1.5).meanAbsDiff(b, in: box), dHalf = try await frame(half, at: 1.5).meanAbsDiff(b, in: box)
        #expect(dFull > 8 && dHalf > dFull * 0.3 && dHalf < dFull * 0.75, "full \(dFull), half \(dHalf)")
    }

    @Test func aBorderIsDrawnAroundTheLayer() async throws {
        let main = try await Fixtures.shared.source()
        let pic = try png(1, 0, 1, name: "magenta")
        let spec = LayerSpec(kind: .image(path: pic.path), lane: 0, start: .zero, duration: MediaTime(seconds: 3), transform: { var t = OverlayTransform(); t.centerX = 0.8; t.centerY = 0.75; t.width = 0.3; t.borderWidth = 0.04; t.borderHex = "#00FF00"; return t }())
        let out = try await render(main, layers: [spec], name: "border")
        let f = try await frame(out, at: 1.5)
        #expect(f.isGreen(205, 135), "green border just left of the box: \(f.rgb(205, 135))")
        let c = f.rgb(256, 135)
        #expect(c.r > 200 && c.g < 60 && c.b > 200, "the picture itself is magenta: \(c)")
    }

    @Test func keyframesMoveTheLayerAcrossThePicture() async throws {
        let main = try await Fixtures.shared.source()
        let pic = try png(1, 0, 1, name: "mag2")
        var left = OverlayState(centerX: 0.2, centerY: 0.5, width: 0.2, opacity: 1), right = left; right.centerX = 0.8
        var clip = OverlayClip(name: "k", kind: .image(path: pic.path, bookmark: nil), start: .zero, duration: MediaTime(seconds: 3))
        OverlayEditor.setKeyframe(&clip, at: MediaTime(seconds: 0.5), to: left)
        OverlayEditor.setKeyframe(&clip, at: MediaTime(seconds: 2), to: right)
        left.opacity = 1
        let spec = LayerSpec(kind: .image(path: pic.path), lane: 0, start: clip.start, duration: clip.duration, transform: clip.transform, keyframes: clip.keyframes)
        let out = try await render(main, layers: [spec], name: "kf")
        func magenta(_ f: Pixels, _ x: Int, _ y: Int) -> Bool { let c = f.rgb(x, y); return c.r > 200 && c.g < 70 && c.b > 200 }
        let early = try await frame(out, at: 0.2), mid = try await frame(out, at: 1.25), late = try await frame(out, at: 2.6)
        #expect(magenta(early, 64, 90) && !magenta(early, 256, 90), "starts on the left")
        #expect(!magenta(mid, 64, 90) && !magenta(mid, 256, 90) && magenta(mid, 160, 90), "half way it is in the middle")
        #expect(magenta(late, 256, 90) && !magenta(late, 64, 90), "holds on the right after the last keyframe")
    }

    @Test func aHigherLaneIsDrawnOnTop() async throws {
        let main = try await Fixtures.shared.source()
        let mag = try png(1, 0, 1, name: "lane0"), cyan = try png(0, 1, 1, name: "lane1")
        func spec(_ u: URL, lane: Int) -> LayerSpec { var t = OverlayTransform(); t.centerX = 0.5; t.centerY = 0.5; t.width = 0.3; return LayerSpec(kind: .image(path: u.path), lane: lane, start: .zero, duration: MediaTime(seconds: 3), transform: t) }
        // Listed in the "wrong" order on purpose: the lane decides, not the list.
        let out = try await render(main, layers: [spec(cyan, lane: 1), spec(mag, lane: 0)], name: "lanes")
        let c = try await frame(out, at: 1).rgb(160, 90)
        #expect(c.r < 110 && c.g > 200 && c.b > 200, "lane 1 (cyan) is on top of lane 0 (magenta, which would be r > 200, g < 60): \(c)")
    }

    @Test func aLayersSoundIsMixedIn() async throws {
        let silent = try await Fixtures.shared.source(.init(audio: false))
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let withSound = try await render(silent, layers: [video(cam, start: 0, duration: 3)], name: "snd")
        #expect(try await MediaProbe.probe(url: withSound).hasAudio)
        #expect(try await FrameScanner.beepOnsets(url: withSound).count >= 2, "the layer's beeps are heard")
        var muted = video(cam, start: 0, duration: 3); muted.audio.muted = true
        let quiet = try await render(silent, layers: [muted], name: "snd-muted")
        #expect(try await MediaProbe.probe(url: quiet).hasAudio == false, "a muted layer adds no sound")
    }

    @Test func aLayerPastTheEndOfTheTimelineIsCutNotExtended() async throws {
        let main = try await Fixtures.shared.source()
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let out = try await render(main, layers: [video(cam, start: 3, duration: 10)], name: "past-end")   // main is 4 s
        let d = try await MediaProbe.probe(url: out).duration.seconds
        #expect(abs(d - 4) < 0.15, "the export is as long as the main timeline: \(d)")
    }

    @Test func theExportMatchesThePreviewWithLayers() async throws {
        let main = try await Fixtures.shared.source()
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let specs = [video(cam, start: 0.5, duration: 3) { $0.borderWidth = 0.02; $0.opacity = 0.8 }]
        let out = try await render(main, layers: specs, from: 0, to: 120, name: "layer-parity")
        let preview = try await CompositionBuilder.build(pieces: [RenderPiece(sourceURL: main, span: TimeSpan(start: .zero, end: MediaTime(seconds: 4)), look: engaged)], layers: specs, frameAccurate: false)
        let gen = AVAssetImageGenerator(asset: preview.composition)
        gen.videoComposition = preview.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        var worst = 0.0
        for t in [1.0, 2.0, 3.0] {
            let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let p = Pixels(cg), e = try await frame(out, at: t)
            #expect(p.width == e.width && p.height == e.height)
            worst = max(worst, p.meanAbsDiff(e))
        }
        #expect(worst < 3, "preview and export differ by \(worst)/255")
    }
}

/// Frame counts when layers reach the very end of the timeline (found by the in-app self-test: 179 frames instead of 180).
@Suite(.serialized) struct LayerFrameCountTests {
    private var engaged: VideoLook { var l = VideoLook(); l.color.brightness = 0.0001; return l }

    private func png() throws -> URL {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let url = Fixtures.shared.outputURL("cnt", ext: "png"); try ImageWriter.write(ctx.makeImage()!, to: url, format: .png); return url
    }

    private func count(_ layers: [LayerSpec]) async throws -> [Int] {
        let main = try await Fixtures.shared.source(.init(seconds: 6))
        let out = Fixtures.shared.outputURL("cnt")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: main, span: span30(0, 180), look: engaged)], recipe: RenderRecipe(look: engaged, layers: layers), to: out, options: ExportOptions(mode: .exact))
        return try await FrameScanner.scanVideo(url: out).compactMap(\.index)
    }

    @Test func noLayers() async throws { let i = try await count([]); #expect(i == Array(0..<180), "\(i.count) frames, last \(i.last ?? -1)") }

    @Test func aPictureLayerThatEndsExactlyAtTheEnd() async throws {
        let l = LayerSpec(kind: .image(path: try png().path), lane: 0, start: MediaTime(seconds: 1, timescale: 600), duration: MediaTime(seconds: 5, timescale: 600))
        let i = try await count([l]); #expect(i == Array(0..<180), "\(i.count) frames, last \(i.last ?? -1)")
    }

    @Test func aVideoLayerInTheMiddle() async throws {
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let l = LayerSpec(kind: .video(path: cam.path, sourceStart: .zero, sourceEnd: MediaTime(seconds: 3)), lane: 0, start: MediaTime(seconds: 2, timescale: 600), duration: MediaTime(seconds: 3, timescale: 600))
        let i = try await count([l]); #expect(i == Array(0..<180), "\(i.count) frames, last \(i.last ?? -1)")
    }

    @Test func aKeyframedPictureLayer() async throws {
        var clip = OverlayClip(name: "k", kind: .image(path: try png().path, bookmark: nil), start: MediaTime(seconds: 1, timescale: 600), duration: MediaTime(seconds: 5, timescale: 600))
        OverlayEditor.setKeyframe(&clip, at: .zero, to: OverlayState(centerX: 0.2, centerY: 0.8, width: 0.2, opacity: 1))
        OverlayEditor.setKeyframe(&clip, at: MediaTime(seconds: 3, timescale: 600), to: OverlayState(centerX: 0.8, centerY: 0.8, width: 0.2, opacity: 1))
        let l = LayerSpec(kind: .image(path: clip.kindPath), lane: 0, start: clip.start, duration: clip.duration, transform: clip.transform, keyframes: clip.keyframes)
        let i = try await count([l]); #expect(i == Array(0..<180), "\(i.count) frames, last \(i.last ?? -1)")
    }
}

private extension OverlayClip { var kindPath: String { if case .image(let p, _) = kind { return p }; return "" } }

@Suite(.serialized) struct LayerAppScenarioTests {
    private func png() throws -> URL {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let url = Fixtures.shared.outputURL("scn", ext: "png"); try ImageWriter.write(ctx.makeImage()!, to: url, format: .png); return url
    }

    /// Regression: with layers and NO other picture edit the builder still treated the main picture as a straight copy and
    /// trimmed half a frame off both ends, losing the last frame. (Other tests added a colour filter, which hid it.)
    @Test(arguments: ["picture", "video", "video+border", "both"])
    func theLastFrameSurvives(_ which: String) async throws {
        let main = try await Fixtures.shared.source(.init(seconds: 8, gop: 60, width: 640, height: 360))
        let cam = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc, seconds: 3))
        var layers: [LayerSpec] = []
        if which == "picture" || which == "both" {
            layers.append(LayerSpec(kind: .image(path: try png().path), lane: 1, start: MediaTime(seconds: 1, timescale: 600), duration: MediaTime(seconds: 5, timescale: 600)))
        }
        if which.hasPrefix("video") || which == "both" {
            var t = OverlayTransform(); t.width = 0.3; if which != "video" { t.borderWidth = 0.02 }
            layers.append(LayerSpec(kind: .video(path: cam.path, sourceStart: .zero, sourceEnd: MediaTime(seconds: 3)), lane: 0, start: MediaTime(seconds: 2, timescale: 600), duration: MediaTime(seconds: 3, timescale: 600), transform: t))
        }
        let out = Fixtures.shared.outputURL("scn")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: main, span: span30(0, 180))], recipe: RenderRecipe(layers: layers), to: out, options: ExportOptions(mode: .exact))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx == Array(0..<180), "\(which): \(idx.count) frames, missing \(Array(Set(0..<180).subtracting(idx).sorted().prefix(6)))")
    }
}


@Suite(.serialized) struct LiveLayerTests {
    private func png() throws -> URL {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let url = Fixtures.shared.outputURL("live", ext: "png"); try ImageWriter.write(ctx.makeImage()!, to: url, format: .png); return url
    }

    private func magenta(_ f: Pixels, _ x: Int, _ y: Int) -> Bool { let c = f.rgb(x, y); return c.r > 200 && c.g < 70 && c.b > 200 }

    private func spec(at x: Double, id: UUID, path: String) -> LayerSpec {
        var t = OverlayTransform(); t.centerX = x; t.centerY = 0.5; t.width = 0.2
        return LayerSpec(id: id, kind: .image(path: path), lane: 0, start: .zero, duration: MediaTime(seconds: 3), transform: t)
    }

    @Test func aPreviewFollowsALiveChangeButAnExportNeverDoes() async throws {
        defer { LayerLive.clear() }
        let main = try await Fixtures.shared.source()
        let path = try png().path, id = UUID()
        let original = spec(at: 0.2, id: id, path: path)          // left
        let piece = RenderPiece(sourceURL: main, span: TimeSpan(start: .zero, end: MediaTime(seconds: 4)))

        func previewFrame() async throws -> Pixels {
            let built = try await CompositionBuilder.build(pieces: [piece], layers: [original], frameAccurate: false)
            let gen = AVAssetImageGenerator(asset: built.composition)
            gen.videoComposition = built.videoComposition
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            return Pixels(try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image)
        }
        // Same composition objects, asked again after the live change: only the numbers differ.
        let before = try await previewFrame()
        #expect(magenta(before, 64, 90) && !magenta(before, 256, 90), "the layer starts on the left")

        LayerLive.set(spec(at: 0.8, id: id, path: path))          // a drag moves it to the right
        let after = try await previewFrame()
        #expect(magenta(after, 256, 90) && !magenta(after, 64, 90), "the preview follows the live change")

        let out = Fixtures.shared.outputURL("live-export")
        try await RenderExporter().export(pieces: [piece], recipe: RenderRecipe(layers: [original]), to: out, options: ExportOptions(mode: .exact))
        let exported = try await frame(out, at: 1)
        #expect(magenta(exported, 64, 90) && !magenta(exported, 256, 90), "the export ignores the live change and draws its own spec")
    }

    @Test func clearingTheLiveStoreReturnsToTheBuiltValues() async throws {
        let main = try await Fixtures.shared.source()
        let path = try png().path, id = UUID()
        LayerLive.set(spec(at: 0.8, id: id, path: path))
        LayerLive.clear()
        let built = try await CompositionBuilder.build(pieces: [RenderPiece(sourceURL: main, span: TimeSpan(start: .zero, end: MediaTime(seconds: 4)))], layers: [spec(at: 0.2, id: id, path: path)], frameAccurate: false)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let f = Pixels(try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image)
        #expect(magenta(f, 64, 90) && !magenta(f, 256, 90))
    }
}
