import AVFoundation
import CoreMedia
import Foundation

/// Finds out, cheaply, whether the end of a video file can be decoded. Exact export decodes everything, so a file that was cut off
/// (an incomplete download: the header says 36 minutes, the data stops at 36:40) would otherwise only fail minutes into the export.
public enum SourceHealth {
    public struct Damage: Equatable, Sendable {
        /// Source time up to which picture and sound could be read.
        public var readable: Double
        /// What the file says its length is.
        public var declared: Double
    }

    private struct Work: @unchecked Sendable {
        let asset: AVURLAsset
        let tracks: [(type: AVMediaType, track: AVAssetTrack)]
        let start: Double, stop: Double, duration: Double
    }

    /// Decodes the stretch of the file just before `end` (default 20 s of it) and reports where decoding stopped, if it did.
    /// Nil when that stretch decodes. A file that cannot be opened at all is not "damaged" here: other checks report that.
    /// The reading blocks, so it runs on its own queue (not on the pool Swift concurrency shares with everything else), and a watchdog
    /// stops it after `timeout` seconds: this check must never be the thing that holds an export up.
    public static func tailDamage(of url: URL, endingAt end: Double, window: Double = 20, timeout: Double = 30) async -> Damage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        let stop = min(end, duration), start = max(0, stop - window)
        guard stop > start else { return nil }
        var tracks: [(type: AVMediaType, track: AVAssetTrack)] = []
        for type in [AVMediaType.video, .audio] {
            if let t = try? await asset.loadTracks(withMediaType: type).first { tracks.append((type, t)) }
        }
        let work = Work(asset: asset, tracks: tracks, start: start, stop: stop, duration: duration)
        return await withCheckedContinuation { (cont: CheckedContinuation<Damage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: scan(work, timeout: timeout)) }
        }
    }

    private static func scan(_ w: Work, timeout: Double) -> Damage? {
        var stoppedAt: Double?
        for (type, track) in w.tracks {
            guard let reader = try? AVAssetReader(asset: w.asset) else { continue }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: w.start, preferredTimescale: 60000), end: CMTime(seconds: w.stop, preferredTimescale: 60000))
            let settings: [String: Any] = type == .video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                   AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(out) else { continue }
            reader.add(out)
            guard reader.startReading() else { stoppedAt = min(stoppedAt ?? w.start, w.start); continue }
            let watchdog = DispatchWorkItem { reader.cancelReading() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            var lastGood = w.start
            while let sb = out.copyNextSampleBuffer() {
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if t.isFinite { lastGood = max(lastGood, t) }
            }
            watchdog.cancel()
            if reader.status == .failed { stoppedAt = min(stoppedAt ?? lastGood, lastGood) }
            else { reader.cancelReading() }
        }
        return stoppedAt.map { Damage(readable: $0, declared: w.duration) }
    }
}
