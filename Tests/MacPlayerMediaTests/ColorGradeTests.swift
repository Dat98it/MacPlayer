import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// The colour tools drawn on pictures made for the purpose: the cube does what the numbers in `ColorGrading` say.
@Suite(.serialized) struct ColorGradeTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    private func pixel(_ image: CIImage) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    @Test func aNeutralGradeLeavesTheColoursAlone() {
        let src = solid(0.3, 0.5, 0.8)
        let before = pixel(src)
        let after = pixel(ColorGradeRenderer.apply(ColorAdjust(), to: src))
        #expect(before == after)
        // The finer tools set but then moved back to nothing are neutral again.
        var c = ColorAdjust(); c.exposure = 0.4; c.exposure = 0
        #expect(pixel(ColorGradeRenderer.apply(c, to: src)) == before)
    }

    @Test func aCurveGivesThePixelValueTheNumbersPromise() {
        var c = ColorAdjust()
        c.curves.setPoints([CurvePoint(x: 0.5, y: 0.8)], for: .master)
        let p = pixel(ColorGradeRenderer.apply(c, to: solid(0.5, 0.5, 0.5)))
        let want = Int((CurveMath.value(c.curves.master, at: 128.0 / 255) * 255).rounded())
        #expect(abs(p.r - want) <= 3 && abs(p.g - want) <= 3 && abs(p.b - want) <= 3, "got \(p), wanted about \(want)")
        #expect(p.r > 190, "a plain mid-grey became much lighter")
    }

    @Test func eachToolChangesThePictureTheWayItIsNamed() {
        let mid = solid(0.5, 0.5, 0.5), base = pixel(mid)
        var e = ColorAdjust(); e.exposure = 0.6
        #expect(pixel(ColorGradeRenderer.apply(e, to: mid)).r > base.r + 20)
        var t = ColorAdjust(); t.tint = 1
        let m = pixel(ColorGradeRenderer.apply(t, to: mid))
        #expect(m.r > m.g && m.b > m.g, "magenta: green is held back")
        var w = ColorAdjust(); w.wheels.midtones = ColorWheel(x: 0, y: -1)      // up on the wheel is green-yellow
        let tinted = pixel(ColorGradeRenderer.apply(w, to: mid))
        #expect(tinted.r != tinted.b || tinted.g != tinted.b)
        var h = ColorAdjust(); h.hsl[.red] = HSLAdjust(hue: 0, saturation: -1, luminance: 0)
        let red = pixel(ColorGradeRenderer.apply(h, to: solid(0.9, 0.2, 0.2)))
        #expect(abs(red.r - red.g) < 60, "red lost most of its colour, got \(red)")
    }

    @Test func aLookFileIsReadFromDiskAndUsed() throws {
        // red and blue swapped
        let text = "LUT_3D_SIZE 2\n0 0 0\n0 0 1\n0 1 0\n0 1 1\n1 0 0\n1 0 1\n1 1 0\n1 1 1\n"
        let path = NSTemporaryDirectory() + "swap-\(UUID().uuidString).cube"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var c = ColorAdjust(); c.lut = LutRef(name: "swap", path: path, strength: 1)
        let p = pixel(ColorGradeRenderer.apply(c, to: solid(1, 0, 0)))
        #expect(p.r < 40 && p.b > 215, "red became blue, got \(p)")
        #expect(LutStore.isUsable(path: path))
        c.lut = LutRef(name: "gone", path: "/nonexistent/x.cube", strength: 1)
        #expect(!LutStore.isUsable(path: "/nonexistent/x.cube"))
        let unchanged = pixel(ColorGradeRenderer.apply(c, to: solid(1, 0, 0)))
        #expect(unchanged.r > 215 && unchanged.b < 40, "a look that cannot be read leaves the picture as it is, got \(unchanged)")
    }

    @Test func theSmallPicturesOfTheInterfaceUseTheSameRecipe() {
        var c = ColorAdjust(); c.exposure = 0.5
        let src = ctx.createCGImage(solid(0.4, 0.4, 0.4), from: CGRect(x: 0, y: 0, width: 16, height: 16))!
        let out = EffectPreview.image(from: src, colour: c)
        #expect(out != nil && out!.width == 16)
    }

    // MARK: Whole export

    private func export(_ src: URL, _ name: String, colour: ColorAdjust) async throws -> URL {
        var look = VideoLook(); look.color = colour
        let out = Fixtures.shared.outputURL(name)
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 30), look: look)], recipe: RenderRecipe(look: look), to: out, options: ExportOptions(mode: .exact))
        return out
    }

    @Test func anExportedVideoCarriesTheGrade() async throws {
        let src = try await Fixtures.shared.source()
        // Engages the compositor with a hair of brightness; the real change is the exposure and the red curve.
        var plain = ColorAdjust(); plain.brightness = 0.0001
        var graded = plain; graded.exposure = 0.5; graded.curves.setPoints([CurvePoint(x: 0.5, y: 0.7)], for: .red)
        let a = try await frame(try await export(src, "grade-plain", colour: plain), at: 0.5)
        let b = try await frame(try await export(src, "grade-graded", colour: graded), at: 0.5)
        let pa = a.rgb(a.width / 2, a.height / 2), pb = b.rgb(b.width / 2, b.height / 2)
        #expect(pb.r > pa.r + 20 && pb.g > pa.g + 5, "the grade made the picture lighter and redder: \(pa) -> \(pb)")
        #expect(b.luma(b.width / 2, b.height / 2) > a.luma(a.width / 2, a.height / 2) + 10)
    }

    @Test func aLookFileIsUsedByTheExportToo() async throws {
        let src = try await Fixtures.shared.source()
        // red and blue swapped
        let text = "LUT_3D_SIZE 2\n0 0 0\n0 0 1\n0 1 0\n0 1 1\n1 0 0\n1 0 1\n1 1 0\n1 1 1\n"
        let path = NSTemporaryDirectory() + "swap-export-\(UUID().uuidString).cube"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var c = ColorAdjust(); c.lut = LutRef(name: "swap", path: path, strength: 1)
        // The source has a red marker top-right and a blue one bottom-right: they trade places.
        let f = try await frame(try await export(src, "grade-lut", colour: c), at: 0.5)
        #expect(f.isBlue(f.width - 20, 20), "the red marker became blue")
        #expect(f.isRed(f.width - 20, f.height - 20), "the blue marker became red")
    }
}
