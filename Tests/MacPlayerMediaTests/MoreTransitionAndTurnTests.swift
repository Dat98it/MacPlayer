import CoreImage
import CoreVideo
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// The newer transitions, a layer that turns, and a zoom-and-move that turns.
@Suite(.serialized) struct MoreTransitionAndTurnTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let frame = CGRect(x: 0, y: 0, width: 200, height: 100)

    private func solid(_ r: Double, _ g: Double, _ b: Double, w: Int = 200, h: Int = 100) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func px(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: Int(image.extent.height) - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func mix(_ kind: TransitionKind, _ p: Double) -> CIImage {
        TransitionRenderer.blend(outgoing: solid(1, 0, 0), incoming: solid(0, 0, 1), kind: kind, progress: p, frame: frame)
    }

    @Test func everyTransitionStartsOnTheOldPictureAndEndsOnTheNewOne() {
        for kind in TransitionKind.allCases {
            let start = mix(kind, 0), end = mix(kind, 1)
            for (x, y) in [(10, 10), (100, 50), (190, 90)] {
                let s = px(start, x, y), e = px(end, x, y)
                #expect(s.r > 235 && s.b < 20, "\(kind) at the start shows the old picture, got \(s) at \(x),\(y)")
                #expect(e.b > 235 && e.r < 20, "\(kind) at the end shows the new picture, got \(e) at \(x),\(y)")
            }
        }
    }

    @Test func theWipesUncoverFromTheirOwnEdge() {
        let left = mix(.wipeLeft, 0.5), up = mix(.wipeUp, 0.5), down = mix(.wipeDown, 0.5)
        #expect(px(left, 150, 50).b > 235 && px(left, 50, 50).r > 235, "wipe left: the right half is new")
        #expect(px(up, 100, 90).b > 235 && px(up, 100, 10).r > 235, "wipe up: the bottom half is new")
        #expect(px(down, 100, 10).b > 235 && px(down, 100, 90).r > 235, "wipe down: the top half is new")
    }

    @Test func theCircleOpensFromTheMiddle() {
        let mid = mix(.circleOpen, 0.4)
        #expect(px(mid, 100, 50).b > 235, "the middle is new")
        #expect(px(mid, 3, 3).r > 235, "the corner is still old")
    }

    @Test func theOtherTransitionsChangeThePictureInTheMiddle() {
        let flash = px(mix(.flash, 0.5), 100, 50)
        #expect(flash.r > 200 && flash.g > 200 && flash.b > 200, "a flash is nearly white in the middle, got \(flash)")
        for kind in [TransitionKind.spin, .blur, .pixelate] {
            let m = mix(kind, 0.5)
            let centre = px(m, 100, 50)
            #expect(centre.r != 255 || centre.b != 0 || kind == .spin, "\(kind) is mixed in the middle, got \(centre)")
        }
        let spin = mix(.spin, 0.5)
        #expect(px(spin, 3, 3).b > 200, "the corners are already the new picture when the old one has shrunk and turned")
    }

    @Test func aPreviewTakesANewTransitionKindWithoutBeingBuiltAgain() {
        func buffer(_ image: CIImage) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 200, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            ctx.render(image, to: pb!)
            return pb!
        }
        let red = buffer(solid(1, 0, 0)), blue = buffer(solid(0, 0, 1))
        let key = UUID()
        let plan = PiecePlan(look: VideoLook(), trackOrientation: .up, storedSize: PixelSize(width: 200, height: 100))
        var incoming = plan; incoming.liveKey = key
        let draw = TransitionDraw(trackID: 2, plan: incoming, kind: .dipBlack, start: 0, end: 1)
        func centre() -> (r: Int, g: Int, b: Int) {
            px(RecipeCompositor.render(source: red, plan: plan, layer: OverlayLayer(overlays: [], cues: [], style: SubtitleStyle()), time: 0.5,
                                       outputSize: CGSize(width: 200, height: 100), second: (blue, draw)), 100, 50)
        }
        TransitionLive.clear()
        let built = centre()
        #expect(built.r < 30 && built.b < 30, "half way through a dip to black, as built: \(built)")
        TransitionLive.set(.dissolve, for: key)
        let live = centre()
        #expect(live.r > 60 && live.b > 60, "the new kind is drawn at once: half red, half blue: \(live)")
        TransitionLive.clear()
        let cleared = centre()
        #expect(cleared.r < 30 && cleared.b < 30, "cleared: back to what the preview was built with: \(cleared)")
    }

    // MARK: Turning

    private func render(layer spec: LayerSpec, image: CIImage, over base: CIImage) -> CIImage {
        let plan = PiecePlan(look: VideoLook(), trackOrientation: .up, storedSize: PixelSize(width: Int(base.extent.width), height: Int(base.extent.height)))
        let draw = LayerDraw(spec: spec, live: false, trackID: nil, orientation: .up, image: image, border: CIColor.white)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(base.extent.width), Int(base.extent.height), kCVPixelFormatType_32BGRA, nil, &pb)
        ctx.render(base, to: pb!)
        return RecipeCompositor.render(source: pb!, plan: plan, layer: OverlayLayer(overlays: [], cues: [], style: SubtitleStyle()), time: 0.5,
                                       outputSize: base.extent.size, layerFrames: [(draw, nil)])
    }

    @Test func aLayerTurnedAQuarterStandsUp() {
        var t = OverlayTransform(); t.centerX = 0.5; t.centerY = 0.5; t.width = 0.6       // 120 × 60 px on a 200 × 100 picture
        let layer = solid(1, 0, 0, w: 120, h: 60)
        func spec() -> LayerSpec { LayerSpec(kind: .image(path: "x"), lane: 0, start: .zero, duration: MediaTime(seconds: 2), transform: t) }
        let flat = render(layer: spec(), image: layer, over: solid(0, 0, 1))
        #expect(px(flat, 55, 50).r > 235, "flat: it reaches out to the sides")
        #expect(px(flat, 100, 8).b > 235, "flat: it does not reach the top")
        t.rotation = 90
        let turned = render(layer: spec(), image: layer, over: solid(0, 0, 1))
        #expect(px(turned, 100, 12).r > 235 && px(turned, 100, 88).r > 235, "turned: it now reaches up and down")
        #expect(px(turned, 55, 50).b > 235, "turned: the sides are free again")
    }

    @Test func aLayerArrivingFromTheSideIsOffCentreAtFirst() {
        var t = OverlayTransform(); t.centerX = 0.5; t.centerY = 0.5; t.width = 0.3
        var s = LayerSpec(kind: .image(path: "x"), lane: 0, start: .zero, duration: MediaTime(seconds: 2), transform: t)
        s.animationIn = ElementAnimation(kind: .slideLeft, duration: 1)
        let image = solid(1, 0, 0, w: 60, h: 30)
        // 0.1 s into a 1 s arrival the layer is still far to the right; at 1.5 s it is settled in the middle
        func frameAt(_ time: Double) -> CIImage {
            let plan = PiecePlan(look: VideoLook(), trackOrientation: .up, storedSize: PixelSize(width: 200, height: 100))
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 200, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            ctx.render(solid(0, 0, 1), to: pb!)
            let draw = LayerDraw(spec: s, live: false, trackID: nil, orientation: .up, image: image, border: CIColor.white)
            return RecipeCompositor.render(source: pb!, plan: plan, layer: OverlayLayer(overlays: [], cues: [], style: SubtitleStyle()), time: time, outputSize: CGSize(width: 200, height: 100), layerFrames: [(draw, nil)])
        }
        let settled = px(frameAt(1.5), 100, 50)
        #expect(settled.r > 235, "settled in the middle, got \(settled)")
        let arriving = px(frameAt(0.1), 100, 50)
        #expect(arriving.b > 200 && arriving.r < 60, "at first the middle is empty (the layer is still off to the right), got \(arriving)")
    }

    @Test func aZoomAndMoveThatTurnsTurnsThePicture() {
        // red on the left half, blue on the right half
        let base = solid(1, 0, 0, w: 100, h: 100).composited(over: solid(0, 0, 1)).cropped(to: frame)
        // CIImage compositing puts the red half over the left: confirm, so the test reads as intended.
        #expect(px(base, 20, 50).r > 235 && px(base, 180, 50).b > 235)
        var look = VideoLook(); look.motion = [MotionKeyframe(time: 0, scale: 1, x: 0.5, y: 0.5, rotation: 90)]
        let plan = PiecePlan(look: look, trackOrientation: .up, storedSize: PixelSize(width: 200, height: 100))
        let out = RecipeCompositor.mainPicture(base: base, plan: plan, time: 0, outputSize: frame.size)
        // turned a quarter clockwise, the left half goes to the top and the right half to the bottom
        #expect(px(out, 100, 8).r > 200, "the red half is now at the top, got \(px(out, 100, 8))")
        #expect(px(out, 100, 92).b > 200, "the blue half is now at the bottom, got \(px(out, 100, 92))")
    }
}
