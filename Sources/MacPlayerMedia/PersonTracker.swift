import AVFoundation
import CoreImage
import Foundation
import MacPlayerCore
import Vision

/// Finds where the people are in a video (0.21), with the Mac's own Vision, on this Mac only: frames are looked at a few times a second,
/// and each gives the area-weighted middle of the people found (the biggest count most: the player in front, not the crowd).
public enum PersonTracker {
    /// For tests: replaces Vision (synthetic pictures have no people). Given a frame, returns boxes (0…1, top-left origin).
    nonisolated(unsafe) public static var detector: ((CGImage) -> [CGRect])?

    /// Looks at `span` of the video (source seconds), about `every` seconds apart (more apart for long clips: at most `maxFrames` looks).
    /// `progress` gets 0…1. Times in the result are source seconds; places are 0…1 of the upright frame, top-left origin.
    public static func track(url: URL, span: TimeSpan, every: Double = 0.25, maxFrames: Int = 900,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> [PersonSample] {
        let asset = AVURLAsset(url: url)
        let length = span.duration.seconds
        guard length > 0 else { return [] }
        let step = max(every, length / Double(maxFrames))
        var times: [Double] = []
        var t = span.start.seconds
        while t < span.end.seconds { times.append(t); t += step }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)
        var out: [PersonSample] = []
        var last: (x: Double, y: Double)?
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { out.append(PersonSample(time: t, center: nil)); continue }
            let found = boxes(in: img)
            let c = pick(found, near: last)
            if c != nil { last = c }
            var sample = PersonSample(time: t, center: c)
            sample.main = center(of: Array(found.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(1)))
            out.append(sample)
            progress?(Double(i + 1) / Double(times.count))
        }
        return out
    }

    /// The person to follow (0.21.1): among the people big enough to matter (at least a quarter of the biggest), the one nearest to the
    /// one followed so far, so the frame stays on one player instead of hopping between the three biggest; the biggest when nobody is
    /// near (or at the start). A crowd far away never pulls the frame.
    public static func pick(_ boxes: [CGRect], near last: (x: Double, y: Double)?) -> (x: Double, y: Double)? {
        let big = boxes.map { $0.width * $0.height }.max() ?? 0
        let candidates = boxes.filter { $0.width * $0.height >= big * 0.25 }
        guard let biggest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        guard let last else { return (Double(biggest.midX), Double(biggest.midY)) }
        func dist(_ b: CGRect) -> Double { hypot(Double(b.midX) - last.x, Double(b.midY) - last.y) }
        if let near = candidates.min(by: { dist($0) < dist($1) }), dist(near) < 0.2 { return (Double(near.midX), Double(near.midY)) }
        return (Double(biggest.midX), Double(biggest.midY))
    }

    /// People in a picture: whole bodies, else faces. Boxes are 0…1 from the top-left.
    static func boxes(in img: CGImage) -> [CGRect] {
        if let d = detector { return d(img) }
        let body = VNDetectHumanRectanglesRequest()
        body.upperBodyOnly = false
        let face = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([body, face])
        var found = (body.results ?? []).filter { $0.confidence > 0.3 }.map(\.boundingBox)
        if found.isEmpty { found = (face.results ?? []).map(\.boundingBox) }
        // Vision's origin is bottom-left.
        return found.map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) }
    }

    /// The area-weighted middle of the three biggest boxes (one big player near the camera outweighs a group far away).
    public static func center(of boxes: [CGRect]) -> (x: Double, y: Double)? {
        let top = boxes.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(3)
        let total = top.reduce(0) { $0 + $1.width * $1.height }
        guard total > 0 else { return nil }
        let x = top.reduce(0) { $0 + $1.midX * $1.width * $1.height } / total
        let y = top.reduce(0) { $0 + $1.midY * $1.width * $1.height } / total
        return (Double(x), Double(y))
    }
}
