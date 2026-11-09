import AVFoundation
import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct StabilizerTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// A large patch of fine texture, so there is something to follow.
    private func texture(_ w: Int = 640, _ h: Int = 400) -> CIImage {
        CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)).applyingGaussianBlur(sigma: 1.2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// The part of the texture a camera would see when the picture's content has moved by (dx, dy) (y up): the window moves the other way.
    private func frame(_ tex: CIImage, dx: Double, dy: Double, w: Int, h: Int) -> CIImage {
        let ox = 100 - dx, oy = 100 - dy
        return tex.cropped(to: CGRect(x: ox, y: oy, width: Double(w), height: Double(h))).transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
    }

    private func buffer(_ img: CIImage, w: Int, h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        ctx.render(img, to: pb!)
        return pb!
    }

    @Test func theMeasuredMovementHasTheSignOfTheContentsOwnMovement() throws {
        let tex = texture()
        let a = buffer(frame(tex, dx: 0, dy: 0, w: 320, h: 180), w: 320, h: 180)
        let b = buffer(frame(tex, dx: 6, dy: 4, w: 320, h: 180), w: 320, h: 180)         // the content moved right by 6 and up by 4
        let m = try #require(Stabilizer.motion(from: a, to: b))
        #expect(abs(m.0 - 6) < 1.0 && abs(m.1 - 4) < 1.0, "measured \(m)")
        let back = try #require(Stabilizer.motion(from: b, to: a))
        #expect(abs(back.0 + 6) < 1.0 && abs(back.1 + 4) < 1.0, "the other way round: \(back)")
    }

    /// A 320x180 video of the texture, the content displaced by `shifts[i]` in frame i.
    private func makeVideo(_ url: URL, shifts: [(Double, Double)]) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
                                                                           AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let tex = texture()
        for (i, s) in shifts.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer(frame(tex, dx: s.0, dy: s.1, w: 320, h: 180), w: 320, h: 180), withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    /// Slow drift plus quick jitter, the way a hand-held camera moves.
    private func shakyShifts(_ n: Int) -> [(Double, Double)] {
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) % 1000) / 1000 - 0.5 }
        return (0..<n).map { i in (Double(i) * 0.4 + rnd() * 10, sin(Double(i) / 12) * 6 + rnd() * 8) }
    }

    @Test func theAnalysisFollowsTheShakeOfARealVideo() async throws {
        let shifts = shakyShifts(60)
        let url = Fixtures.shared.outputURL("shaky.mp4")
        try await makeVideo(url, shifts: shifts)
        Stabilizer.cacheFolder = Fixtures.shared.root.appendingPathComponent("stab-cache-\(UUID().uuidString.prefix(6))")
        let path = try await Stabilizer.analyze(url)
        #expect(path.frameCount == 60 && abs(path.fps - 30) < 0.5)
        // The analysis is made 1.5 times bigger than the video (480 across instead of 320).
        let k = Double(path.width) / 320
        var worst = 0.0
        for i in 0..<60 { worst = max(worst, abs(Double(path.x[i]) - (shifts[i].0 - shifts[0].0) * k), abs(Double(path.y[i]) - (shifts[i].1 - shifts[0].1) * k)) }
        #expect(worst < 6, "the followed path stays within a few pixels of the true one: worst \(worst)")
        #expect(Stabilizer.cachedPath(for: url) == path, "kept for next time")
        let again = try await Stabilizer.analyze(url)
        #expect(again == path, "the second time it is read, not worked out")
    }

    @Test func steadyingRemovesTheJitterAndKeepsTheSlowDrift() {
        let n = 90
        var seed: UInt64 = 3
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) % 1000) / 1000 - 0.5 }
        let x = (0..<n).map { Float(Double($0) * 0.5 + rnd() * 12) }, y = (0..<n).map { _ in Float(rnd() * 10) }
        let path = StabilizationPath(fps: 30, width: 480, height: 270, x: x, y: y)
        let plan = Stabilizer.plan(for: path, strength: 0.7)
        #expect(plan.dx.count == n && plan.dy.count == n)
        func variance(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(v.count); return v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count) }
        func detrended(_ v: [Double]) -> [Double] { zip(v, v.indices).map { $0 - Double($1) * 0.5 } }
        let rawJitter = variance(y.map(Double.init)), steadied = variance((0..<n).map { Double(y[$0]) + Double(plan.dy[$0]) * 270 })
        #expect(steadied < rawJitter * 0.35, "vertical jitter before \(rawJitter) after \(steadied)")
        let xs = variance(detrended((0..<n).map { Double(x[$0]) + Double(plan.dx[$0]) * 480 })), xr = variance(detrended(x.map(Double.init)))
        #expect(xs < xr * 0.35, "horizontal jitter before \(xr) after \(xs)")
        #expect(plan.zoom > 1 && plan.zoom < 1.8, "the picture is enlarged a little to hide the edges: \(plan.zoom)")
    }

    @Test func aStrongerSettingSmoothsMoreAndZoomsInMore() {
        let n = 120
        var seed: UInt64 = 11
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) % 1000) / 1000 - 0.5 }
        let x = (0..<n).map { Float(sin(Double($0) / 20) * 20 + rnd() * 8) }
        let path = StabilizationPath(fps: 30, width: 480, height: 270, x: x, y: [Float](repeating: 0, count: n))
        let light = Stabilizer.plan(for: path, strength: 0.1), strong = Stabilizer.plan(for: path, strength: 1)
        func spread(_ p: StabilizerPlan) -> Double { (0..<n).map { abs(Double(p.dx[$0])) }.reduce(0, +) }
        #expect(spread(strong) > spread(light), "a strong setting corrects by more")
        #expect(strong.zoom >= light.zoom)
        #expect(Stabilizer.plan(for: StabilizationPath(fps: 30, width: 10, height: 10, x: [0], y: [0]), strength: 0.5).dx.isEmpty, "a single frame has nothing to steady")
    }

    @Test func aFileWithoutPictureCannotBeAnalysed() async throws {
        let audio = try await Fixtures.shared.source(.init(seconds: 2, audio: true))
        _ = audio
        let missing = URL(fileURLWithPath: "/nonexistent/none.mp4")
        await #expect(throws: (any Error).self) { _ = try await Stabilizer.analyze(missing) }
    }

    /// How jerky a path is: the spread of the movement from one frame to the next.
    private func jerk(_ p: StabilizationPath) -> Double {
        let d = (1..<p.frameCount).map { Double(p.x[$0] - p.x[$0 - 1]) }, e = (1..<p.frameCount).map { Double(p.y[$0] - p.y[$0 - 1]) }
        func v(_ a: [Double]) -> Double { let m = a.reduce(0, +) / Double(a.count); return a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count) }
        return v(d) + v(e)
    }

    @Test func anExportedVideoIsSteadierThanTheOneItCameFrom() async throws {
        let url = Fixtures.shared.outputURL("shaky-export-src.mp4")
        try await makeVideo(url, shifts: shakyShifts(90))
        Stabilizer.cacheFolder = Fixtures.shared.root.appendingPathComponent("stab-cache-\(UUID().uuidString.prefix(6))")
        var look = VideoLook(); look.stabilize = 0.8
        let out = Fixtures.shared.outputURL("shaky-export-steady.mp4")
        // No analysis exists yet: the export makes it.
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)), look: look)], recipe: RenderRecipe(look: look), to: out, options: ExportOptions(mode: .exact, container: .mp4, codec: .h264))
        let before = try #require(Stabilizer.cachedPath(for: url)), after = try await Stabilizer.analyze(out)
        #expect(jerk(after) < jerk(before) * 0.5, "frame-to-frame jerk before \(jerk(before)) after \(jerk(after))")
    }

    @Test func aPreviewUsesTheAnalysisWhenThereIsOneAndNeverWaitsForOne() async throws {
        let url = Fixtures.shared.outputURL("shaky-preview-src.mp4")
        try await makeVideo(url, shifts: shakyShifts(45))
        Stabilizer.cacheFolder = Fixtures.shared.root.appendingPathComponent("stab-cache-\(UUID().uuidString.prefix(6))")
        var look = VideoLook(); look.stabilize = 0.6
        let piece = RenderPiece(sourceURL: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 1.5)), look: look)
        let t0 = Date()
        let cold = try await CompositionBuilder.build(pieces: [piece], frameAccurate: false)
        #expect(Date().timeIntervalSince(t0) < 2, "a preview does not stop to analyse")
        #expect((cold.videoComposition?.instructions.first as? RecipeInstruction)?.plan.stabilizer == nil)
        _ = try await Stabilizer.analyze(url)
        let warm = try await CompositionBuilder.build(pieces: [piece], frameAccurate: false)
        #expect((warm.videoComposition?.instructions.first as? RecipeInstruction)?.plan.stabilizer?.dx.count == 45, "with an analysis it is used")
    }
}
