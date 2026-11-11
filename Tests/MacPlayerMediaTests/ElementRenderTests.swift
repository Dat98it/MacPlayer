import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct ElementRenderTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let size = CGSize(width: 320, height: 180)

    private func alphaPixels(_ cg: CGImage) -> Int {
        let ci = CIImage(cgImage: cg)
        var p = [UInt8](repeating: 0, count: Int(ci.extent.width) * Int(ci.extent.height) * 4)
        ctx.render(ci, toBitmap: &p, rowBytes: Int(ci.extent.width) * 4, bounds: ci.extent, format: .RGBA8, colorSpace: nil)
        return stride(from: 3, to: p.count, by: 4).filter { p[$0] > 40 }.count
    }
    private func alpha(_ cg: CGImage, _ x: Int, _ y: Int) -> Int {
        var p = [UInt8](repeating: 0, count: 4)
        ctx.render(CIImage(cgImage: cg), toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: cg.height - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Int(p[3])
    }
    private func bounds(_ cg: CGImage) -> CGRect {
        let ci = CIImage(cgImage: cg); let w = Int(ci.extent.width), h = Int(ci.extent.height)
        var p = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(ci, toBitmap: &p, rowBytes: w * 4, bounds: ci.extent, format: .RGBA8, colorSpace: nil)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 40 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        return maxX < 0 ? .zero : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    private func box(_ text: String = "Hello", configure: (inout OverlayRenderer.TextBox) -> Void = { _ in }) -> OverlayRenderer.TextBox {
        var b = OverlayRenderer.TextBox(text: text, fontName: "Helvetica-Bold", sizeFraction: 0.2, colorHex: "#FFFFFF", outlineHex: nil, backgroundHex: nil, alignment: .center, centerX: 0.5, centerY: 0.5, bottomMargin: 0)
        configure(&b); return b
    }

    @Test func everyShapeIsFilledInTheMiddleAndEmptyOutsideItsBox() throws {
        for kind in ShapeKind.allCases {
            let spec = ShapeSpec(kind: kind, width: 0.4, height: kind == .line ? 0.03 : 0.4, fillHex: "#FF0000")
            let img = try #require(OverlayRenderer.renderShape(spec, centerX: 0.5, centerY: 0.5, size: size), "\(kind)")
            if kind != .ring { #expect(alpha(img, 160, 90) > 200, "\(kind): filled at its centre") }     // a ring is empty in the middle (tested on its own)
            #expect(alpha(img, 5, 5) == 0 && alpha(img, 315, 175) == 0, "\(kind): nothing outside")
            let b = bounds(img)
            #expect(b.width <= 0.4 * 320 + 3 && b.height <= max(0.4 * 180 + 3, 8), "\(kind) stays within its box: \(b)")
        }
    }

    @Test func aShapeIsPlacedWhereItIsToldAndAnOutlineIsDrawnOnlyWhenAsked() throws {
        let left = try #require(OverlayRenderer.renderShape(ShapeSpec(kind: .rectangle, width: 0.2, height: 0.2, fillHex: "#00FF00"), centerX: 0.25, centerY: 0.25, size: size))
        #expect(alpha(left, 80, 45) > 200 && alpha(left, 240, 135) == 0)
        let outlined = try #require(OverlayRenderer.renderShape(ShapeSpec(kind: .rectangle, width: 0.3, height: 0.3, fillHex: nil, strokeHex: "#FFFFFF", strokeWidth: 0.02), centerX: 0.5, centerY: 0.5, size: size))
        #expect(alpha(outlined, 160, 90) == 0, "no fill: the middle is empty")
        #expect(alpha(outlined, 160 - 48, 90) > 100, "the outline is drawn on the box's edge")
    }

    @Test func theTypewriterDrawsOnlyThePartOfTheTextRevealed() throws {
        let full = try #require(OverlayRenderer.render(box(), size: size)), half = try #require(OverlayRenderer.render(box { $0.reveal = 0.4 }, size: size))
        #expect(alphaPixels(half) > 0 && alphaPixels(half) < alphaPixels(full) * 7 / 10, "less ink: \(alphaPixels(half)) of \(alphaPixels(full))")
        let b0 = bounds(OverlayRenderer.render(box { $0.reveal = 1 }, size: size)!)
        // The unrevealed letters take no space away: what is shown stays where it would be.
        let startOfFull = bounds(full).minX, startOfHalf = bounds(half).minX
        #expect(abs(startOfFull - startOfHalf) < 3 && b0.width > 0, "the shown letters do not shift (\(startOfFull) vs \(startOfHalf))")
    }

    @Test func letterSpacingAndCapitalsChangeWhatIsDrawn() throws {
        let plain = bounds(try #require(OverlayRenderer.render(box(), size: size)))
        let spaced = bounds(try #require(OverlayRenderer.render(box { $0.letterSpacing = 0.4 }, size: size)))
        #expect(spaced.width > plain.width + 20, "wider with space between letters: \(plain.width) → \(spaced.width)")
        let lower = bounds(try #require(OverlayRenderer.render(box("hello"), size: size))), upper = bounds(try #require(OverlayRenderer.render(box("hello") { $0.uppercase = true }, size: size)))
        #expect(upper.height > lower.height, "capitals are taller: \(lower.height) → \(upper.height)")
    }

    @Test func aShadowAddsInkAroundTheLettersAndNoOutlineMeansNoneIsDrawn() throws {
        let plain = alphaPixels(try #require(OverlayRenderer.render(box(), size: size)))
        let shadowed = alphaPixels(try #require(OverlayRenderer.render(box { $0.shadow = true; $0.shadowHex = "#FF00FF" }, size: size)))
        #expect(shadowed > plain, "a glow spreads past the letters: \(plain) → \(shadowed)")
        let outlined = alphaPixels(try #require(OverlayRenderer.render(box { $0.outlineHex = "#000000" }, size: size)))
        let none = alphaPixels(try #require(OverlayRenderer.render(box { $0.outlineHex = "#000000"; $0.outlineWidth = 0 }, size: size)))
        #expect(outlined > none, "an outline adds ink; a width of 0 draws none: \(outlined) vs \(none)")
        var o = TextOverlay(text: "x", start: .zero, end: MediaTime(seconds: 1)); var f = TextFlair(); f.outlineWidth = 0; o.flair = f
        #expect(OverlayRenderer.box(for: o).outlineHex == nil, "a text with its outline switched off")
    }

    // MARK: Through the compositor

    private func frameBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        ctx.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)), to: pb!)
        return pb!
    }
    private func pixel(_ i: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var p = [UInt8](repeating: 0, count: 4)
        ctx.render(i, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: 180 - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }
    private func render(_ overlays: [TextOverlay], at t: Double) -> CIImage {
        let plan = PiecePlan(look: VideoLook(), trackOrientation: .up, storedSize: PixelSize(width: 320, height: 180))
        return RecipeCompositor.render(source: frameBuffer(), plan: plan, layer: OverlayLayer(overlays: overlays, cues: [], style: SubtitleStyle()), time: t, outputSize: size)
    }

    @Test func aShapeFollowsItsKeyframesAcrossThePicture() {
        var o = TextOverlay.shape(ShapeSpec(kind: .rectangle, width: 0.2, height: 0.3, fillHex: "#FF0000"), start: .zero, end: MediaTime(seconds: 4), x: 0.2, y: 0.5)
        o.fade = 0
        o.keyframes = [ElementKeyframe(time: 0, x: 0.2, y: 0.5), ElementKeyframe(time: 2, x: 0.8, y: 0.5)]
        let a = render([o], at: 0.01), b = render([o], at: 2.5)
        #expect(pixel(a, 64, 90).r > 200 && pixel(a, 256, 90).r < 20, "at the start it is on the left")
        #expect(pixel(b, 256, 90).r > 200 && pixel(b, 64, 90).r < 20, "after the keyframes it is on the right")
        let mid = render([o], at: 1.0)
        #expect(pixel(mid, 160, 90).r > 200, "half way it is in the middle")
    }

    @Test func aShapeGrowsAndTurnsAndFadesAsAnimated() {
        var o = TextOverlay.shape(ShapeSpec(kind: .rectangle, width: 0.1, height: 0.1, fillHex: "#00FF00"), start: .zero, end: MediaTime(seconds: 4), x: 0.5, y: 0.5)
        o.fade = 0; o.scale = 3
        let big = render([o], at: 1)
        #expect(pixel(big, 160 + 40, 90).g > 200, "three times as big reaches further out")
        var faded = o; faded.scale = 1; faded.keyframes = [ElementKeyframe(time: 0, x: 0.5, y: 0.5, opacity: 1), ElementKeyframe(time: 2, x: 0.5, y: 0.5, opacity: 0)]
        #expect(pixel(render([faded], at: 1.0), 160, 90).g < 140 && pixel(render([faded], at: 1.0), 160, 90).g > 90, "half faded")
        var turned = o; turned.scale = 1; turned.rotation = 45; turned.shape = ShapeSpec(kind: .rectangle, width: 0.3, height: 0.05, fillHex: "#00FF00")
        let r = render([turned], at: 1)
        #expect(pixel(r, 160 + 25, 90 + 25).g > 150 && pixel(r, 160 - 25, 90 - 25).g > 150, "turned clockwise, the bar's right end goes down and its left end goes up")
        #expect(pixel(r, 160 + 25, 90 - 25).g < 30, "and the other diagonal is empty")
    }

    @Test func aSlideInStartsOffCentreAndSettlesInPlace() {
        var o = TextOverlay.shape(ShapeSpec(kind: .rectangle, width: 0.3, height: 0.2, fillHex: "#0000FF"), start: .zero, end: MediaTime(seconds: 4), x: 0.5, y: 0.5)
        o.fade = 0; o.animationIn = ElementAnimation(kind: .slideLeft, duration: 1)
        let start = render([o], at: 0.3), end = render([o], at: 2)
        #expect(pixel(end, 160, 90).b > 200)
        let (sx, ex) = ((0..<320).first { pixel(start, $0, 90).b > 60 }, (0..<320).first { pixel(end, $0, 90).b > 60 })
        #expect((sx ?? 0) > (ex ?? 0) + 20, "at first it sits to the right of where it ends up: \(String(describing: sx)) vs \(String(describing: ex))")
    }
}
