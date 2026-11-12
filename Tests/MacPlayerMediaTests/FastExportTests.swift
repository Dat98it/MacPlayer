import AVFoundation
import CoreVideo
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// 0.16.4: exports skip work on pictures that do not change — a frame like the one before is neither drawn again nor encoded again,
/// and a timeline where nothing moves is drawn 4 times a second. What is seen must stay exactly what it was.
@Suite(.serialized) struct FastExportTests {
    private func buffer(_ value: UInt8, width: Int = 64, height: Int = 32, padTo rowBytes: Int? = nil) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferBytesPerRowAlignmentKey as String: rowBytes ?? 64] as CFDictionary, &pb)
        let b = try #require(pb)
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!, rb = CVPixelBufferGetBytesPerRow(b)
        memset(base, 0x5A, rb * height)                       // padding gets something else
        for y in 0..<height { memset(base + y * rb, Int32(value), width * 4) }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    @Test func repeatedPicturesAreFoundAndChangedOnesAreNot() throws {
        let a = try buffer(10), b = try buffer(10), c = try buffer(11)
        #expect(RepeatSkipper.same(a, a) && RepeatSkipper.same(a, b))
        #expect(!RepeatSkipper.same(a, c))
        // One pixel different, in a row the quick look does not sample: still told apart.
        let d = try buffer(10)
        CVPixelBufferLockBaseAddress(d, []); (CVPixelBufferGetBaseAddress(d)! + 7 * CVPixelBufferGetBytesPerRow(d) + 13).storeBytes(of: 99, as: UInt8.self); CVPixelBufferUnlockBaseAddress(d, [])
        #expect(!RepeatSkipper.same(a, d))
        // Different sizes are different pictures.
        #expect(!RepeatSkipper.same(a, try buffer(10, width: 32)))
    }

    @Test func nothingMovesOnlyWhenNothingFadesAnimatesOrIsKeyed() {
        let piece = RenderPiece(sourceURL: URL(fileURLWithPath: "/x.mov"), span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)))
        var text = TextOverlay(text: "A", start: .zero, end: MediaTime(seconds: 1)); text.fade = 0
        #expect(CompositionBuilder.nothingMoves(pieces: [piece], overlays: [text], layers: []))
        var faded = text; faded.fade = 0.2
        #expect(!CompositionBuilder.nothingMoves(pieces: [piece], overlays: [faded], layers: []))
        var animated = text; animated.animationIn = ElementAnimation(kind: .zoom, duration: 0.4)
        #expect(!CompositionBuilder.nothingMoves(pieces: [piece], overlays: [animated], layers: []))
        var zoom = piece; zoom.look.motion = [MotionKeyframe(time: 0, scale: 1), MotionKeyframe(time: 1, scale: 1.2)]
        #expect(!CompositionBuilder.nothingMoves(pieces: [zoom], overlays: [], layers: []))
        let videoLayer = LayerSpec(kind: .video(path: "/v.mov", sourceStart: .zero, sourceEnd: MediaTime(seconds: 1)), lane: 0, start: .zero, duration: MediaTime(seconds: 1))
        #expect(!CompositionBuilder.nothingMoves(pieces: [piece], overlays: [], layers: [videoLayer]))
        let logo = LayerSpec(kind: .image(path: "/l.png"), lane: 0, start: .zero, duration: MediaTime(seconds: 1))
        #expect(CompositionBuilder.nothingMoves(pieces: [piece], overlays: [], layers: [logo]))
    }

    @Test func aTitleOverAStillPictureComesAndGoesAtItsTimes() async throws {
        // The default folder: StillClipTests changes `cacheFolder` while its own tests run.
        let photo = Fixtures.shared.outputURL("fast-photo", ext: "png")
        let ctx = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        try ImageWriter.write(try #require(ctx.makeImage()), to: photo, format: .png)
        let still = try await StillClip.make(from: photo)
        var title = TextOverlay(text: "HELLO", start: MediaTime(seconds: 1), end: MediaTime(seconds: 2), sizeFraction: 0.25, colorHex: "#FFFFFF", x: 0.5, y: 0.5)
        title.fade = 0
        let out = Fixtures.shared.outputURL("fast-title")
        let reusedBefore = StillFrameKey.reused
        let t0 = Date()
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: still, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)))],
                                          recipe: RenderRecipe(overlays: [title]), to: out, options: ExportOptions(mode: .exact))
        let took = Date().timeIntervalSince(t0)
        func white(_ t: Double) async throws -> Int {
            let px = try await frame(out, at: t)
            var n = 0
            for y in stride(from: 60, to: 120, by: 2) { for x in stride(from: 60, to: 260, by: 2) { let c = px.rgb(x, y); if c.r > 200 && c.g > 200 && c.b > 200 { n += 1 } } }
            return n
        }
        let before = try await white(0.5), during = try await white(1.5), after = try await white(2.6)
        #expect(before == 0 && after == 0 && during > 100, "the title only between 1 and 2 s: \(before) / \(during) / \(after)")
        let early = try await white(0.9), late = try await white(2.1)
        #expect(early == 0 && late == 0, "it does not show early or stay late (on a quarter of a second): \(early) / \(late)")
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 3) < 0.05)
        #expect(StillFrameKey.reused > reusedBefore, "repeated frames are handed over, not drawn again")
        #expect(took < 5, "\(took) s")
    }

    @Test func aMovingVideoKeepsEveryFrame() async throws {
        let src = try await Fixtures.shared.source()          // a frame number on every frame: no two are the same
        var look = VideoLook(); look.color.exposure = 0.0001
        let out = Fixtures.shared.outputURL("fast-moving")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 90), look: look)], recipe: RenderRecipe(look: look), to: out, options: ExportOptions(mode: .exact))
        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil); reader.add(o); reader.startReading()
        var n = 0
        while let sb = o.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
        #expect(n == 90, "3 s at 30 fps: \(n) frames")
        #expect(try await track.load(.nominalFrameRate) > 29)
    }
}
