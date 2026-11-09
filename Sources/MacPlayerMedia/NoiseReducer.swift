import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import MacPlayerCore

/// Takes steady background noise (a fan, a hiss, the hum of a room) out of a sound.
///
/// It works in the frequency domain: the sound is cut into short overlapping slices, the level of the noise in each frequency is estimated from the
/// quietest slices, and each frequency of each slice is turned down by how much of it looks like noise. Voices and music stay, because they are
/// well above the noise. The result is written once to a file next to the app's other cached work; the original is never touched.
public enum NoiseReducer {
    nonisolated(unsafe) public static var cacheFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("macplayer-denoised", isDirectory: true)
    /// Longer sounds are not processed (the whole sound is held in memory).
    public static let maxSeconds = 1500.0

    public enum DenoiseError: Error, CustomStringConvertible {
        case noAudio, tooLong, failed(String)
        public var description: String {
            switch self {
            case .noAudio: return "This file has no sound to clean."
            case .tooLong: return "This sound is too long to clean in one go (the limit is 25 minutes)."
            case .failed(let m): return "Cleaning the sound failed: \(m)"
            }
        }
    }

    static func level(_ strength: Double) -> Int { max(1, min(10, Int((strength * 10).rounded()))) }

    public static func cacheURL(for source: URL, strength: Double) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(source.standardizedFileURL.path)|\(size)|\(Int(modified))|\(level(strength))"
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return cacheFolder.appendingPathComponent(String(format: "%016llx.m4a", h))
    }

    /// The cleaned sound, when it has been made before.
    public static func cached(for source: URL, strength: Double) -> URL? {
        let u = cacheURL(for: source, strength: strength)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Makes (or finds) the cleaned copy of a file's sound.
    public static func clean(_ source: URL, strength: Double, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let hit = cached(for: source, strength: strength) { progress?(1); return hit }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw DenoiseError.noAudio }
        let duration = try await asset.load(.duration).seconds
        guard duration <= maxSeconds else { throw DenoiseError.tooLong }
        let rate = 44100.0
        let pcm = try await read(asset: asset, tracks: tracks, rate: rate)
        progress?(0.2)
        var channels = pcm
        for c in channels.indices {
            channels[c] = process(channels[c], sampleRate: rate, strength: strength)
            progress?(0.2 + 0.6 * Double(c + 1) / Double(channels.count))
        }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let out = cacheURL(for: source, strength: strength)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            try write(channels, rate: rate, to: tmp)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: tmp, to: out)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw DenoiseError.failed("\(error.localizedDescription)")
        }
        progress?(1)
        return out
    }

    // MARK: reading and writing

    private final class Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    /// All of the sound as 1 or 2 channels of floats.
    static func read(asset: AVAsset, tracks: [AVAssetTrack], rate: Double) async throws -> [[Float]] {
        let box = Box((asset, tracks))
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (asset, tracks) = box.value
                    let reader = try AVAssetReader(asset: asset)
                    let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: rate,
                    ])
                    reader.add(out)
                    guard reader.startReading() else { throw reader.error ?? DenoiseError.failed("cannot read") }
                    var left: [Float] = [], right: [Float] = []
                    while let sb = out.copyNextSampleBuffer() {
                        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                        let n = CMBlockBufferGetDataLength(block) / 4
                        guard n >= 2 else { continue }
                        var data = [Float](repeating: 0, count: n)
                        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                        let frames = n / 2
                        left.reserveCapacity(left.count + frames); right.reserveCapacity(right.count + frames)
                        for i in 0..<frames { left.append(data[2 * i]); right.append(data[2 * i + 1]) }
                    }
                    if reader.status == .failed { throw reader.error ?? DenoiseError.failed("cannot read") }
                    // A sound that is the same on both sides is cleaned once.
                    let same = zip(left, right).prefix(200_000).allSatisfy { abs($0 - $1) < 1e-6 }
                    cont.resume(returning: same ? [left] : [left, right])
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    static func write(_ channels: [[Float]], rate: Double, to url: URL) throws {
        let count = channels.count
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000],
                                          commonFormat: .pcmFormatFloat32, interleaved: false) else { throw DenoiseError.failed("cannot write") }
        let total = channels[0].count, chunk = 32768
        var pos = 0
        while pos < total {
            let n = min(chunk, total - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { throw DenoiseError.failed("no buffer") }
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 {
                let src = channels[min(c, count - 1)]
                buf.floatChannelData![c].update(from: Array(src[pos..<pos + n]), count: n)
            }
            try file.write(from: buf)
            pos += n
        }
    }

    // MARK: the cleaning itself

    static let fftSize = 1024, hop = 256

    /// Cleans one channel. `strength` 0...1: how much noise is taken out (more also takes a little of the voice's own warmth).
    public static func process(_ x: [Float], sampleRate: Double, strength: Double) -> [Float] {
        let n = fftSize, h = hop, bins = n / 2 + 1
        guard x.count > n * 4 else { return x }
        let s = Float(min(1, max(0, strength)))
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return x }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        // Slices start `n` before the sound so that its first samples are covered by full overlap too.
        let padded = [Float](repeating: 0, count: n) + x + [Float](repeating: 0, count: n)
        let frames = (padded.count - n) / h + 1

        func spectrum(_ frame: Int, _ re: inout [Float], _ im: inout [Float]) {
            var seg = [Float](repeating: 0, count: n)
            padded.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + frame * h, 1, window, 1, &seg, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    seg.withUnsafeBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
        }
        func magnitudes(_ re: [Float], _ im: [Float]) -> [Float] {
            var m = [Float](repeating: 0, count: bins)
            m[0] = abs(re[0]) / 2; m[bins - 1] = abs(im[0]) / 2        // zrip packs DC and Nyquist together
            for k in 1..<(n / 2) { m[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() / 2 }
            return m
        }

        // Pass 1: how loud each slice is, to find the quiet ones.
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var energy = [Float](repeating: 0, count: frames)
        var mags = [[Float]](); mags.reserveCapacity(frames)
        for f in 0..<frames {
            spectrum(f, &re, &im)
            let m = magnitudes(re, im)
            mags.append(m)
            energy[f] = m.reduce(0, +)
        }
        let order = energy.indices.sorted { energy[$0] < energy[$1] }
        let quiet = Array(order.prefix(max(4, frames / 10)))          // the quietest tenth of the slices is taken to be noise alone
        var noise = [Float](repeating: 0, count: bins)
        for k in 0..<bins { noise[k] = quiet.reduce(0) { $0 + mags[$1][k] } / Float(quiet.count) }
        // A touch of smoothing across neighbouring frequencies, so the estimate does not follow single random peaks.
        var smooth = noise
        for k in 1..<(bins - 1) { smooth[k] = (noise[k - 1] + 2 * noise[k] + noise[k + 1]) / 4 }
        noise = smooth

        // Pass 2: turn each frequency of each slice down by how noise-like it is, and put the slices back together.
        let over = 1.2 + 1.8 * s, floorGain = 0.35 - 0.3 * s
        var out = [Float](repeating: 0, count: padded.count)
        var previous = [Float](repeating: 1, count: bins)
        var seg = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            spectrum(f, &re, &im)
            let m = mags[f]
            var gains = [Float](repeating: 1, count: bins)
            for k in 0..<bins {
                let g = m[k] > 1e-9 ? 1 - over * noise[k] / m[k] : 0
                gains[k] = min(1, max(floorGain, g))
                // Gains that jump from slice to slice sound like bubbling: they may rise quickly but only fall gradually.
                gains[k] = max(gains[k], previous[k] * 0.6)
            }
            previous = gains
            for k in 1..<(n / 2) { re[k] *= gains[k]; im[k] *= gains[k] }
            re[0] *= gains[0]; im[0] *= gains[bins - 1]
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    seg.withUnsafeMutableBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2)) }
                    }
                }
            }
            // The inverse transform is n times too big (and the forward one 2 times), and the window is applied again on the way out.
            var scale = 1 / Float(2 * n)
            vDSP_vsmul(seg, 1, &scale, &seg, 1, vDSP_Length(n))
            vDSP_vmul(seg, 1, window, 1, &seg, 1, vDSP_Length(n))
            out.withUnsafeMutableBufferPointer { o in
                vDSP_vadd(o.baseAddress! + f * h, 1, seg, 1, o.baseAddress! + f * h, 1, vDSP_Length(n))
            }
        }
        // Hann × Hann windows overlapped by 4 add up to a constant (1.5), which is taken out here.
        var norm = Float(1) / 1.5
        var result = Array(out[n..<(n + x.count)])
        vDSP_vsmul(result, 1, &norm, &result, 1, vDSP_Length(result.count))
        return result
    }
}
