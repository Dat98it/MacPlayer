import AVFoundation
import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Filters, blur, vignette, sharpening, the blurred backdrop and chroma key, on pictures made for the purpose.
@Suite(.serialized) struct LookEffectsTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double, w: Int = 64, h: Int = 64) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func rgba(_ image: CIImage, at x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let rect = CGRect(x: x, y: Int(image.extent.height) - 1 - y, width: 1, height: 1)
        ctx.render(image, toBitmap: &px, rowBytes: 4, bounds: rect, format: .RGBA8, colorSpace: nil)
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    private func frame(_ img: CIImage) -> CGRect { img.extent }

    @Test func monoRemovesColourAndNeutralLeavesThePictureAlone() {
        let red = solid(1, 0, 0)
        var e = LookEffects(); e.filter = .mono
        let mono = rgba(LookEffectsRenderer.apply(e, to: red, frame: frame(red)), at: 10, 10)
        #expect(abs(mono.r - mono.g) < 8 && abs(mono.g - mono.b) < 8, "got \(mono)")
        #expect(LookEffects().isNeutral)
        let same = rgba(LookEffectsRenderer.apply(LookEffects(), to: red, frame: frame(red)), at: 10, 10)
        #expect(same.r == 255 && same.g == 0 && same.b == 0)
    }

    @Test func theFilterAmountBlendsBetweenTheOriginalAndTheFilter() {
        let red = solid(1, 0, 0)
        func spread(_ amount: Double) -> Int {
            var e = LookEffects(); e.filter = .mono; e.filterAmount = amount
            let p = rgba(LookEffectsRenderer.apply(e, to: red, frame: frame(red)), at: 5, 5)
            return p.r - p.g
        }
        #expect(spread(0) > 240 && spread(1) < 12)
        #expect(spread(0.5) > 40 && spread(0.5) < 220, "half way, got \(spread(0.5))")
    }

    @Test func everyPresetChangesAPictureAndKeepsItsSize() {
        let base = solid(0.6, 0.4, 0.3, w: 80, h: 48)
        let before = rgba(base, at: 40, 24)
        for preset in FilterPreset.allCases where preset != .none {
            var e = LookEffects(); e.filter = preset
            let out = LookEffectsRenderer.apply(e, to: base, frame: frame(base))
            let after = rgba(out, at: 40, 24)
            #expect(out.extent == base.extent, "\(preset): size")
            #expect(abs(after.r - before.r) + abs(after.g - before.g) + abs(after.b - before.b) > 6, "\(preset) changed nothing: \(before) -> \(after)")
        }
    }

    @Test func aVignetteDarkensTheCornersMoreThanTheMiddle() {
        let grey = solid(0.5, 0.5, 0.5, w: 200, h: 200)
        var e = LookEffects(); e.vignette = 1
        let out = LookEffectsRenderer.apply(e, to: grey, frame: frame(grey))
        #expect(rgba(out, at: 100, 100).r > rgba(out, at: 2, 2).r + 15, "corner \(rgba(out, at: 2, 2).r) middle \(rgba(out, at: 100, 100).r)")
    }

    @Test func blurSoftensAnEdgeAndKeepsTheSize() {
        let left = solid(0, 0, 0, w: 50, h: 100), right = solid(1, 1, 1, w: 50, h: 100).transformed(by: CGAffineTransform(translationX: 50, y: 0))
        let edge = right.composited(over: left)
        var e = LookEffects(); e.blur = 1
        let out = LookEffectsRenderer.apply(e, to: edge, frame: edge.extent)
        #expect(out.extent == edge.extent)
        #expect(rgba(edge, at: 48, 50).r < 5 && rgba(out, at: 48, 50).r > 30, "before \(rgba(edge, at: 48, 50).r) after \(rgba(out, at: 48, 50).r)")
    }

    @Test func sharpeningRaisesTheContrastAtAnEdge() {
        let left = solid(0.4, 0.4, 0.4, w: 50, h: 100), right = solid(0.6, 0.6, 0.6, w: 50, h: 100).transformed(by: CGAffineTransform(translationX: 50, y: 0))
        let edge = right.composited(over: left)
        var e = LookEffects(); e.sharpen = 1
        let out = LookEffectsRenderer.apply(e, to: edge, frame: edge.extent)
        #expect(rgba(out, at: 52, 50).r > rgba(edge, at: 52, 50).r + 3, "before \(rgba(edge, at: 52, 50).r) after \(rgba(out, at: 52, 50).r)")
    }

    @Test func theBackdropFillsTheWholeFrameWithTheVideosOwnColours() {
        let landscape = solid(0.9, 0.1, 0.1, w: 160, h: 90)
        let frame = CGRect(x: 0, y: 0, width: 90, height: 160)
        let bg = LookEffectsRenderer.backdrop(of: landscape, frame: frame, amount: 0.5)
        #expect(bg.extent == frame)
        for (x, y) in [(2, 2), (45, 80), (87, 157)] {
            let p = rgba(bg, at: x, y)
            #expect(p.r > 150 && p.g < 90 && p.b < 90, "at \(x),\(y): \(p)")
        }
    }

    @Test func chromaKeyRemovesTheKeyColourAndKeepsOthers() {
        let key = ChromaKey(colorHex: "#00FF00", tolerance: 0.3, softness: 0.15)
        let green = LookEffectsRenderer.chromaKeyed(solid(0, 1, 0), key: key)
        let red = LookEffectsRenderer.chromaKeyed(solid(1, 0, 0), key: key)
        let shadow = LookEffectsRenderer.chromaKeyed(solid(0, 0.55, 0.05), key: key)       // the same backdrop in the dark
        let skin = LookEffectsRenderer.chromaKeyed(solid(0.85, 0.6, 0.5), key: key)
        #expect(rgba(green, at: 5, 5).a < 10, "green stays: \(rgba(green, at: 5, 5))")
        #expect(rgba(red, at: 5, 5).a > 245 && rgba(skin, at: 5, 5).a > 245)
        #expect(rgba(shadow, at: 5, 5).a < 60, "a green in shadow still goes: \(rgba(shadow, at: 5, 5))")
    }

    @Test func aWiderToleranceRemovesMoreOfTheNeighbouringColours() {
        let lime = solid(0.3, 0.8, 0.1)
        let tight = rgba(LookEffectsRenderer.chromaKeyed(lime, key: ChromaKey(tolerance: 0.1, softness: 0.05)), at: 5, 5).a
        let wide = rgba(LookEffectsRenderer.chromaKeyed(lime, key: ChromaKey(tolerance: 0.7, softness: 0.05)), at: 5, 5).a
        #expect(tight > wide, "tight \(tight) wide \(wide)")
    }

    /// A 32-bit frame filled with one colour, as the compositor receives frames.
    private func frameBuffer(_ r: Double, _ g: Double, _ b: Double, w: Int = 320, h: Int = 180) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        ctx.render(solid(r, g, b, w: w, h: h), to: pb!)
        return pb!
    }

    @Test func thePortraitBarsAreBlackUnlessTheBlurredBackdropIsAskedFor() {
        let src = frameBuffer(0.95, 0.5, 0.1)                       // an orange landscape frame
        let layer = OverlayLayer(overlays: [], cues: [], style: SubtitleStyle())
        func bar(_ blur: Bool) -> (r: Int, g: Int, b: Int, a: Int) {
            var look = VideoLook(); look.canvas = .portrait9x16; look.fit = .fit; look.effects.blurBackground = blur
            let plan = PiecePlan(look: look, trackOrientation: .up, storedSize: PixelSize(width: 320, height: 180))
            let out = RecipeCompositor.render(source: src, plan: plan, layer: layer, time: 0, outputSize: CGSize(width: 90, height: 160))
            return rgba(out, at: 45, 6)
        }
        let plain = bar(false), blurred = bar(true)
        #expect(plain.r < 10 && plain.g < 10, "the bar is black: \(plain)")
        #expect(blurred.r > 150 && blurred.g > 70 && blurred.b < 60, "the bar shows the video's own colours, blurred: \(blurred)")
    }

    @Test func aFilterReachesAnExportedFile() async throws {
        let src = try await Fixtures.shared.source()
        func colourSpread(_ filter: FilterPreset) async throws -> Int {
            var look = VideoLook(); look.effects.filter = filter
            let out = Fixtures.shared.outputURL("filter-\(filter.rawValue)")
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 30), look: look)], recipe: RenderRecipe(look: look), to: out, options: ExportOptions(mode: .exact))
            let ci = CIImage(cgImage: try await FrameGrabber.image(url: out, at: MediaTime(seconds: 0.3)))
            var total = 0
            for yy in stride(from: 2, to: Int(ci.extent.height), by: 6) { for xx in stride(from: 2, to: Int(ci.extent.width), by: 6) {
                let p = rgba(ci, at: xx, yy); total += abs(p.r - p.g) + abs(p.g - p.b)
            } }
            return total
        }
        let plain = try await colourSpread(.none), mono = try await colourSpread(.mono)
        #expect(plain > 400, "the test picture has colour to remove: \(plain)")
        #expect(mono < plain / 4, "mono took most of the colour out of the exported picture: plain \(plain) mono \(mono)")
    }

    /// A frame with its left half red and its right half blue.
    private func halvesBuffer(w: Int = 320, h: Int = 180) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let left = solid(1, 0, 0, w: w / 2, h: h), right = solid(0, 0, 1, w: w / 2, h: h).transformed(by: CGAffineTransform(translationX: CGFloat(w / 2), y: 0))
        ctx.render(right.composited(over: left), to: pb!)
        return pb!
    }

    @Test func zoomingIntoTheRightHalfShowsOnlyBlueAndAPanMovesOverTime() {
        let src = halvesBuffer()
        let layer = OverlayLayer(overlays: [], cues: [], style: SubtitleStyle())
        func render(_ look: VideoLook, at t: Double, start: Double = 0) -> CIImage {
            let plan = PiecePlan(look: look, trackOrientation: .up, storedSize: PixelSize(width: 320, height: 180), rangeStart: start)
            return RecipeCompositor.render(source: src, plan: plan, layer: layer, time: t, outputSize: CGSize(width: 320, height: 180))
        }
        let still = render(VideoLook(), at: 0)
        #expect(rgba(still, at: 10, 90).r > 200 && rgba(still, at: 310, 90).b > 200)

        var zoom = VideoLook(); zoom.motion = [MotionKeyframe(time: 0, scale: 2, x: 0.75, y: 0.5)]
        let z = render(zoom, at: 0)
        #expect(rgba(z, at: 10, 90).b > 200 && rgba(z, at: 310, 90).b > 200 && rgba(z, at: 10, 90).r < 40, "only the right half is in view")

        var pan = VideoLook(); pan.motion = [MotionKeyframe(time: 0, scale: 2, x: 0.25), MotionKeyframe(time: 2, scale: 2, x: 0.75)]
        let a = render(pan, at: 0), b = render(pan, at: 2)
        #expect(rgba(a, at: 160, 90).r > 200 && rgba(a, at: 310, 90).r > 200, "starts on the red half")
        #expect(rgba(b, at: 10, 90).b > 200 && rgba(b, at: 310, 90).b > 200, "ends on the blue half")
        let shifted = render(pan, at: 12, start: 10)          // the same moment of a clip that starts at 10 s on the timeline
        #expect(rgba(shifted, at: 10, 90).b > 200, "animations count from the clip's own start")
    }

    @Test func aPreviewTakesNewFilterSettingsWithoutBeingBuiltAgain() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let src = try #require(buffer)
        ctx.render(solid(1, 0, 0), to: src)
        let key = UUID()
        var plan = PiecePlan(look: VideoLook(), trackOrientation: .up, storedSize: PixelSize(width: 64, height: 64))
        plan.liveKey = key
        func centre() -> (r: Int, g: Int, b: Int, a: Int) { rgba(RecipeCompositor.mainPicture(source: src, plan: plan, time: 0, outputSize: CGSize(width: 64, height: 64)), at: 32, 32) }
        EffectsLive.clear()
        let before = centre()
        #expect(before.r > 240 && before.g < 15, "untouched red: \(before)")
        var mono = LookEffects(); mono.filter = .mono
        EffectsLive.set(mono, for: key)
        let after = centre()
        #expect(abs(after.r - after.g) < 12, "the live filter is drawn: \(after)")
        EffectsLive.clear()
        #expect(centre().r > 240, "cleared: back to what the preview was built with")
        // Only a preview has a key: a plan without one never reads the live settings.
        var exportPlan = plan; exportPlan.liveKey = nil
        EffectsLive.set(mono, for: key)
        let exported = rgba(RecipeCompositor.mainPicture(source: src, plan: exportPlan, time: 0, outputSize: CGSize(width: 64, height: 64)), at: 32, 32)
        #expect(exported.r > 240 && exported.g < 15, "an export ignores them: \(exported)")
        EffectsLive.clear()
    }
}
