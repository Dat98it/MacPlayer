import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// 0.20: the beat of a real sound file (a made drum loop) is found.
struct BeatDetectorTests {
    /// A kick (low thump) on every beat and a hi-hat between, over a quiet held chord, as a 44.1 kHz stereo file.
    private func drumLoop(bpm: Double, seconds: Double, offset: Double) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-beat-\(UUID().uuidString.prefix(6)).caf")
        let rate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let n = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let period = 60 / bpm
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let t = Double(i) / rate
            var v = 0.05 * sin(2 * .pi * 220 * t) + 0.04 * sin(2 * .pi * 277 * t)
            if t >= offset {
                let beatT = (t - offset).truncatingRemainder(dividingBy: period)
                v += 0.8 * exp(-beatT * 30) * sin(2 * .pi * (60 + 80 * exp(-beatT * 40)) * beatT)
                let hatT = (t - offset + period / 2).truncatingRemainder(dividingBy: period)
                v += 0.15 * exp(-hatT * 80) * Double.random(in: -1...1, using: &rng)
            }
            buf.floatChannelData![0][i] = Float(v); buf.floatChannelData![1][i] = Float(v)
        }
        try file.write(from: buf)
        return url
    }

    @Test(arguments: [(128.0, 0.3), (100.0, 1.1)])
    func theBeatOfADrumLoopIsFound(bpm: Double, offset: Double) async throws {
        let url = try drumLoop(bpm: bpm, seconds: 30, offset: offset)
        defer { try? FileManager.default.removeItem(at: url) }
        let g = try await BeatDetector.detect(url: url)
        #expect(abs(g.bpm - bpm) < 2, "found \(g.bpm) bpm")
        let period = 60 / bpm
        let late = g.times.filter { $0 > offset + 1 }
        #expect(late.count > 20)
        let off = late.map { t -> Double in let r = (t - offset).truncatingRemainder(dividingBy: period); return min(abs(r), abs(period - r)) }
        #expect((off.max() ?? 1) < 0.03, "every beat is within 30 ms of a kick: worst \(off.max() ?? -1)")
    }

    @Test func aSteadyToneHasNoBeat() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-tone-\(UUID().uuidString.prefix(6)).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let n = 44100 * 10
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buf.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * 440 * Double(i) / 44100)) }
        try file.write(from: buf)
        await #expect(throws: BeatDetector.BeatError.self) { _ = try await BeatDetector.detect(url: url) }
    }
}

extension BeatDetectorTests {
    /// With MACPLAYER_BEAT_FILES=<a|b|…>: the tempo found in real songs (read only), printed to compare by ear (not a check).
    @Test func tempoOfRealSongs() async throws {
        guard let list = ProcessInfo.processInfo.environment["MACPLAYER_BEAT_FILES"] else { return }
        for path in list.split(separator: "|").map(String.init) {
            let t0 = Date()
            do {
                let g = try await BeatDetector.detect(url: URL(fileURLWithPath: path))
                let gaps = zip(g.times.dropFirst(), g.times).map { $0 - $1 }
                // In place of listening: how many beats sit on a strong onset (within 40 ms), against the same grid moved half a beat.
                let fl = BeatDetector.flux(try await BeatDetector.read(url: URL(fileURLWithPath: path))), hop = 256.0 / 11025, lead = 1024 * 0.75 / 11025
                let strong = fl.sorted()[Int(Double(fl.count) * 0.8)]
                func hit(_ t: Double) -> Bool { let c = Int(((t - lead) / hop).rounded()); guard c + 2 >= 0, c - 2 < fl.count else { return false }; return (max(0, c - 2)...min(fl.count - 1, c + 2)).contains { fl[$0] >= strong } }
                let period = 60 / g.bpm
                let on = g.times.filter(hit).count, off = g.times.map { $0 + period / 2 }.filter(hit).count
                print("BEATFIT", (path as NSString).lastPathComponent.prefix(30), "halfway/beat", BeatTracker.lastHalfwayRatio, "on-beat", on, "of", g.times.count, "half-beat-shifted", off)
                print("BEAT", (path as NSString).lastPathComponent.prefix(30), "bpm", g.bpm, "beats", g.times.count, "first", g.times.prefix(4).map { ($0 * 100).rounded() / 100 },
                      "gap min/max", (gaps.min() ?? 0), (gaps.max() ?? 0), "secs", Date().timeIntervalSince(t0))
            } catch { print("BEAT", path, "error", error) }
        }
    }
}

extension BeatDetectorTests {
    /// With MACPLAYER_BEAT_LISTEN=<out dir> and MACPLAYER_BEAT_FILES: the first minute of each song with a click on every beat found
    /// (a higher click on every 4th), as .m4a, to check by ear. The songs are only read.
    @Test func listeningCopiesWithClicks() async throws {
        guard let out = ProcessInfo.processInfo.environment["MACPLAYER_BEAT_LISTEN"], let list = ProcessInfo.processInfo.environment["MACPLAYER_BEAT_FILES"] else { return }
        for path in list.split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let g = try await BeatDetector.detect(url: url)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 60, preferredTimescale: 600))
            let rate = 44100.0
            let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: rate])
            reader.add(o); reader.startReading()
            var samples: [Float] = []
            while let sb = o.copyNextSampleBuffer(), let b = CMSampleBufferGetDataBuffer(sb) {
                let n = CMBlockBufferGetDataLength(b) / 4
                var d = [Float](repeating: 0, count: n)
                d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                samples += d
            }
            let frames = samples.count / 2
            for (k, t) in g.times.enumerated() where t < 60 {
                let start = Int(t * rate), f = k % 4 == 0 ? 2000.0 : 1200.0
                for i in 0..<Int(0.03 * rate) where start + i < frames {
                    let v = Float(0.45 * sin(2 * .pi * f * Double(i) / rate) * exp(-Double(i) / (0.008 * rate)))
                    samples[(start + i) * 2] += v; samples[(start + i) * 2 + 1] += v
                }
            }
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
            buf.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { buf.floatChannelData![0][i] = samples[i * 2] * 0.8; buf.floatChannelData![1][i] = samples[i * 2 + 1] * 0.8 }
            let name = (url.deletingPathExtension().lastPathComponent as NSString).substring(to: min(40, url.deletingPathExtension().lastPathComponent.count))
            let dest = URL(fileURLWithPath: out).appendingPathComponent("\(name) - nhịp \(Int(g.bpm.rounded())).m4a")
            try? FileManager.default.removeItem(at: dest)
            let file = try AVAudioFile(forWriting: dest, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            try file.write(from: buf)
            print("LISTEN", dest.lastPathComponent, g.bpm)
        }
    }
}
