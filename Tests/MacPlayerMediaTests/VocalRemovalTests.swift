import AVFoundation
import Foundation
import Testing
@testable import MacPlayerMedia

@Suite(.serialized) struct VocalRemovalTests {
    private func sound(seconds: Double = 0.5, rate: Double = 44100, mono: Bool = false, silent: Bool = false) throws -> URL {
        let url = Fixtures.shared.outputURL("vocal-input", ext: "wav")
        let channels: AVAudioChannelCount = mono ? 1 : 2
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let n = Int(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
        buffer.frameLength = AVAudioFrameCount(n)
        for channel in 0..<Int(channels) {
            for i in 0..<n {
                let t = Double(i) / rate
                buffer.floatChannelData![channel][i] = silent ? 0 : Float(0.2 * sin(2 * .pi * (channel == 0 ? 220 : 330) * t) + 0.1 * sin(2 * .pi * 880 * t))
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func complexSTFTRoundTripPreservesPhaseAmplitudeAndEnds() throws {
        let transform = try VocalSTFT()
        let wave = (0..<2).map { channel in
            (0..<VocalSTFT.samples).map { i in Float(0.1 + 0.2 * sin(2 * .pi * Double(440 + channel * 77) * Double(i) / 44100)) }
        }
        let tensor = try transform.spectrum(wave, removeLowBins: false)
        let back = try transform.waveform(tensor)
        for channel in 0..<2 {
            let worst = zip(wave[channel], back[channel]).map { abs($0 - $1) }.max() ?? 1
            #expect(worst < 0.001, "the transform must reconstruct both boundaries too: \(worst)")
        }
        let constant = [[Float](repeating: 0.25, count: VocalSTFT.samples), [Float](repeating: 0.5, count: VocalSTFT.samples)]
        let dc = try transform.spectrum(constant, removeLowBins: false)
        #expect(abs(dc[[0, 0, 0, 100]].floatValue - 768) < 0.1, "unnormalised periodic Hann has a known DC sum")
        #expect(abs(dc[[0, 2, 1, 100]].floatValue + 768) < 0.1, "second channel's complex planes have the expected layout")
    }

    @Test func realModelKeepsSilenceSilent() async throws {
        let source = try sound(silent: true)
        let out = Fixtures.shared.outputURL("instrumental-silence", ext: "m4a")
        try await VocalRemover.writeInstrumental(source: source, to: out)
        let file = try AVAudioFile(forReading: out)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let floats = try #require(buffer.floatChannelData)
        let peak = (0..<Int(buffer.frameLength)).map { abs(floats[0][$0]) }.max() ?? 1
        #expect(peak < 0.001, "the learned model must not invent sound in silence")
    }

    @Test func theLearnedModelRemovesTheKnownVoiceAndKeepsTheKnownMusic() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "vocal-test", withExtension: "wav", subdirectory: "Fixtures"))
        let voiceFile = try AVAudioFile(forReading: fixture)
        let voiceBuffer = try #require(AVAudioPCMBuffer(pcmFormat: voiceFile.processingFormat, frameCapacity: AVAudioFrameCount(voiceFile.length)))
        try voiceFile.read(into: voiceBuffer)
        let voice = Array(UnsafeBufferPointer(start: try #require(voiceBuffer.floatChannelData)[0], count: Int(voiceBuffer.frameLength)))
        let n = voice.count
        var music = [Float](repeating: 0, count: n), mixture = music
        for i in 0..<n {
            let time = Double(i) / 44100, beat = time.truncatingRemainder(dividingBy: 0.5)
            let chord = time < 2.5 ? [130.81, 164.81, 196] : [110, 138.59, 164.81]
            var pluck = 0.0
            for frequency in chord {
                for harmonic in 1...4 { pluck += sin(2 * .pi * frequency * Double(harmonic) * time) * exp(-beat * Double(4 + harmonic)) / Double(harmonic) }
            }
            let kick = 0.22 * sin(2 * .pi * (50 + 80 * exp(-beat * 30)) * time) * exp(-beat * 25)
            music[i] = Float(pluck * 0.07 + kick)
            mixture[i] = music[i] + voice[i]
        }
        let input = Fixtures.shared.outputURL("known-mixture", ext: "wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
            buffer.frameLength = AVAudioFrameCount(n)
            for channel in 0..<2 { mixture.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: n) } }
            try file.write(from: buffer)
        }
        let output = Fixtures.shared.outputURL("known-instrumental", ext: "m4a")
        try await VocalRemover.writeInstrumental(source: input, to: output)
        let result = try AVAudioFile(forReading: output)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length)))
        try result.read(into: buffer)
        let y = try #require(buffer.floatChannelData)[0]
        var mm = 0.0, vv = 0.0, mv = 0.0, ym = 0.0, yv = 0.0, error = 0.0
        for i in 0..<min(n, Int(buffer.frameLength)) {
            let m = Double(music[i]), v = Double(voice[i]), out = Double(y[i])
            mm += m * m; vv += v * v; mv += m * v; ym += out * m; yv += out * v; error += (out - m) * (out - m)
        }
        let determinant = mm * vv - mv * mv
        let musicGain = (ym * vv - yv * mv) / determinant, voiceGain = (yv * mm - ym * mv) / determinant
        #expect(abs(voiceGain) < 0.2, "the known vocal must be suppressed by at least 14 dB; got \(voiceGain)")
        #expect(musicGain > 0.6, "the known backing must survive, rather than muting the whole mix; got \(musicGain)")
        #expect(10 * log10(vv / error) > 6, "the output must approach the real backing by at least 6 dB")
    }

    @Test func monoAndResampledSongsKeepDurationAcrossChunkBoundaries() async throws {
        let source = try sound(seconds: 6.2, rate: 48000, mono: true)
        let original = try Data(contentsOf: source)
        let out = Fixtures.shared.outputURL("instrumental-long", ext: "m4a")
        try await VocalRemover.writeInstrumental(source: source, to: out)
        let info = try await MediaProbe.probe(url: out)
        #expect(info.hasAudio && !info.hasVideo && abs(info.duration.seconds - 6.2) < 0.05)
        let file = try AVAudioFile(forReading: out)
        #expect(file.processingFormat.channelCount == 2 && file.processingFormat.sampleRate == 44100)
        #expect(try Data(contentsOf: source) == original, "the original is read only")
    }

    @Test func anExistingDestinationAndTheOriginalAreNeverChanged() async throws {
        let source = try sound()
        let original = try Data(contentsOf: source)
        let output = Fixtures.shared.outputURL("instrumental-exists", ext: "m4a")
        let keep = Data("keep this file".utf8); try keep.write(to: output)
        await #expect(throws: VocalRemover.Failure.destinationExists) { try await VocalRemover.writeInstrumental(source: source, to: output) }
        await #expect(throws: VocalRemover.Failure.destinationExists) { try await VocalRemover.writeInstrumental(source: source, to: source) }
        #expect(try Data(contentsOf: output) == keep && Data(contentsOf: source) == original)
    }

    @Test func cancellingCleansUpThePartialFile() async throws {
        let source = try sound(seconds: 8)
        let output = Fixtures.shared.outputURL("instrumental-cancel", ext: "m4a")
        let (stream, events) = AsyncStream<Double>.makeStream()
        let task = Task { try await VocalRemover.writeInstrumental(source: source, to: output) { events.yield($0) } }
        for await _ in stream { task.cancel(); break }
        await #expect(throws: CancellationError.self) { try await task.value }
        events.finish()
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func silentVideoFailsWithoutCreatingAnOutput() async throws {
        let source = try await Fixtures.shared.source(.init(audio: false))
        let out = Fixtures.shared.outputURL("instrumental-noaudio", ext: "m4a")
        await #expect(throws: VocalRemover.Failure.noAudio) { try await VocalRemover.writeInstrumental(source: source, to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func aShortAudioTrackInALongerVideoCanStillBeSeparated() async throws {
        let source = try await Fixtures.shared.source()
        let asset = AVURLAsset(url: source)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let v = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let a = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)), of: video, at: .zero)
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.7, preferredTimescale: 600)), of: audio, at: .zero)
        let movie = Fixtures.shared.outputURL("short-audio", ext: "mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: movie, as: .mov)
        let duration = try await VocalRemover.audioDuration(of: movie)
        #expect(abs(duration - 0.7) < 0.05)
        let output = Fixtures.shared.outputURL("short-instrumental", ext: "m4a")
        try await VocalRemover.writeInstrumental(source: movie, to: output)
        let made = try await MediaProbe.probe(url: output)
        #expect(abs(made.duration.seconds - duration) < 0.05, "preserve the audio, without rejecting a longer video")
    }
}
