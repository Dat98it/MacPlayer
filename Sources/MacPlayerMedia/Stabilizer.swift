import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import MacPlayerCore
import Vision

/// How the camera moved, frame by frame, found by following the picture (translation only: shake, not rotation).
public struct StabilizationPath: Codable, Equatable, Sendable {
    /// Frames per second of the analysed video, and the size the analysis was done at.
    public var fps: Double
    public var width: Int
    public var height: Int
    /// Where the picture's content is at each frame compared with the first frame, in analysis pixels, y up (Core Image's way).
    public var x: [Float]
    public var y: [Float]
    public var frameCount: Int { x.count }
}

/// What the renderer needs to steady one clip: a correction for each source frame, as a fraction of the picture size, and how far to
/// zoom in so the moved picture never shows an empty edge.
public struct StabilizerPlan: Sendable {
    public var fps: Double
    public var dx: [Float]
    public var dy: [Float]
    public var zoom: Double
}

public enum Stabilizer {
    /// Where analyses are kept. The app points it at its own folder; tests leave it in the temporary folder.
    nonisolated(unsafe) public static var cacheFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("macplayer-stabilization", isDirectory: true)

    public enum StabilizeError: Error, CustomStringConvertible {
        case noVideo, failed(String), cancelled
        public var description: String {
            switch self {
            case .noVideo: return "This file has no picture to steady."
            case .failed(let m): return "Steadying failed: \(m)"
            case .cancelled: return "Steadying was cancelled."
            }
        }
    }

    // MARK: Smoothing (pure maths)

    /// The correction to move each frame by: the path smoothed over a window of frames, minus the path itself. A stronger setting smooths
    /// over a longer time, so slow, deliberate camera moves are kept and only quick shake is taken out.
    public static func plan(for path: StabilizationPath, strength: Double) -> StabilizerPlan {
        let n = path.frameCount
        guard n > 1 else { return StabilizerPlan(fps: path.fps, dx: [], dy: [], zoom: 1) }
        let s = min(max(strength, 0), 1)
        let radius = min(n - 1, max(1, Int((0.15 + 1.35 * s) * path.fps)))            // 0.15 s ... 1.5 s each way
        // A moving average over a window. At the two ends the path is continued by turning it about its end point (an odd reflection), which
        // keeps a steady drift a steady drift instead of flattening it there.
        func smooth(_ v: [Float]) -> [Float] {
            var padded = [Double](); padded.reserveCapacity(n + 2 * radius)
            for k in stride(from: radius, to: 0, by: -1) { padded.append(2 * Double(v[0]) - Double(v[k])) }
            padded.append(contentsOf: v.map(Double.init))
            for k in 1...radius { padded.append(2 * Double(v[n - 1]) - Double(v[n - 1 - k])) }
            var prefix = [Double](repeating: 0, count: padded.count + 1)
            for i in 0..<padded.count { prefix[i + 1] = prefix[i] + padded[i] }
            return (0..<n).map { i in Float((prefix[i + 2 * radius + 1] - prefix[i]) / Double(2 * radius + 1)) }
        }
        let sx = smooth(path.x), sy = smooth(path.y)
        var dx = [Float](), dy = [Float](); dx.reserveCapacity(n); dy.reserveCapacity(n)
        var worst = 0.0
        for i in 0..<n {
            let cx = sx[i] - path.x[i], cy = sy[i] - path.y[i]
            dx.append(cx / Float(path.width)); dy.append(cy / Float(path.height))
            worst = max(worst, abs(Double(cx)) / Double(path.width), abs(Double(cy)) / Double(path.height))
        }
        // Moving a picture by a fraction f of its size uncovers f at one edge; zooming by 1 + 2f hides it. A little extra for safety.
        return StabilizerPlan(fps: path.fps, dx: dx, dy: dy, zoom: 1 + 2 * min(worst, 0.3) * 1.04 + 0.01)
    }

    // MARK: Analysis

    /// How far the content moved from `previous` to `current` (analysis pixels, y up), by registering one frame against the other.
    static func motion(from previous: CVPixelBuffer, to current: CVPixelBuffer) -> (Double, Double)? {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current)
        let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
        guard (try? handler.perform([request])) != nil, let o = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        // The transform that moves `current` onto `previous`; the content's own movement is the opposite.
        return (-Double(o.alignmentTransform.tx), -Double(o.alignmentTransform.ty))
    }

    public static func cacheURL(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(source.standardizedFileURL.path)|\(size)|\(Int(modified))"
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return cacheFolder.appendingPathComponent(String(format: "%016llx.json", h))
    }

    public static func cachedPath(for source: URL) -> StabilizationPath? {
        guard let d = try? Data(contentsOf: cacheURL(for: source)) else { return nil }
        return try? JSONDecoder().decode(StabilizationPath.self, from: d)
    }

    /// Follows the picture through the whole video (at a reduced size, so it is fast) and keeps the result for next time.
    public static func analyze(_ source: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> StabilizationPath {
        if let hit = cachedPath(for: source) { progress?(1); return hit }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StabilizeError.noVideo }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let nominal = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let rect = natural.applying(transform)
        let display = CGSize(width: abs(rect.width), height: abs(rect.height))
        let w = 480, h = max(2, Int((480 * display.height / max(1, display.width)).rounded()) & ~1)
        let reader = try AVAssetReader(asset: asset)
        // The reader hands over the stored picture; the size asked for here is the stored one scaled down, and the orientation is applied below.
        let stored = CGSize(width: natural.width, height: natural.height)
        let scale = 480 / max(1, display.width)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int((stored.width * scale).rounded()) & ~1), kCVPixelBufferHeightKey as String: max(2, Int((stored.height * scale).rounded()) & ~1)])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw StabilizeError.failed(reader.error?.localizedDescription ?? "cannot read") }
        let orientation = RecipeCompositor.orientation(of: transform)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func upright(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
            var copy: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &copy)
            guard let c = copy else { return nil }
            var img = CIImage(cvPixelBuffer: pb).oriented(orientation)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
            img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
            context.render(img, to: c)
            return c
        }
        var px: [Float] = [0], py: [Float] = [0]
        var previous: CVPixelBuffer?
        var count = 0
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw StabilizeError.cancelled }
            guard let pb = CMSampleBufferGetImageBuffer(sb), let current = upright(pb) else { continue }
            if let prev = previous {
                let m = motion(from: prev, to: current) ?? (0, 0)
                px.append(px.last! + Float(m.0)); py.append(py.last! + Float(m.1))
            }
            previous = current
            count += 1
            if count % 15 == 0, duration > 0 { progress?(min(0.99, CMSampleBufferGetPresentationTimeStamp(sb).seconds / duration)) }
        }
        guard px.count > 1 else { throw StabilizeError.failed("no frames could be read") }
        let result = StabilizationPath(fps: nominal > 0 ? nominal : 30, width: w, height: h, x: px, y: py)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(result).write(to: cacheURL(for: source), options: .atomic)
        progress?(1)
        return result
    }
}
