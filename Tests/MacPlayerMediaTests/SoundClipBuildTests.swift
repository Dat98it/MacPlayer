import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct SoundClipBuildTests {
    private let rate = 44100.0

    private func tone(_ seconds: Double, amp: Float = 0.4, freq: Double = 330, name: String) throws -> URL {
        try TestSound.write(TestSound.samples(seconds: seconds, tones: [.init(from: 0, to: seconds, amp: amp, freq: freq)], noise: 0), name: name)
    }

    private func clip(_ url: URL, at start: Double, for length: Double, kind: SoundKind = .music, _ f: (inout SoundClip) -> Void = { _ in }) -> SoundClip {
        var c = SoundClip(name: url.lastPathComponent, path: url.path, kind: kind, start: MediaTime(seconds: start, timescale: 600), duration: MediaTime(seconds: length, timescale: 600))
        f(&c); return c
    }

    private func build(_ main: URL, _ clips: [SoundClip], seconds: Int64 = 4, accurate: Bool = false) async throws -> BuiltRender {
        try await CompositionBuilder.build(pieces: [RenderPiece(sourceURL: main, span: span30(0, seconds * 30))], includeAudio: true, soundClips: clips, frameAccurate: accurate)
    }

    /// Where a track really has sound (a track that starts with a gap reports the gap as part of its range).
    private func played(_ track: AVAssetTrack) -> (start: Double, end: Double)? {
        let segs = ((track as? AVCompositionTrack)?.segments ?? []).filter { !$0.isEmpty }
        guard let a = segs.first, let b = segs.last else { return nil }
        return (a.timeMapping.target.start.seconds, b.timeMapping.target.end.seconds)
    }

    /// The gain the mix gives a track at a moment.
    private func volume(_ built: BuiltRender, track: AVAssetTrack, at t: Double) -> Float? {
        guard let p = built.audioMix?.inputParameters.first(where: { $0.trackID == track.trackID }) else { return nil }
        var s: Float = 1, e: Float = 1; var range = CMTimeRange.zero
        let time = CMTime(seconds: t, preferredTimescale: 6000)
        guard p.getVolumeRamp(for: time, startVolume: &s, endVolume: &e, timeRange: &range) else {
            // Past the last ramp the volume stays where that ramp left it.
            var back = t - 0.05
            while back > 0 {
                if p.getVolumeRamp(for: CMTime(seconds: back, preferredTimescale: 6000), startVolume: &s, endVolume: &e, timeRange: &range) { return range.end.seconds <= t ? e : nil }
                back -= 0.05
            }
            return nil
        }
        // Before a ramp the volume is the one the ramp starts from; inside it it moves in a straight line.
        let len = range.duration.seconds
        guard t >= range.start.seconds, len > 0 else { return s }
        return s + (e - s) * Float((t - range.start.seconds) / len)
    }

    @Test func aSoundIsPlacedWhereItIsToStartAndNeverRunsPastTheEnd() async throws {
        let main = try await Fixtures.shared.source()                                  // 4 s
        let music = try tone(10, name: "music")
        let built = try await build(main, [clip(music, at: 1, for: 10)])
        #expect(abs(built.duration.seconds - 4) < 0.1, "the video is no longer for the music: \(built.duration.seconds)")
        let audio = try await built.composition.loadTracks(withMediaType: .audio)
        #expect(audio.count == 2, "the video's sound and the music")
        let musicTrack = try #require(audio.last)
        let range = try #require(played(musicTrack))
        #expect(abs(range.start - 1) < 0.05 && abs(range.end - 4) < 0.1, "plays from \(range.start) to \(range.end)")
    }

    @Test func aMutedSoundAddsNothingAndASoundPastTheEndIsLeftOut() async throws {
        let main = try await Fixtures.shared.source()
        let music = try tone(3, name: "m2")
        let built = try await build(main, [clip(music, at: 0, for: 3) { $0.muted = true }, clip(music, at: 9, for: 3)])
        #expect(try await built.composition.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func partOfAFileCanPlayFromWhereItIsTold() async throws {
        let main = try await Fixtures.shared.source()
        let music = try tone(10, name: "m3")
        let built = try await build(main, [clip(music, at: 0.5, for: 2) { $0.sourceStart = MediaTime(seconds: 4, timescale: 600) }])
        let t = try #require(try await built.composition.loadTracks(withMediaType: .audio).last)
        let range = try #require(played(t))
        #expect(abs(range.start - 0.5) < 0.05 && abs(range.end - 2.5) < 0.1, "\(range.start) to \(range.end)")
    }

    @Test func gainAndFadesShapeTheVolume() async throws {
        let main = try await Fixtures.shared.source()
        let music = try tone(10, name: "m4")
        let built = try await build(main, [clip(music, at: 0, for: 4) { $0.gainDB = -6; $0.fadeIn = 1; $0.fadeOut = 1 }])
        let t = try #require(try await built.composition.loadTracks(withMediaType: .audio).last)
        let half = Float(pow(10, -6.0 / 20))
        #expect(abs((volume(built, track: t, at: 0.01) ?? 9) - 0) < 0.05, "silent at the very start")
        #expect(abs((volume(built, track: t, at: 2) ?? 0) - half) < 0.02, "-6 dB in the middle")
        #expect(abs((volume(built, track: t, at: 0.5) ?? 0) - half * 0.5) < 0.03, "half way up the fade")
        #expect((volume(built, track: t, at: 3.9) ?? 9) < 0.15, "nearly silent at the end")
    }

    @Test func musicGoesDownWhileAVoiceOverSpeaksAndComesBack() async throws {
        let main = try await Fixtures.shared.source(.init(seconds: 8, audio: false))
        let music = try tone(8, name: "bg")
        // the voice: silent except for 3 s...5 s
        let voice = try TestSound.write(TestSound.samples(seconds: 8, tones: [.init(from: 3, to: 5, amp: 0.4, freq: 220)], noise: 0.002), name: "voice")
        let built = try await build(main, [clip(music, at: 0, for: 8) { $0.ducking = true; $0.duckDepthDB = -12 }, clip(voice, at: 0, for: 8, kind: .voice)], seconds: 8)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let musicTrack = try #require(tracks.first)
        let down = Float(pow(10, -12.0 / 20))
        #expect(abs((volume(built, track: musicTrack, at: 1) ?? 0) - 1) < 0.02, "full before the voice")
        #expect(abs((volume(built, track: musicTrack, at: 4) ?? 0) - down) < 0.03, "down while the voice speaks: \(volume(built, track: musicTrack, at: 4) ?? -1)")
        #expect(abs((volume(built, track: musicTrack, at: 7) ?? 0) - 1) < 0.02, "back after")
        // Without the switch the music is left alone.
        let plain = try await build(main, [clip(music, at: 0, for: 8), clip(voice, at: 0, for: 8, kind: .voice)], seconds: 8)
        let plainTrack = try #require(try await plain.composition.loadTracks(withMediaType: .audio).first)
        #expect(abs((volume(plain, track: plainTrack, at: 4) ?? 1) - 1) < 0.02)
    }

    @Test func musicGoesDownWhileTheVideosOwnSoundSpeaks() async throws {
        // The video's own sound: a long loud stretch in the middle (made with a test sound laid under a silent video as a "recording").
        let silent = try await Fixtures.shared.source(.init(seconds: 8, audio: false))
        let speechSound = try TestSound.write(TestSound.samples(seconds: 8, tones: [.init(from: 3, to: 5, amp: 0.4, freq: 220)], noise: 0.002), name: "ownvoice")
        let withVoice = Fixtures.shared.outputURL("own-voice")
        // Make a video that has that sound: export the silent video with a replacement audio.
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: silent, span: TimeSpan(start: .zero, end: MediaTime(seconds: 7.9)))],
                                          recipe: { var r = RenderRecipe(); r.audio.replacementPath = speechSound.path; return r }(), to: withVoice, options: ExportOptions(mode: .exact))
        let music = try tone(8, name: "bg2")
        let built = try await CompositionBuilder.build(pieces: [RenderPiece(sourceURL: withVoice, span: TimeSpan(start: .zero, end: MediaTime(seconds: 7.5)))], includeAudio: true,
                                                       soundClips: [clip(music, at: 0, for: 7.5) { $0.ducking = true; $0.duckDepthDB = -12 }], frameAccurate: false)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let musicTrack = try #require(tracks.last)
        #expect(abs((volume(built, track: musicTrack, at: 1) ?? 0) - 1) < 0.02)
        #expect((volume(built, track: musicTrack, at: 4) ?? 1) < 0.3, "down while the video speaks: \(volume(built, track: musicTrack, at: 4) ?? -1)")
    }

    @Test func theExportHasTheMusicInIt() async throws {
        let main = try await Fixtures.shared.source(.init(seconds: 4, audio: false))
        let music = try tone(4, amp: 0.5, name: "m5")
        let out = Fixtures.shared.outputURL("with-music")
        let recipe = RenderRecipe(soundClips: [clip(music, at: 1, for: 2)])
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: main, span: span30(0, 120))], recipe: recipe, to: out, options: ExportOptions(mode: .exact))
        let info = try await MediaProbe.probe(url: out)
        #expect(info.hasAudio, "a video that had no sound now has the music")
        let r = try await AudioAnalysis.rms(asset: AVURLAsset(url: out), frameSeconds: 0.5)
        func level(_ a: Double, _ b: Double) -> Float { let s = r.frames[Int(a / 0.5)..<min(r.frames.count, Int(b / 0.5))]; return s.reduce(0, +) / Float(s.count) }
        #expect(level(1.2, 2.8) > 0.1, "music playing: \(level(1.2, 2.8))")
        #expect(level(0, 0.8) < 0.02 && level(3.3, 3.9) < 0.02, "and silence around it: \(level(0, 0.8)) / \(level(3.3, 3.9))")
    }

    @Test func noiseReductionIsUsedByAnExportAndWaitsInAPreview() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-denoise-build-\(UUID().uuidString.prefix(6))")
        NoiseReducer.cacheFolder = folder
        let main = try await Fixtures.shared.source()
        var audio = AudioSettings(); audio.denoise = 0.5
        let piece = RenderPiece(sourceURL: main, span: span30(0, 90), audio: audio)
        _ = try await CompositionBuilder.build(pieces: [piece], includeAudio: true, frameAccurate: false)
        #expect(NoiseReducer.cached(for: main, strength: 0.5) == nil, "a preview does not make the cleaned copy (it would hold the picture up)")
        _ = try await CompositionBuilder.build(pieces: [piece], includeAudio: true, frameAccurate: true)
        #expect(NoiseReducer.cached(for: main, strength: 0.5) != nil, "an export makes it")
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func aRecipeWithSoundClipsAndNoiseReductionNeedsTheExactMode() async throws {
        let main = try await Fixtures.shared.source()
        let music = try tone(2, name: "m6")
        let recipe = RenderRecipe(soundClips: [clip(music, at: 0, for: 2)])
        let out = Fixtures.shared.outputURL("fast-music")
        do {
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: main, span: span30(0, 60))], recipe: recipe, to: out, options: ExportOptions(mode: .fast))
            Issue.record("a fast cut cannot add music")
        } catch let e as ExportError { if case .incompatible = e {} else { Issue.record("wrong error \(e)") } }
    }
}
