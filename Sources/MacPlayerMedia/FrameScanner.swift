import AVFoundation
import CoreMedia
import Foundation
import MacPlayerCore

/// Measures what a file really contains, by decoding it: which frame index sits at which time, and where
/// the audio beeps start. This is the ground truth the cut/seek/sync checks compare against.
public enum FrameScanner {
    public struct Frame: Equatable, Sendable {
        public let time: MediaTime
        /// Index drawn by `SyntheticMedia`, or nil for a frame whose barcode could not be read.
        public let index: Int?
    }

    /// Decodes every video frame in order (what AVAssetReader presents, so edit lists are respected).
    public static func scanVideo(url: URL, timeRange: TimeSpan? = nil) async throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        if let r = timeRange {
            reader.timeRange = CMTimeRange(start: r.start.cmTime, end: r.end.cmTime)
        }
        guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable("reader") }
        var frames: [Frame] = []
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard pts.isNumeric else { continue }
            let idx = CMSampleBufferGetImageBuffer(sb).flatMap { SyntheticMedia.decodeIndex(from: $0) }
            frames.append(Frame(time: MediaTime(value: pts.value, timescale: pts.timescale), index: idx))
        }
        if reader.status == .failed { throw reader.error ?? MediaProbeError.unreadable("reader failed") }
        return frames
    }

    /// Start times of beeps: where the audio envelope rises above a threshold after silence.
    public static func beepOnsets(url: URL) async throws -> [MediaTime] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 48_000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable("audio reader") }
        var onsets: [MediaTime] = []
        var quiet = true
        let window = 48 // 1 ms windows
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            var i = 0
            while i + window <= data.count {
                var peak: Float = 0
                for k in i..<(i + window) { peak = max(peak, abs(data[k])) }
                if quiet, peak > 0.15 {
                    let t = pts.seconds + Double(i) / rate
                    onsets.append(MediaTime(seconds: t, timescale: 48_000))
                    quiet = false
                } else if !quiet, peak < 0.03 {
                    quiet = true
                }
                i += window
            }
        }
        return onsets
    }
}

extension MediaTime {
    public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    /// A time AVFoundation gives (an invalid or endless one — a player with nothing in it — is taken as zero rather than stopping the app).
    public init(_ t: CMTime) { if t.isNumeric && t.timescale > 0 { self.init(value: t.value, timescale: t.timescale) } else { self.init(value: 0, timescale: 600) } }
}

/// Looks at the compressed samples of a file (no decoding): how many, where keyframes are, and the
/// track's edit list. This is how a "fast cut" is told apart from a re-encode.
public enum SampleInspector {
    public struct Report: Sendable {
        public var sampleCount: Int
        public var syncSampleCount: Int
        public var firstSampleTime: Double
        public var firstSampleIsSync: Bool
        public var timeMappings: [(source: Double, sourceDuration: Double, target: Double, targetDuration: Double)]
        public var width: Int
        public var height: Int
        public var totalBytes: Int
    }

    public static func inspect(url: URL) async throws -> Report? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        let segments = try await track.load(.segments)
        let maps = segments.map { (source: $0.timeMapping.source.start.seconds, sourceDuration: $0.timeMapping.source.duration.seconds,
                                   target: $0.timeMapping.target.start.seconds, targetDuration: $0.timeMapping.target.duration.seconds) }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // compressed samples as stored
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable("sample reader") }
        var n = 0, sync = 0, bytes = 0
        var first: Double = -1
        var firstSync = false
        while let sb = out.copyNextSampleBuffer() {
            let atts = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first
            let notSync = (atts?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            if n == 0 { first = CMSampleBufferGetPresentationTimeStamp(sb).seconds; firstSync = !notSync }
            if !notSync { sync += 1 }
            bytes += CMSampleBufferGetTotalSampleSize(sb)
            n += 1
        }
        return Report(sampleCount: n, syncSampleCount: sync, firstSampleTime: first, firstSampleIsSync: firstSync,
                      timeMappings: maps, width: Int(size.width), height: Int(size.height), totalBytes: bytes)
    }
}
