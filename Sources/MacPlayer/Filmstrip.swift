import AppKit
import AVFoundation
import MacPlayerCore

extension Notification.Name {
    /// The small pictures of a video for the timeline are ready (object: the file's path).
    static let filmstripReady = Notification.Name("MacPlayer.filmstripReady")
}

/// Small pictures along each video, drawn on its clips in the timeline so a clip can be recognised at a glance. Read once per file in the
/// background (nearest keyframes, which is quick), and kept for every window.
@MainActor
final class FilmstripCache {
    static let shared = FilmstripCache()
    /// Pictures of each file, by time (seconds into the file), in order.
    private(set) var strips: [String: [(Double, NSImage)]] = [:]
    private var loading: Set<String> = []
    /// How many files were read (for the self-test).
    private(set) var reads = 0

    /// The pictures of the file, or nil while they are read (they are asked for once; `filmstripReady` says when they are there).
    func strip(for path: String, duration: Double) -> [(Double, NSImage)]? {
        if let s = strips[path] { return s }
        guard !loading.contains(path), duration > 0 else { return nil }
        loading.insert(path); reads += 1
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .utility) {
            let count = max(6, min(90, Int(duration / 2)))
            let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * duration / Double(count), preferredTimescale: 600) }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 0, height: 96)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            final class Out: @unchecked Sendable { var frames: [(Double, CGImage)] = [] }
            let out = Out()
            for await r in gen.images(for: times) {
                if let img = try? r.image { out.frames.append((r.requestedTime.seconds, img)) }
            }
            let frames = out.frames.sorted { $0.0 < $1.0 }
            await MainActor.run {
                FilmstripCache.shared.finish(path, frames.map { ($0.0, NSImage(cgImage: $0.1, size: NSSize(width: $0.1.width, height: $0.1.height))) })
            }
        }
        return nil
    }

    private func finish(_ path: String, _ frames: [(Double, NSImage)]) {
        loading.remove(path)
        strips[path] = frames
        NotificationCenter.default.post(name: .filmstripReady, object: path)
    }

    /// The picture nearest to `t` seconds into the file.
    static func nearest(_ strip: [(Double, NSImage)], _ t: Double) -> NSImage? {
        guard !strip.isEmpty else { return nil }
        var lo = 0, hi = strip.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if strip[mid].0 < t { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(strip[lo - 1].0 - t) < abs(strip[lo].0 - t) { return strip[lo - 1].1 }
        return strip[lo].1
    }
}
