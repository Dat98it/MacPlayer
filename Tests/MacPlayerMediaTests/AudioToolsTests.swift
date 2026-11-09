import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Sounds made for the tests: tones where "someone speaks", and steady noise all the way through.
enum TestSound {
    struct Tone { var from: Double; var to: Double; var amp: Float; var freq: Double = 440 }

    static func samples(seconds: Double, tones: [Tone], noise: Float, rate: Double = 44100, seed: UInt64 = 7) -> [Float] {
        var rng = seed
        func rand() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float((rng >> 33) % 20001) / 10000 - 1 }
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var v = noise * rand()
            for tone in tones where t >= tone.from && t < tone.to { v += tone.amp * Float(sin(2 * .pi * tone.freq * t) * 0.7 + sin(2 * .pi * tone.freq * 2.1 * t) * 0.3) }
            return v
        }
    }

    static func write(_ s: [Float], rate: Double = 44100, name: String = "sound") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-sound-\(name)-\(UUID().uuidString.prefix(6)).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count))!
        buf.frameLength = AVAudioFrameCount(s.count)
        buf.floatChannelData![0].update(from: s, count: s.count)
        try file.write(from: buf)
        return url
    }

    static func rms(_ s: ArraySlice<Float>) -> Double { s.isEmpty ? 0 : (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot() }
    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }
}

@Suite(.serialized) struct AudioToolsTests {
    private let rate = 44100.0

    @Test func noiseIsTurnedDownAndTheVoiceStays() {
        let seconds = 6.0
        let tone = TestSound.Tone(from: 2, to: 4, amp: 0.3)
        let mixed = TestSound.samples(seconds: seconds, tones: [tone], noise: 0.04)
        let voiceOnly = TestSound.samples(seconds: seconds, tones: [tone], noise: 0)
        let cleaned = NoiseReducer.process(mixed, sampleRate: rate, strength: 0.7)
        #expect(cleaned.count == mixed.count)
        func slice(_ a: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> { a[Int(from * rate)..<Int(to * rate)] }
        let before = TestSound.rms(slice(mixed, 0.3, 1.7)), after = TestSound.rms(slice(cleaned, 0.3, 1.7))
        #expect(TestSound.db(after) < TestSound.db(before) - 8, "the noise alone went from \(TestSound.db(before)) to \(TestSound.db(after)) dB")
        let voiceBefore = TestSound.rms(slice(voiceOnly, 2.3, 3.7)), voiceAfter = TestSound.rms(slice(cleaned, 2.3, 3.7))
        #expect(voiceAfter > voiceBefore * 0.8 && voiceAfter < voiceBefore * 1.25, "the voice kept its level: \(voiceBefore) → \(voiceAfter)")
    }

    @Test func aStrongerSettingTakesOutMoreNoise() {
        let mixed = TestSound.samples(seconds: 5, tones: [.init(from: 2, to: 3.5, amp: 0.3)], noise: 0.04)
        func quiet(_ strength: Double) -> Double { TestSound.rms(NoiseReducer.process(mixed, sampleRate: rate, strength: strength)[Int(0.3 * rate)..<Int(1.7 * rate)]) }
        #expect(quiet(0.9) < quiet(0.2))
    }

    @Test func aSoundThatIsTooShortIsLeftAlone() {
        let s = TestSound.samples(seconds: 0.05, tones: [], noise: 0.1)
        #expect(NoiseReducer.process(s, sampleRate: rate, strength: 1) == s)
    }

    @Test func aFileIsCleanedOnceKeptAndLeftUntouched() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-denoise-test-\(UUID().uuidString.prefix(6))")
        NoiseReducer.cacheFolder = folder
        let mixed = TestSound.samples(seconds: 4, tones: [.init(from: 1.5, to: 3, amp: 0.3)], noise: 0.04)
        let src = try TestSound.write(mixed)
        let before = try Data(contentsOf: src)
        #expect(NoiseReducer.cached(for: src, strength: 0.6) == nil)
        let out = try await NoiseReducer.clean(src, strength: 0.6)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(NoiseReducer.cached(for: src, strength: 0.6) == out, "found again without doing it twice")
        #expect(NoiseReducer.cached(for: src, strength: 0.2) == nil, "another strength is another file")
        #expect(try Data(contentsOf: src) == before, "the original is not changed")
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 4) < 0.2, "same length: \(info.duration.seconds)")
        // The noise-only start of the cleaned file is quieter than the start of the original.
        let a = try await AudioAnalysis.rms(asset: AVURLAsset(url: src), range: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)))
        let b = try await AudioAnalysis.rms(asset: AVURLAsset(url: out), range: CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 600), duration: CMTime(seconds: 0.8, preferredTimescale: 600)))
        let ma = a.frames.reduce(0, +) / Float(a.frames.count), mb = b.frames.reduce(0, +) / Float(b.frames.count)
        #expect(mb < ma * 0.5, "noise before \(ma) after \(mb)")
        try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: src)
    }

    @Test func aFileWithoutSoundCannotBeCleaned() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 2, audio: false))
        do { _ = try await NoiseReducer.clean(src, strength: 0.5); Issue.record("should fail") }
        catch let e as NoiseReducer.DenoiseError { if case .noAudio = e {} else { Issue.record("wrong error \(e)") } }
    }

    @Test func loudnessIsMeasuredInDecibels() async throws {
        // A steady tone of amplitude 0.1 has RMS 0.0707 (-23 dBFS) and peak -20 dBFS (a little more from the second tone here, so a plain sine is used).
        let s = (0..<Int(3 * rate)).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let url = try TestSound.write(s)
        let l = try #require(try await AudioAnalysis.loudness(url: url))
        #expect(abs(l.averageDB - -23) < 0.7 && abs(l.peakDB - -20) < 0.7, "average \(l.averageDB) peak \(l.peakDB)")
        try? FileManager.default.removeItem(at: url)
        #expect(AudioAnalysis.level(frames: [0, 0, 0], peak: 0) == nil, "silence has no loudness")
    }

    @Test func speechIsFoundInAFile() async throws {
        let s = TestSound.samples(seconds: 8, tones: [.init(from: 2, to: 4, amp: 0.3), .init(from: 5.5, to: 6.5, amp: 0.3)], noise: 0.004)
        let url = try TestSound.write(s)
        let r = try await AudioAnalysis.speech(asset: AVURLAsset(url: url))
        #expect(r.count == 2, "\(r)")
        if r.count == 2 {
            #expect(abs(r[0].start - 1.9) < 0.3 && abs(r[0].end - 4.2) < 0.4)
            #expect(abs(r[1].start - 5.4) < 0.3 && abs(r[1].end - 6.7) < 0.4)
        }
        // Only the part asked for is listened to, counted from its start.
        let part = try await AudioAnalysis.speech(asset: AVURLAsset(url: url), range: CMTimeRange(start: CMTime(seconds: 4.5, preferredTimescale: 600), duration: CMTime(seconds: 3, preferredTimescale: 600)))
        #expect(part.count == 1 && abs(part[0].start - 0.9) < 0.3, "\(part)")
        try? FileManager.default.removeItem(at: url)
    }
}
