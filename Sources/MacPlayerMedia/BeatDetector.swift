import Accelerate
import AVFoundation
import Foundation
import MacPlayerCore

/// Finds the beat of a song (0.20), on this Mac: the sound is read once at a low rate, turned into how much new sound starts in each
/// 23 ms frame (spectral flux), and `BeatTracker` finds the tempo and the beats in that.
public enum BeatDetector {
    public enum BeatError: Error, CustomStringConvertible {
        case noSound, noBeat
        public var description: String {
            switch self {
            case .noSound: return "This file has no sound to listen to."
            case .noBeat: return "No steady beat was found in this sound."
            }
        }
    }

    static let rate = 11025.0
    static let frame = 1024
    static let hop = 256
    /// Longer sounds are only listened to this far (a beat found in 20 minutes covers any song).
    static let maxSeconds = 20.0 * 60

    public static func detect(url: URL) async throws -> BeatGrid {
        let samples = try await read(url: url)
        guard samples.count > frame * 4 else { throw BeatError.noSound }
        let onset = flux(samples)
        guard var grid = BeatTracker.track(onset: onset, hop: Double(hop) / rate) else { throw BeatError.noBeat }
        // A frame's value belongs to the window that starts there; a hit shows as soon as it enters the window, about 3/4 of a window
        // before its end, so the beat is that much later than the frame's start.
        let lead = Double(frame) * 0.75 / rate
        grid.times = grid.times.map { $0 + lead }
        return grid
    }

    /// The sound as one channel of floats at `rate`.
    static func read(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw BeatError.noSound }
        let duration = try await asset.load(.duration)
        let box = SendableBox((asset, tracks))
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (asset, tracks) = box.value
                    let reader = try AVAssetReader(asset: asset)
                    reader.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, CMTime(seconds: maxSeconds, preferredTimescale: 600)))
                    let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
                    ])
                    reader.add(out)
                    guard reader.startReading() else { throw reader.error ?? BeatError.noSound }
                    var all: [Float] = []
                    all.reserveCapacity(Int(min(duration.seconds, maxSeconds) * rate) + 4096)
                    while let sb = out.copyNextSampleBuffer() {
                        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                        let n = CMBlockBufferGetDataLength(block) / 4
                        guard n > 0 else { continue }
                        var data = [Float](repeating: 0, count: n)
                        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                        all.append(contentsOf: data)
                    }
                    if reader.status == .failed { throw reader.error ?? BeatError.noSound }
                    cont.resume(returning: all)
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Spectral flux: for each frame, how much louder each frequency got than in the frame before (log-compressed, rises only), less
    /// its local average, so steady sound counts for nothing and new notes and drum hits stand out.
    static func flux(_ x: [Float]) -> [Float] {
        let n = frame, half = n / 2
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frames = (x.count - n) / hop + 1
        var out = [Float](repeating: 0, count: max(0, frames))
        var prev = [Float](repeating: 0, count: half), mag = [Float](repeating: 0, count: half)
        // Bands of the spectrum (Hz), each bin counted in one.
        let bands: [ClosedRange<Double>] = [30...120, 120...250, 250...500, 500...1000, 1000...2000, 2000...4000, 4000...5500]
        let bandOf = (0..<half).map { k -> Int in let hz = Double(k) * rate / Double(n); return bands.firstIndex { $0.contains(hz) } ?? (hz < 30 ? 0 : bands.count - 1) }
        var bandFlux = [[Float]](repeating: [Float](repeating: 0, count: max(0, frames)), count: bands.count)
        var buf = [Float](repeating: 0, count: n), re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        for f in 0..<frames {
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + f * hop, 1, window, 1, &buf, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.withUnsafeBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            for b in bands.indices { bandFlux[b][f] = 0 }
            for k in 1..<half {
                let v = log1pf(mag[k] * 10)
                let d = v - prev[k]
                if d > 0 { bandFlux[bandOf[k]][f] += d }
                prev[k] = v
            }
        }
        // Each band counts by its own size, the lowest two (kick drum, bass) twice: a hi-hat spreads over many bins and would otherwise
        // set the beat on the off-beats.
        for b in bands.indices {
            let mean = max(1e-6, bandFlux[b].reduce(0, +) / Float(max(1, frames)))
            let w: Float = b < 2 ? 2 : 1
            for f in 0..<frames { out[f] += w * bandFlux[b][f] / mean }
        }
        // Less the average of the half second around each frame, never below zero.
        let w = max(1, Int(0.25 * rate / Double(hop)))
        var prefix = [Float](repeating: 0, count: out.count + 1)
        for i in 0..<out.count { prefix[i + 1] = prefix[i] + out[i] }
        return out.indices.map { i in
            let a = max(0, i - w), b = min(out.count, i + w + 1)
            return max(0, out[i] - (prefix[b] - prefix[a]) / Float(b - a))
        }
    }
}

/// Carries values that are only used on one thread at a time across a hop to a background queue.
struct SendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
