import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// 0.16.5, drawn: things in full while the editor is paused, pictures stretched, motions that move, every new style and shape.
@Suite(.serialized) struct EditorDrawingTests {
    private let size = CGSize(width: 320, height: 180)

    private func opaquePixels(_ img: CIImage) -> Int {
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = ctx.createCGImage(img.cropped(to: CGRect(origin: .zero, size: size)), from: CGRect(origin: .zero, size: size)) else { return 0 }
        let p = Pixels(cg); var n = 0
        for y in stride(from: 0, to: p.height, by: 2) { for x in stride(from: 0, to: p.width, by: 2) { let c = p.rgb(x, y); if c.r + c.g + c.b > 60 { n += 1 } } }
        return n
    }

    @Test func aStickerAddedAtThePlayheadIsDrawnWhilePausedAndAnimatesWhilePlaying() {
        var o = TextOverlay(text: "■", start: MediaTime(seconds: 2), end: MediaTime(seconds: 5), sizeFraction: 0.4, colorHex: "#FFFFFF", x: 0.5, y: 0.5, fade: 0)
        o.animationIn = ElementAnimation(kind: .pop, duration: 0.4)
        let preview = OverlayLayer(overlays: [o], cues: [], style: SubtitleStyle(), live: true)
        let was = ElementLive.paused
        defer { ElementLive.paused = was }
        ElementLive.paused = true
        #expect(preview.visible(at: 2, size: size).first?.1 == 1, "paused at its first instant: drawn in full")
        ElementLive.paused = false
        #expect(preview.visible(at: 2, size: size).isEmpty, "playing: its arrival starts see-through, as in the export")
        // An export never settles.
        ElementLive.paused = true
        let export = OverlayLayer(overlays: [o], cues: [], style: SubtitleStyle(), live: false)
        #expect(export.visible(at: 2, size: size).isEmpty)
    }

    @Test func aStretchedPictureIsDrawnInItsStretchedShape() {
        let square = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        func drawn(stretch: Double) -> CGRect {
            var spec = LayerSpec(kind: .image(path: "x"), lane: 0, start: .zero, duration: MediaTime(seconds: 1))
            spec.transform.centerX = 0.5; spec.transform.centerY = 0.5; spec.transform.width = 0.25; spec.transform.stretch = stretch
            let out = RecipeCompositor.drawLayer(square, spec: spec, border: CIColor(red: 0, green: 0, blue: 0), time: 0.5, subjectMode: .photo,
                                                 over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size)), frame: CGRect(origin: .zero, size: size))
            let ctx = CIContext(options: [.workingColorSpace: NSNull()])
            let p = Pixels(ctx.createCGImage(out, from: CGRect(origin: .zero, size: size))!)
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in 0..<p.height { for x in 0..<p.width where p.isRed(x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        let own = drawn(stretch: 1), tall = drawn(stretch: 1.5)
        #expect(abs(own.width - 80) <= 1 && abs(own.height - 80) <= 1, "a quarter of the width, square: \(own)")
        #expect(abs(tall.width - 80) <= 1 && abs(tall.height - 120) <= 1, "same width, half as tall again: \(tall)")
    }

    @Test func aMotionMovesTheStickerInTheExport() async throws {
        let src = try await Fixtures.shared.source()
        var look = VideoLook(); look.color.exposure = 0.0001
        var o = TextOverlay(text: "■", start: .zero, end: MediaTime(seconds: 2), sizeFraction: 0.3, colorHex: "#FFFFFF", x: 0.5, y: 0.5, fade: 0)
        o.loop = ElementLoop(kind: .sway, period: 1, strength: 3)
        let out = Fixtures.shared.outputURL("loop-sway")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 60), look: look)], recipe: RenderRecipe(look: look, overlays: [o]), to: out, options: ExportOptions(mode: .exact))
        func centreX(_ t: Double) async throws -> Double {
            let p = try await frame(out, at: t)
            var sum = 0.0, n = 0.0
            for y in stride(from: 70, to: 110, by: 2) { for x in 0..<p.width { let c = p.rgb(x, y); if c.r > 230 && c.g > 230 && c.b > 230 { sum += Double(x); n += 1 } } }
            return n > 0 ? sum / n : -1
        }
        let mid = try await centreX(0.0), right = try await centreX(0.25), left = try await centreX(0.75)
        #expect(right > mid + 10 && left < mid - 10, "it sways: \(left) / \(mid) / \(right)")
        // Something that moves by itself is never drawn at the slow still pace.
        #expect(!CompositionBuilder.nothingMoves(pieces: [], overlays: [o], layers: []))
    }

    @Test func everyShapeAndEveryStyleDraws() {
        for k in ShapeKind.allCases {
            let spec = ShapeSpec.made(k, width: 0.3, aspect: 16.0 / 9)
            let img = OverlayRenderer.renderShape(spec, centerX: 0.5, centerY: 0.5, size: size)
            #expect(img.map { opaquePixels(CIImage(cgImage: $0)) } ?? 0 > 30, "\(k) draws")
        }
        for t in TextTemplate.allCases {
            var o = TextOverlay(text: "Xin chào", start: .zero, end: MediaTime(seconds: 1)); t.apply(to: &o)
            // The font is on this Mac (not silently replaced by another).
            let f = CTFontCreateWithName(o.fontName as CFString, 20, nil)
            #expect(CTFontCopyPostScriptName(f) as String == o.fontName, "\(t): \(o.fontName)")
            let layer = OverlayLayer(overlays: [o], cues: [], style: SubtitleStyle())
            #expect(!layer.visible(at: 0.9, size: size).isEmpty, "\(t) draws")
        }
    }
}
