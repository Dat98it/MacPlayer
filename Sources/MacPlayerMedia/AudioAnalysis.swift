import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import MacPlayerCore

/// Looking at a sound: how loud each short stretch is, and how loud it is overall.
public enum AudioAnalysis {
    public struct Loudness: Equatable, Sendable {
        /// Average level of the parts that are not silence, and the highest peak, in dBFS (0 is the loudest a file can hold).
        public var averageDB: Double
        public var peakDB: Double
    }

    private final class Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    /// The loudness (RMS, 0...1) of each `frameSeconds` of the given audio tracks of an asset, as one mono sound.
    /// - Parameters:
    ///   - tracks: which audio tracks to listen to (all of the asset's when nil).
    ///   - range: the part to read (all of it when nil). Frame 0 is the start of the range.
    public static func rms(asset: AVAsset, tracks: [AVAssetTrack]? = nil, range: CMTimeRange? = nil, frameSeconds: Double = 0.05) async throws -> (frames: [Float], peak: Float) {
        let audio: [AVAssetTrack]
        if let tracks { audio = tracks } else { audio = try await asset.loadTracks(withMediaType: .audio) }
        guard !audio.isEmpty else { return ([], 0) }
        let total = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: total)
        guard span.duration.seconds > 0 else { return ([], 0) }
        let rate = 8000.0
        let count = max(1, Int((span.duration.seconds / frameSeconds).rounded(.up)))
        let box = Box((asset, audio))
        return try await withCheckedThrowingContinuation { cont in
            // Reading blocks the thread it runs on, so it has its own (never the shared pool the rest of the app's work runs in).
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (asset, audio) = box.value
                    let reader = try AVAssetReader(asset: asset)
                    reader.timeRange = span
                    let out = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
                    ])
                    reader.add(out)
                    guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable("audio") }
                    var sums = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
                    var peak: Float = 0
                    let t0 = span.start.seconds
                    while let sb = out.copyNextSampleBuffer() {
                        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                        let n = CMBlockBufferGetDataLength(block) / 4
                        guard n > 0 else { continue }
                        var data = [Float](repeating: 0, count: n)
                        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                        var pk: Float = 0; vDSP_maxmgv(data, 1, &pk, vDSP_Length(n)); peak = max(peak, pk)
                        let first = Int(((CMSampleBufferGetPresentationTimeStamp(sb).seconds - t0) * rate).rounded())
                        let perFrame = max(1, Int(frameSeconds * rate))
                        var i = 0
                        while i < n {
                            let idx = first + i
                            let f = idx / perFrame
                            let take = min(n - i, (f + 1) * perFrame - idx)
                            if f >= 0, f < count {
                                var s: Float = 0
                                data.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i, 1, &s, vDSP_Length(take)) }
                                sums[f] += Double(s); counts[f] += take
                            }
                            i += max(1, take)
                        }
                    }
                    if reader.status == .failed { throw reader.error ?? MediaProbeError.unreadable("audio") }
                    let frames = (0..<count).map { counts[$0] > 0 ? Float((sums[$0] / Double(counts[$0])).squareRoot()) : 0 }
                    cont.resume(returning: (frames, peak))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Average and peak level of (a part of) a file's sound. Nil when it has no sound or is silent.
    public static func loudness(url: URL, range: CMTimeRange? = nil) async throws -> Loudness? {
        let r = try await rms(asset: AVURLAsset(url: url), range: range)
        return level(frames: r.frames, peak: r.peak)
    }

    /// Pure part of `loudness`: silence between the words does not drag the average down.
    public static func level(frames: [Float], peak: Float) -> Loudness? {
        let audible = frames.filter { $0 > 0.003 }          // louder than -50 dBFS
        guard !audible.isEmpty, peak > 0 else { return nil }
        let meanSquare = audible.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(audible.count)
        return Loudness(averageDB: 10 * log10(meanSquare), peakDB: 20 * log10(Double(peak)))
    }

    /// When someone speaks in the audio of an asset, in seconds from the start of `range` (or of the asset).
    public static func speech(asset: AVAsset, tracks: [AVAssetTrack]? = nil, range: CMTimeRange? = nil) async throws -> [(start: Double, end: Double)] {
        let frame = 0.05
        let r = try await rms(asset: asset, tracks: tracks, range: range, frameSeconds: frame)
        return SpeechDetector.ranges(rms: r.frames, frameSeconds: frame)
    }
}
