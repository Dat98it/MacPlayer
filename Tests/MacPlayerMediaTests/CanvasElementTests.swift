import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Elements moved right on the picture: the preview follows a drag at once (`ElementLive`), an export never does, and the frames drawn over the
/// picture sit where the renderer draws.
@Suite(.serialized) struct CanvasElementTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let size = CGSize(width: 200, height: 100)

    private func alpha(_ layer: OverlayLayer, x: Int, y: Int) -> Int {
        guard let (img, _) = layer.visible(at: 0.5, size: size).first else { return 0 }
        var bytes = [UInt8](repeating: 0, count: 4)
        ctx.render(img, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: Int(size.height) - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Int(bytes[3])
    }

    @Test func aPreviewFollowsADragAtOnceAndAnExportNever() {
        let o = TextOverlay.shape(ShapeSpec(kind: .rectangle, width: 0.2, height: 0.4), start: .zero, end: MediaTime(seconds: 2), x: 0.25, y: 0.5)
        let preview = OverlayLayer(overlays: [o], cues: [], style: SubtitleStyle(), live: true)
        let export = OverlayLayer(overlays: [o], cues: [], style: SubtitleStyle(), live: false)
        ElementLive.clear()
        #expect(alpha(preview, x: 50, y: 50) > 200 && alpha(preview, x: 150, y: 50) == 0, "as built: on the left")
        ElementLive.set(.init(x: 0.75, y: 0.5, scale: 1), for: o.id)
        #expect(alpha(preview, x: 150, y: 50) > 200 && alpha(preview, x: 50, y: 50) == 0, "dragged: on the right at once")
        #expect(alpha(export, x: 50, y: 50) > 200 && alpha(export, x: 150, y: 50) == 0, "an export draws what is saved")
        ElementLive.set(.init(x: 0.25, y: 0.5, scale: 2), for: o.id)
        #expect(alpha(preview, x: 50 + 30, y: 50) > 200, "sized up twice: it reaches further out")
        ElementLive.clear()
        #expect(alpha(preview, x: 50 + 30, y: 50) == 0, "cleared: back to what the preview was built with")
    }

    @Test func theFramesSitWhereTheElementsAreDrawn() throws {
        let s = TextOverlay.shape(ShapeSpec(kind: .ellipse, width: 0.3, height: 0.2), start: .zero, end: MediaTime(seconds: 1), x: 0.6, y: 0.4)
        let r = try #require(ElementGeometry.baseRect(s, pictureSize: CGSize(width: 1600, height: 900)))
        #expect(abs(r.midX - 0.6) < 1e-9 && abs(r.midY - 0.4) < 1e-9 && abs(r.width - 0.3) < 1e-9)
        var t = TextOverlay(text: "Hello there", start: .zero, end: MediaTime(seconds: 1), sizeFraction: 0.1, y: 0.3)
        t.x = 0.4
        let a = try #require(ElementGeometry.baseRect(t, pictureSize: CGSize(width: 1600, height: 900)))
        let b = try #require(ElementGeometry.baseRect(t, pictureSize: CGSize(width: 800, height: 450)))
        #expect(abs(a.midX - 0.4) < 0.01 && abs(a.midY - 0.3) < 0.02 && a.height > 0.08 && a.height < 0.2, "centred on the text, a line high: \(a)")
        #expect(abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01, "the same at any size of the same shape")
        // The renderer really draws inside that box.
        let img = try #require(OverlayRenderer.render(OverlayRenderer.box(for: t), size: CGSize(width: 1600, height: 900)))
        let px = rgbaBytes(img)
        var inside = 0
        for i in 0..<40 {
            let x = Int((a.minX + a.width * Double(i) / 40) * 1600), y = Int(a.midY * 900)
            if px.bytes[(y * px.width + x) * 4 + 3] > 0 { inside += 1 }
        }
        #expect(inside > 5, "letters are drawn along the middle of the box (\(inside) of 40 samples)")
        #expect(ElementGeometry.baseRect(TextOverlay(text: "  ", start: .zero, end: MediaTime(seconds: 1)), pictureSize: CGSize(width: 1600, height: 900)) == nil)
    }

    @Test func aSquareShapeIsDrawnSquareOnAWidePicture() throws {
        let size = CGSize(width: 320, height: 180)
        let spec = ShapeSpec.made(.rectangle, width: 0.25, aspect: size.width / size.height)
        let img = try #require(OverlayRenderer.renderShape(spec, centerX: 0.5, centerY: 0.5, size: size))
        let px = rgbaBytes(img)
        func filled(_ x: Int, _ y: Int) -> Bool { px.bytes[(y * px.width + x) * 4 + 3] > 128 }
        let w = (0..<320).filter { filled($0, 90) }.count, h = (0..<180).filter { filled(160, $0) }.count
        #expect(abs(w - h) <= 1 && w == 80, "as many pixels wide as high: \(w) × \(h)")
    }

    @Test func everyShapeIsDrawnAndTheRingHasAHole() throws {
        let size = CGSize(width: 200, height: 200)
        for k in ShapeKind.allCases {
            let img = try #require(OverlayRenderer.renderShape(ShapeSpec.made(k, width: 0.6, aspect: 1), centerX: 0.5, centerY: 0.5, size: size), "\(k)")
            let b = rgbaBytes(img).bytes
            let ink = stride(from: 3, to: b.count, by: 4).filter { b[$0] > 128 }.count
            #expect(ink > (k == .line ? 60 : 200), "\(k) draws something (\(ink) pixels)")
            if k == .ring { #expect(b[(100 * 200 + 100) * 4 + 3] == 0 && b[(100 * 200 + 42) * 4 + 3] > 128, "the ring is empty in the middle and solid at its edge") }
        }
    }
}

/// The picture's pixels (RGBA, the top row first), drawn into memory that the context owns. (Handing it `&array` is wrong: that pointer is only
/// good during the call, and drawing later wrote over memory the test no longer owned — the test process then died now and then.)
func rgbaBytes(_ img: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return ([], 0, 0) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    // A bitmap context's memory starts with the top row.
    return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)), w, h)
}
