import AVFoundation
import CoreMedia
import Foundation
import MacPlayerCore

/// Loudness over time for the timeline: `bins` peak values (0...1), read once in the background.
public enum Waveform {
    public static func peaks(url: URL, bins: Int = 1600) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable("waveform") }
        var peaks = [Float](repeating: 0, count: bins)
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(block) / 4
            var data = [Float](repeating: 0, count: n)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            let t0 = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            for (i, v) in data.enumerated() {
                let t = t0 + Double(i) / 8000
                let b = min(bins - 1, max(0, Int(t / duration * Double(bins))))
                peaks[b] = max(peaks[b], abs(v))
            }
        }
        let top = peaks.max() ?? 0
        return top > 0 ? peaks.map { $0 / top } : peaks
    }
}
