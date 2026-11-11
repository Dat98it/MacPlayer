import AppKit
import CoreImage
import MacPlayerCore
import MacPlayerMedia

/// The small pictures the tools show (filter tiles, transition tiles, the histogram): taken from the clip under the playhead, quickly
/// (the nearest frame is good enough for a thumbnail), one at a time, and kept, so that going back and forth between tools does not
/// decode the video again and again. Decoding a frame exactly, from the first video at the timeline's time, every quarter of a
/// second while playing, used to fight the player for the decoder: the picture and the interface stuttered (0.8.2).
extension EditorSession {
    /// Where a tool's picture comes from: a file and a time in it.
    struct ToolFrameSource: Equatable {
        var url: URL
        var time: MediaTime
        /// Identifies the picture for the caches (file, half-second, size).
        var key: String
    }

    /// The frame under the playhead (the clip it falls in, at its own time); nil when there is nothing to show.
    func toolFrameSource(maxSize: CGSize) -> ToolFrameSource? {
        let size = "\(Int(maxSize.width))x\(Int(maxSize.height))"
        if isPhoto {
            guard let url = sourceURL else { return nil }
            return ToolFrameSource(url: url, time: .zero, key: "\(url.path)|photo|\(size)")
        }
        if isProject {
            guard let loc = TimelineMap.locate(project.timeline, at: player.currentTime) ?? TimelineMap.locate(project.timeline, at: .zero),
                  project.timeline.indices.contains(loc.index) else { return nil }
            let clip = project.timeline[loc.index]
            guard let url = sourceURLs[clip.sourceID] else { return nil }
            let t = min(max(loc.sourceTime, clip.sourceStart), clip.sourceEnd)
            return ToolFrameSource(url: url, time: t, key: "\(url.path)|\(Int(t.seconds * 2))|\(size)")
        }
        guard let url = sourceURL else { return nil }
        let t = min(max(player.currentTime, .zero), duration)
        return ToolFrameSource(url: url, time: t, key: "\(url.path)|\(Int(t.seconds * 2))|\(size)")
    }

    /// The picture for the tools. A request for the picture already being read waits for that read; the last few pictures are kept.
    func toolFrame(maxSize: CGSize) async -> (image: CGImage, key: String)? {
        guard let src = toolFrameSource(maxSize: maxSize) else { return nil }
        if let hit = ToolFrameCache.shared.frames[src.key] { return (hit, src.key) }
        // While the video plays, the last picture of the same video and size will do: reading a new one would fight the player.
        let fileKey = "\(src.url.path)|\(Int(maxSize.width))x\(Int(maxSize.height))"
        if player.isPlaying, let (img, key) = ToolFrameCache.shared.latest[fileKey] { return (img, key) }
        if let running = ToolFrameCache.shared.reading[src.key] { return await running.value.map { ($0, src.key) } }
        let isPicture = isPhoto
        ToolFrameCache.shared.reads += 1
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            if isPicture { return PhotoLoader.thumbnail(url: src.url, maxSize: maxSize) }
            return try? await FrameGrabber.image(url: src.url, at: src.time, accuracy: .nearest, maxSize: maxSize)
        }
        ToolFrameCache.shared.reading[src.key] = task
        let image = await task.value
        ToolFrameCache.shared.reading[src.key] = nil
        guard let image else { return nil }
        ToolFrameCache.shared.remember(image, for: src.key)
        ToolFrameCache.shared.latest[fileKey] = (image, src.key)
        return (image, src.key)
    }

    /// Draws pictures off the main thread (Core Image), so choosing and switching tools never waits for them.
    nonisolated static func drawOffMain<K: Hashable & Sendable>(_ keys: [K], _ draw: @escaping @Sendable (K) -> CGImage?) async -> [K: NSImage] {
        let out = await Task.detached(priority: .userInitiated) { () -> DrawnTiles<K> in
            let o = DrawnTiles<K>()
            for k in keys { if let cg = draw(k) { o.images[k] = cg } }
            return o
        }.value
        return out.images.mapValues { NSImage(cgImage: $0, size: .zero) }
    }
}

/// Pictures drawn off the main thread, handed back to it.
final class DrawnTiles<K: Hashable>: @unchecked Sendable { var images: [K: CGImage] = [:]; init() {} }

/// The pictures read and drawn for the tools, shared by every window (they only depend on the file and the time).
@MainActor
final class ToolFrameCache {
    static let shared = ToolFrameCache()
    private(set) var frames: [String: CGImage] = [:]
    private var order: [String] = []
    var reading: [String: Task<CGImage?, Never>] = [:]
    /// The last picture read from each file (at each size), for while the video plays.
    var latest: [String: (CGImage, String)] = [:]
    /// How many frames were read from video files for the tools (the self-test checks that playing and switching tools read few).
    var reads = 0
    /// Drawn tiles, by what they were drawn from (frame key + what was drawn).
    private(set) var tiles: [String: [String: NSImage]] = [:]
    private var tileOrder: [String] = []

    func remember(_ image: CGImage, for key: String) {
        frames[key] = image; order.removeAll { $0 == key }; order.append(key)
        while order.count > 24 { frames[order.removeFirst()] = nil }
    }

    func rememberTiles(_ images: [String: NSImage], for key: String) {
        tiles[key] = images; tileOrder.removeAll { $0 == key }; tileOrder.append(key)
        while tileOrder.count > 12 { tiles[tileOrder.removeFirst()] = nil }
    }
}
