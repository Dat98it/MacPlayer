import CoreImage
import CoreVideo
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Shape masks, key colours, subject cut-outs and blending, drawn on pictures made for the purpose.
@Suite(.serialized) struct MaskTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double, w: Int = 200, h: Int = 100) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// One pixel, x and y counted from the top-left.
    private func px(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: Int(image.extent.height) - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func picture(_ base: CIImage, look: VideoLook) -> CIImage {
        let plan = PiecePlan(look: look, trackOrientation: .up, storedSize: PixelSize(width: Int(base.extent.width), height: Int(base.extent.height)))
        return RecipeCompositor.mainPicture(base: base, plan: plan, time: 0, outputSize: base.extent.size)
    }

    // MARK: Shapes (geometry)

    @Test func eachShapeHasItsInsideAndOutside() {
        for shape in MaskShape.allCases {
            var m = MaskSpec(shape: shape); m.width = 0.5; m.height = 0.5
            #expect(MaskGeometry.contains(m, x: 0.5, y: 0.5, aspect: 1) || shape == .split, "the middle of \(shape) is inside")
        }
        var e = MaskSpec(shape: .ellipse); e.width = 0.5; e.height = 0.5
        #expect(MaskGeometry.contains(e, x: 0.5, y: 0.5, aspect: 1))
        #expect(!MaskGeometry.contains(e, x: 0.95, y: 0.95, aspect: 1))
        var r = MaskSpec(shape: .rectangle); r.width = 0.5; r.height = 0.5
        #expect(MaskGeometry.contains(r, x: 0.7, y: 0.7, aspect: 1) && !MaskGeometry.contains(r, x: 0.8, y: 0.5, aspect: 1))
        var rr = MaskSpec(shape: .roundedRectangle); rr.width = 0.5; rr.height = 0.5
        #expect(!MaskGeometry.contains(rr, x: 0.749, y: 0.749, aspect: 1), "the corner of a rounded rectangle is cut off")
        #expect(MaskGeometry.contains(rr, x: 0.5, y: 0.5, aspect: 1))
        var h = MaskSpec(shape: .heart); h.width = 0.6; h.height = 0.6
        #expect(MaskGeometry.contains(h, x: 0.5, y: 0.5, aspect: 1) && !MaskGeometry.contains(h, x: 0.5, y: 0.02, aspect: 1))
        var st = MaskSpec(shape: .star); st.width = 0.8; st.height = 0.8
        #expect(MaskGeometry.contains(st, x: 0.5, y: 0.5, aspect: 1) && !MaskGeometry.contains(st, x: 0.9, y: 0.9, aspect: 1))
        let split = MaskSpec(shape: .split)
        #expect(MaskGeometry.contains(split, x: 0.2, y: 0.5, aspect: 1) && !MaskGeometry.contains(split, x: 0.8, y: 0.5, aspect: 1))
    }

    @Test func aTurnedShapeIsTurnedAndAStretchedPictureDoesNotSquashIt() {
        var bar = MaskSpec(shape: .rectangle); bar.width = 0.8; bar.height = 0.1
        #expect(MaskGeometry.contains(bar, x: 0.8, y: 0.5, aspect: 1) && !MaskGeometry.contains(bar, x: 0.5, y: 0.8, aspect: 1))
        bar.rotation = 90
        #expect(MaskGeometry.contains(bar, x: 0.5, y: 0.8, aspect: 1) && !MaskGeometry.contains(bar, x: 0.8, y: 0.5, aspect: 1), "turned a quarter, the bar stands up")
        // A circle stays round on a wide picture: its width is a fraction of the width, its height of the height.
        var c = MaskSpec(shape: .ellipse); c.width = 0.5; c.height = 0.5
        #expect(MaskGeometry.contains(c, x: 0.5 + 0.2, y: 0.5, aspect: 2), "wide picture: 0.2 of the width across is inside")
    }

    @Test func settingsAreKeptInRange() {
        var m = MaskSpec(); m.feather = 7; m.width = -1; m.centerX = 9
        let c = m.clamped()
        #expect(c.feather == 1 && c.width == 0.05 && c.centerX == 1.5)
    }

    // MARK: Drawn

    @Test func aMaskOnThePictureKeepsTheInsideAndShowsTheBackdropOutside() {
        var look = VideoLook()
        var m = MaskSpec(shape: .ellipse); m.width = 0.5; m.height = 0.5; m.feather = 0
        look.mask = m; look.backdropHex = "#0000FF"
        let out = picture(solid(1, 0, 0), look: look)
        let centre = px(out, 100, 50), corner = px(out, 4, 4)
        #expect(centre.r > 240 && centre.b < 20, "inside: the picture, got \(centre)")
        #expect(corner.b > 240 && corner.r < 20, "outside: the backdrop colour, got \(corner)")
    }

    @Test func aShapePlacedHighKeepsTheTopOfThePicture() {
        var look = VideoLook()
        var m = MaskSpec(shape: .rectangle); m.centerY = 0.25; m.width = 1; m.height = 0.4; m.feather = 0
        look.mask = m
        let out = picture(solid(1, 0, 0), look: look)
        #expect(px(out, 100, 10).r > 240, "the top is kept")
        #expect(px(out, 100, 90).r < 20, "the bottom is gone")
        // A heart has its two humps at the top and its point at the bottom.
        var heart = MaskSpec(shape: .heart); heart.width = 0.8; heart.height = 0.9; heart.feather = 0
        look.mask = heart
        let h = picture(solid(1, 0, 0, w: 200, h: 200), look: look)
        #expect(px(h, 55, 45).r > 240 && px(h, 145, 45).r > 240, "both humps are at the top")
        #expect(px(h, 100, 20).r < 20, "the dip between the humps is at the top")
        #expect(px(h, 100, 170).r > 240, "the point reaches the bottom middle")
        #expect(px(h, 20, 175).r < 20, "the bottom corners are empty")
    }

    @Test func invertSwapsInsideAndOutsideAndBlackIsTheBackdropByDefault() {
        var look = VideoLook()
        var m = MaskSpec(shape: .ellipse); m.width = 0.5; m.height = 0.5; m.feather = 0; m.invert = true
        look.mask = m
        let out = picture(solid(1, 0, 0), look: look)
        #expect(px(out, 100, 50).r < 20, "inside is gone: black")
        #expect(px(out, 4, 4).r > 240, "outside stays")
    }

    @Test func aSoftEdgeFadesBetweenKeptAndHidden() {
        var look = VideoLook()
        var m = MaskSpec(shape: .rectangle); m.width = 0.5; m.height = 1; m.feather = 0.6
        look.mask = m
        let out = picture(solid(1, 1, 1), look: look)
        let edge = px(out, 150, 50)         // right at the edge of the half
        #expect(edge.r > 40 && edge.r < 215, "the edge is part way, got \(edge)")
        #expect(px(out, 100, 50).r > 240 && px(out, 195, 50).r < 20)
    }

    @Test func aKeyColourOnTheMainPictureShowsTheBackdrop() {
        var look = VideoLook()
        look.chromaKey = ChromaKey(colorHex: "#00FF00", tolerance: 0.3, softness: 0.1)
        look.backdropHex = "#FF8000"
        let green = picture(solid(0, 1, 0), look: look), red = picture(solid(1, 0, 0), look: look)
        #expect(px(green, 50, 50).g < 160 && px(green, 50, 50).r > 200, "green is replaced by the backdrop, got \(px(green, 50, 50))")
        #expect(px(red, 50, 50).r > 240 && px(red, 50, 50).g < 20, "red is not touched")
    }

    @Test func aSubjectCutOutKeepsTheSubjectAndDropsTheRest() {
        // Pretend the subject is the left half of the picture.
        SubjectMasker.provider = { image, _ in
            let e = image.extent
            let left = CIImage(color: .white).cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width / 2, height: e.height))
            return left.composited(over: CIImage(color: .black).cropped(to: e))
        }
        defer { SubjectMasker.provider = nil }
        var look = VideoLook(); look.isolateSubject = true; look.backdropHex = "#00FF00"
        let out = picture(solid(1, 0, 0), look: look)
        #expect(px(out, 40, 50).r > 240, "the left half is kept")
        #expect(px(out, 160, 50).g > 240 && px(out, 160, 50).r < 20, "the right half shows the backdrop")
    }

    @Test func noSubjectFoundLeavesThePictureWhole() {
        SubjectMasker.provider = { _, _ in nil }
        defer { SubjectMasker.provider = nil }
        var look = VideoLook(); look.isolateSubject = true
        #expect(px(picture(solid(1, 0, 0), look: look), 100, 50).r > 240)
    }

    @Test func aPictureWithNoPersonInItGivesNoMaskFromVision() {
        // The real Vision request on a flat picture: nothing to find, and no crash.
        _ = SubjectMasker.mask(for: solid(0.5, 0.5, 0.5, w: 64, h: 64), mode: .previewVideo)
        _ = SubjectMasker.mask(for: solid(0.5, 0.5, 0.5, w: 64, h: 64), mode: .photo)
    }

    // MARK: Layers

    private func render(layer spec: LayerSpec, image: CIImage, over base: CIImage) -> CIImage {
        var plan = PiecePlan(look: VideoLook(), trackOrientation: .up, storedSize: PixelSize(width: Int(base.extent.width), height: Int(base.extent.height)))
        plan.subjectMode = .exportVideo
        let draw = LayerDraw(spec: spec, live: false, trackID: nil, orientation: .up, image: image, border: CIColor.white)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(base.extent.width), Int(base.extent.height), kCVPixelFormatType_32BGRA, nil, &pb)
        ctx.render(base, to: pb!)
        return RecipeCompositor.render(source: pb!, plan: plan, layer: OverlayLayer(overlays: [], cues: [], style: SubtitleStyle()), time: 0.5,
                                       outputSize: base.extent.size, layerFrames: [(draw, nil)])
    }

    private func spec(_ t: OverlayTransform) -> LayerSpec {
        LayerSpec(kind: .image(path: "x"), lane: 0, start: .zero, duration: MediaTime(seconds: 2), transform: t)
    }

    @Test func aBlendModeMixesTheLayerWithWhatIsUnderIt() {
        var t = OverlayTransform(); t.centerX = 0.5; t.centerY = 0.5; t.width = 1
        let under = solid(0.5, 0.5, 0.5), top = solid(0.5, 0.5, 0.5)
        let normal = px(render(layer: spec(t), image: top, over: under), 100, 50)
        t.blend = .multiply
        let mult = px(render(layer: spec(t), image: top, over: under), 100, 50)
        t.blend = .screen
        let screen = px(render(layer: spec(t), image: top, over: under), 100, 50)
        #expect(abs(normal.r - 128) < 4, "a normal layer covers: got \(normal)")
        #expect(mult.r < 80, "multiply darkens (0.5 × 0.5 ≈ 0.25): got \(mult)")
        #expect(screen.r > 170, "screen lightens (≈ 0.75): got \(screen)")
    }

    @Test func aLayerMaskCutsTheLayerNotTheBackground() {
        var t = OverlayTransform(); t.centerX = 0.5; t.centerY = 0.5; t.width = 1
        var m = MaskSpec(shape: .ellipse); m.width = 0.4; m.height = 0.4; m.feather = 0; t.mask = m
        let out = render(layer: spec(t), image: solid(1, 0, 0), over: solid(0, 0, 1))
        #expect(px(out, 100, 50).r > 240, "the middle of the layer shows")
        #expect(px(out, 4, 4).b > 240 && px(out, 4, 4).r < 20, "outside the shape the picture under it shows")
    }

    @Test func oldProjectsOpenWithNoMaskBlendOrCutOut() throws {
        let old = ##"{"centerX":0.4,"centerY":0.5,"width":0.3,"opacity":1,"borderWidth":0,"borderHex":"#FFFFFF"}"##.data(using: .utf8)!
        let t = try JSONDecoder().decode(OverlayTransform.self, from: old)
        #expect(t.mask == nil && t.blend == .normal && !t.isolateSubject && t.centerX == 0.4)
        let look = try JSONDecoder().decode(VideoLook.self, from: #"{"rotation":90}"#.data(using: .utf8)!)
        #expect(look.mask == nil && look.chromaKey == nil && !look.isolateSubject && look.backdropHex == nil && !look.cutsOut)
        var withMask = OverlayTransform(); withMask.mask = MaskSpec(shape: .heart); withMask.blend = .overlay; withMask.isolateSubject = true
        #expect(try JSONDecoder().decode(OverlayTransform.self, from: try JSONEncoder().encode(withMask)) == withMask)
        var l = VideoLook(); l.mask = MaskSpec(); l.backdropHex = "#112233"
        #expect(try JSONDecoder().decode(VideoLook.self, from: try JSONEncoder().encode(l)) == l && l.changesPicture)
    }
}
