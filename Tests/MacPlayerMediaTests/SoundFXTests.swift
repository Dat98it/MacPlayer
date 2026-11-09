import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Bass, treble, pitch, room and echo, checked on tones and bursts made for the purpose.
@Suite(.serialized) struct SoundFXTests {
    private let rate = 44100.0

    private func folder() -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("fxtests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        SoundFXRenderer.cacheFolder = f.appendingPathComponent("cache", isDirectory: true)
        return f
    }

    /// A mono sound: `signal(t)` for `seconds`, written as a WAV.
    private func makeSound(in dir: URL, name: String = "tone.wav", seconds: Double, _ signal: (Double) -> Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = Float(signal(Double(i) / rate)) }
        try file.write(from: buffer)
        return url
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func rms(_ s: ArraySlice<Float>) -> Double { (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, s.count))).squareRoot() }

    private func crossings(_ s: ArraySlice<Float>) -> Int {
        var n = 0, last: Float = 0
        for v in s { if (v >= 0) != (last >= 0) && last != 0 { n += 1 }; last = v }
        return n
    }

    @Test func aHigherPitchRaisesTheToneAndKeepsTheLength() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try makeSound(in: dir, seconds: 2) { 0.5 * sin(2 * .pi * 440 * $0) }
        var fx = SoundFX(); fx.pitch = 12
        let out = try await SoundFXRenderer.process(src, fx: fx)
        let before = try samples(src), after = try samples(out)
        #expect(abs(Double(after.count - before.count)) < rate * 0.1, "the length stays: \(before.count) → \(after.count)")
        let mid = after.count / 4..<after.count * 3 / 4
        let ratio = Double(crossings(after[mid])) / Double(max(1, crossings(before[before.count / 4..<before.count * 3 / 4])))
        #expect(ratio > 1.8 && ratio < 2.2, "an octave up doubles the pitch, got ×\(ratio)")
    }

    @Test func bassBoostLiftsALowToneAndTrebleCutQuietensAHighOne() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let low = try makeSound(in: dir, name: "low.wav", seconds: 1.5) { 0.2 * sin(2 * .pi * 80 * $0) }
        let high = try makeSound(in: dir, name: "high.wav", seconds: 1.5) { 0.5 * sin(2 * .pi * 9000 * $0) }
        var boost = SoundFX(); boost.bass = 12
        var cut = SoundFX(); cut.treble = -12
        let lowOut = try samples(try await SoundFXRenderer.process(low, fx: boost)), highOut = try samples(try await SoundFXRenderer.process(high, fx: cut))
        let lowIn = try samples(low), highIn = try samples(high)
        let span = 20000..<60000
        #expect(rms(lowOut[span]) > rms(lowIn[span]) * 2.2, "bass +12 dB lifts an 80 Hz tone: \(rms(lowIn[span])) → \(rms(lowOut[span]))")
        #expect(rms(highOut[span]) < rms(highIn[span]) * 0.5, "treble −12 dB quietens a 9 kHz tone: \(rms(highIn[span])) → \(rms(highOut[span]))")
    }

    @Test func anEchoRepeatsASoundAfterItIsOver() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // 0.15 s of tone, then silence
        let src = try makeSound(in: dir, seconds: 2) { $0 < 0.15 ? 0.6 * sin(2 * .pi * 500 * $0) : 0 }
        var fx = SoundFX(); fx.echo = 1
        let out = try samples(try await SoundFXRenderer.process(src, fx: fx))
        let quiet = out[Int(0.9 * rate)..<Int(1.6 * rate)]
        #expect(rms(quiet) > 0.01, "the repeats are heard in what was silence, rms \(rms(quiet))")
        let plain = try samples(src)
        #expect(rms(plain[Int(0.9 * rate)..<Int(1.6 * rate)]) < 0.0001)
    }

    @Test func aRoomAddsATailAndTheCopyIsKeptForNextTime() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try makeSound(in: dir, seconds: 2) { $0 < 0.1 ? 0.6 * sin(2 * .pi * 700 * $0) : 0 }
        var fx = SoundFX(); fx.reverb = 1
        #expect(SoundFXRenderer.cached(for: src, fx: fx) == nil)
        let out = try await SoundFXRenderer.process(src, fx: fx)
        #expect(rms(try samples(out)[Int(0.3 * rate)..<Int(0.9 * rate)]) > 0.003, "a tail follows the sound")
        #expect(SoundFXRenderer.cached(for: src, fx: fx) == out)
        let again = try await SoundFXRenderer.process(src, fx: fx)
        #expect(again == out)
        var other = fx; other.reverb = 0.5
        #expect(SoundFXRenderer.cached(for: src, fx: other) == nil, "other settings are another copy")
    }

    @Test func aFileWithNoSoundIsRefusedWithAReason() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("not-a-sound.txt")
        try "hello".write(to: bad, atomically: true, encoding: .utf8)
        var fx = SoundFX(); fx.bass = 3
        await #expect(throws: SoundFXRenderer.FXError.self) { _ = try await SoundFXRenderer.process(bad, fx: fx) }
        #expect(!SoundFXRenderer.FXError.noAudio.description.isEmpty)
    }

    @Test func presetsAreRecognisedAndSettingsStayInRange() {
        for p in SoundFX.Preset.allCases { #expect(!p.fx.isNeutral && p.fx.preset == p) }
        var f = SoundFX(); f.bass = 99; f.pitch = -50; f.reverb = 3; f.echo = -1
        let c = f.clamped()
        #expect(c.bass == 12 && c.pitch == -12 && c.reverb == 1 && c.echo == 0)
        #expect(SoundFX().isNeutral && SoundFX().preset == nil)
        #expect(SoundFX.Preset.deep.fx.cacheKey != SoundFX.Preset.high.fx.cacheKey)
    }

    @Test func theSettingsSurviveSavingAndOldProjectsOpenWithNone() throws {
        var a = AudioSettings(); a.fx = SoundFX.Preset.telephone.fx
        #expect(try JSONDecoder().decode(AudioSettings.self, from: try JSONEncoder().encode(a)) == a)
        let old = ##"{"gainDB":3,"muted":false,"fadeIn":0,"fadeOut":0,"offsetSeconds":0}"##.data(using: .utf8)!
        #expect(try JSONDecoder().decode(AudioSettings.self, from: old).fx == nil)
        var spec = AudioSettings(); spec.fx = SoundFX()
        #expect(!spec.isNeutral, "an effect that is set, even with no change yet, is a difference to look at")
    }

    // MARK: Whole export

    private func exportedSamples(_ url: URL) throws -> [Float] { try samples(url) }

    @Test func anExportedVideoCarriesTheChangedSound() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await Fixtures.shared.source()
        func export(_ name: String, fx: SoundFX?) async throws -> URL {
            var audio = AudioSettings(); audio.fx = fx
            let out = Fixtures.shared.outputURL(name)
            let piece = RenderPiece(sourceURL: src, span: span30(0, 60), look: VideoLook(), audio: audio)
            try await RenderExporter().export(pieces: [piece], recipe: RenderRecipe(look: VideoLook(), audio: audio), to: out, options: ExportOptions(mode: .exact))
            return out
        }
        var fx = SoundFX(); fx.pitch = 12
        // The source sound is changed first (the way the app does when the effect is chosen), then the export uses that copy.
        _ = try await SoundFXRenderer.process(src, fx: fx)
        let plain = try samples(try await export("fx-plain", fx: nil)), pitched = try samples(try await export("fx-pitched", fx: fx))
        let a = crossings(plain[plain.count / 4..<plain.count * 3 / 4]), b = crossings(pitched[pitched.count / 4..<pitched.count * 3 / 4])
        #expect(a > 20, "the source has a tone to measure, crossings \(a)")
        let ratio = Double(b) / Double(max(1, a))
        // (The source is a beep with some clicks, not a pure tone, so the count is a rough sign: well above 1 means the sound went up in pitch.)
        #expect(ratio > 1.5, "the exported sound is much higher than the plain one, got ×\(ratio)")
    }
}
