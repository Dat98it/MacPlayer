import AVFoundation
import CoreGraphics
import Foundation
import MacPlayerCore

/// Still frames from a video: thumbnails in the library, exported stills, and the frame under the playhead.
public enum FrameGrabber {
    public enum Accuracy: Sendable {
        /// The frame at exactly this time (slower: may decode from the previous keyframe).
        case exact
        /// Any nearby frame, fast. Right for scrubbing strips and library thumbnails.
        case nearest
    }

    public static func image(url: URL, at time: MediaTime, accuracy: Accuracy = .exact, maxSize: CGSize? = nil) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if accuracy == .exact {
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
        } else {
            gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        }
        if let m = maxSize { gen.maximumSize = m }
        let (image, _) = try await gen.image(at: time.cmTime)
        return image
    }

    /// A frame that stands for the whole video in lists and grids: the middle of it, since the start is often black or a fade-in.
    /// A nearby frame is fine, so it stays fast even for long videos. A video of unknown or tiny length gives its first frame.
    public static func representativeImage(url: URL, maxSize: CGSize? = nil) async throws -> CGImage {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        let t = seconds.isFinite && seconds > 0.2 ? seconds / 2 : 0
        return try await image(url: url, at: MediaTime(seconds: t, timescale: 600), accuracy: .nearest, maxSize: maxSize)
    }

    /// Reads a synthetic barcode out of a CGImage (for tests of seek/preview accuracy).
    public static func syntheticIndex(of image: CGImage) -> Int? {
        let w = image.width, h = image.height
        guard w >= 16 * 16, h >= 16 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var value = 0
        for bit in 0..<16 {
            // Bitmap memory starts at the top row, so the top-left barcode is at row 8.
            let cx = bit * 16 + 8, cy = 8
            let o = (cy * w + cx) * 4
            let lum = (Int(pixels[o]) + Int(pixels[o + 1]) + Int(pixels[o + 2])) / 3
            if lum > 60 && lum < 195 { return nil }
            value = (value << 1) | (lum >= 128 ? 1 : 0)
        }
        return value
    }
}

/// Real frame times, read from the file's own sample table (not computed from a nominal frame rate).
public enum FrameLocator {
    /// Presentation time of the frame shown at `time`, and its duration. Nil if there is no video track.
    public static func frame(url: URL, at time: MediaTime) async throws -> (time: MediaTime, duration: MediaTime)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time.cmTime) else { return nil }
        let pts = cursor.presentationTimeStamp
        let dur = cursor.currentSampleDuration
        return (MediaTime(pts), dur.isNumeric ? MediaTime(dur) : MediaTime(value: 1, timescale: 30))
    }

    /// The frame `count` frames away from the one at `time` (negative = earlier). Clamped to the first/last frame.
    public static func step(url: URL, from time: MediaTime, by count: Int) async throws -> MediaTime? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let cursor = track.makeSampleCursor(presentationTimeStamp: time.cmTime) else { return nil }
        _ = cursor.stepInPresentationOrder(byCount: Int64(count))
        return MediaTime(cursor.presentationTimeStamp)
    }
}

/// Steps frame by frame using the file's own frame times. Keeps the track loaded, so each step is quick.
/// (AVPlayerItem.step(byCount:) only steps by whole frames when a video view is showing; this does not depend on that.)
public final class FrameStepper: @unchecked Sendable {
    private let url: URL
    private var track: AVAssetTrack?
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    private func loadedTrack() async -> AVAssetTrack? {
        lock.lock(); let t = track; lock.unlock()
        if let t { return t }
        let asset = AVURLAsset(url: url)
        guard let t = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        lock.lock(); track = t; lock.unlock()
        return t
    }

    /// Presentation time of the frame `count` frames away from the one shown at `time`. Clamped to the first/last frame.
    public func step(from time: MediaTime, by count: Int) async -> MediaTime? {
        guard let t = await loadedTrack(),
              let cursor = t.makeSampleCursor(presentationTimeStamp: (time + MediaTime(value: 1, timescale: 6000)).cmTime) else { return nil }
        _ = cursor.stepInPresentationOrder(byCount: Int64(count))
        return MediaTime(cursor.presentationTimeStamp)
    }
}
