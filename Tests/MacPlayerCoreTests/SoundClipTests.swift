import Foundation
import Testing
@testable import MacPlayerCore

struct SoundClipTests {
    @Test func aProjectWithoutSoundsStoresNothingExtra() throws {
        var p = Project(name: "x")
        #expect(p.soundClips.isEmpty && p.soundClipStore == nil)
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!json.contains("soundClipStore"), "older readers and files stay unchanged when there are no sounds")
        p.soundClips = [SoundClip(name: "m", path: "/a.mp3", start: .zero, duration: MediaTime(seconds: 5))]
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        #expect(back.soundClips.count == 1 && back.soundClips[0].name == "m")
        p.soundClips = []
        #expect(p.soundClipStore == nil)
    }

    @Test func aRecipeFromBeforeSoundsStillLoads() throws {
        let r = RenderRecipe()
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        obj.removeValue(forKey: "soundClips")
        let back = try JSONDecoder().decode(RenderRecipe.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.soundClips.isEmpty)
        #expect(!back.needsReencode)
        var withSound = RenderRecipe(); withSound.soundClips = [SoundClip(name: "m", path: "/a.mp3", start: .zero, duration: MediaTime(seconds: 5))]
        #expect(withSound.needsReencode, "a fast stream copy cannot add a second sound")
        var denoised = RenderRecipe(); denoised.audio.denoise = 0.5
        #expect(denoised.needsReencode)
    }

    @Test func speechIsFoundWhereTheSoundIsLoudAndNotInSilence() {
        // 10 frames of 0.1 s: quiet, speech from 0.3 to 0.7 s, quiet again.
        var rms = [Float](repeating: 0.001, count: 20)
        for i in 6..<14 { rms[i] = 0.2 }
        let r = SpeechDetector.ranges(rms: rms, frameSeconds: 0.1)
        #expect(r.count == 1)
        #expect(abs(r[0].start - 0.5) < 0.11 && abs(r[0].end - 1.6) < 0.25, "start \(r[0].start) end \(r[0].end)")
        #expect(SpeechDetector.ranges(rms: [Float](repeating: 0, count: 50), frameSeconds: 0.1).isEmpty)
    }

    @Test func closeBurstsAreOneSpeechAndTinyBlipsAreIgnored() {
        var rms = [Float](repeating: 0.001, count: 60)
        for i in 10..<16 { rms[i] = 0.3 }; for i in 18..<24 { rms[i] = 0.3 }     // 0.2 s gap: a breath between words
        rms[40] = 0.3                                                             // a click
        let r = SpeechDetector.ranges(rms: rms, frameSeconds: 0.1)
        #expect(r.count == 1, "words with a short gap between are one stretch, a click is no speech")
    }

    @Test func loudnessGainBringsTheAverageToTheTargetButKeepsThePeakSafe() {
        #expect(LoudnessMatch.gainDB(averageDB: -28, peakDB: -12) == 10)
        #expect(LoudnessMatch.gainDB(averageDB: -28, peakDB: -3) == 2, "the peak may not go above the ceiling")
        #expect(LoudnessMatch.gainDB(averageDB: -10, peakDB: -2) == -8, "loud sound is turned down")
        #expect(LoudnessMatch.gainDB(averageDB: -.infinity, peakDB: -.infinity) == 0)
        #expect(LoudnessMatch.gainDB(averageDB: -80, peakDB: -70) == 24, "never more than 24 dB")
    }
}

struct VolumeEnvelopeTests {
    @Test func fadesRiseAndFallInStraightLines() {
        let p = VolumeEnvelope.points(start: 10, end: 20, gain: 1, fadeIn: 2, fadeOut: 4)
        #expect(VolumeEnvelope.gain(at: 10, in: p) == 0 && VolumeEnvelope.gain(at: 20, in: p) == 0)
        #expect(abs(VolumeEnvelope.gain(at: 11, in: p) - 0.5) < 1e-9)
        #expect(VolumeEnvelope.gain(at: 14, in: p) == 1)
        #expect(abs(VolumeEnvelope.gain(at: 18, in: p) - 0.5) < 1e-9)
    }

    @Test func fadesLongerThanTheClipAreCutToHalfEach() {
        let p = VolumeEnvelope.points(start: 0, end: 4, gain: 1, fadeIn: 10, fadeOut: 10)
        #expect(abs(VolumeEnvelope.gain(at: 2, in: p) - 1) < 1e-9, "the two fades meet at full volume")
        #expect(abs(VolumeEnvelope.gain(at: 1, in: p) - 0.5) < 1e-9)
    }

    @Test func musicGoesDownBeforeSpeechStaysDownAndComesBackAfter() {
        let down = pow(10, -14.0 / 20)
        let p = VolumeEnvelope.points(start: 0, end: 30, gain: 1, fadeIn: 0, fadeOut: 0, speech: [(10, 14)], duckGain: down, attack: 0.25, release: 0.6)
        #expect(VolumeEnvelope.gain(at: 5, in: p) == 1)
        #expect(abs(VolumeEnvelope.gain(at: 12, in: p) - down) < 1e-9)
        #expect(abs(VolumeEnvelope.gain(at: 10, in: p) - down) < 1e-9, "already down when the speech starts")
        #expect(VolumeEnvelope.gain(at: 9.9, in: p) < 1 && VolumeEnvelope.gain(at: 9.9, in: p) > down, "on its way down just before")
        #expect(VolumeEnvelope.gain(at: 20, in: p) == 1, "back up after the speech")
    }

    @Test func shortGapsBetweenSpeechDoNotPumpTheMusic() {
        let r = VolumeEnvelope.merged([(1, 2), (2.5, 3), (10, 11)], gap: 0.85)
        #expect(r.count == 2 && r[0].start == 1 && r[0].end == 3)
    }

    @Test func gainAndDuckingAreAppliedTogether() {
        let g = pow(10, -6.0 / 20)
        let p = VolumeEnvelope.points(start: 0, end: 10, gain: g, fadeIn: 0, fadeOut: 0, speech: [(4, 6)], duckGain: 0.5)
        #expect(abs(VolumeEnvelope.gain(at: 5, in: p) - g * 0.5) < 1e-9)
        #expect(abs(VolumeEnvelope.gain(at: 1, in: p) - g) < 1e-9)
    }
}

struct SoundClipCropTests {
    private func clip(_ start: Double, _ length: Double) -> SoundClip {
        SoundClip(name: "m", path: "/a.mp3", start: MediaTime(seconds: start), sourceStart: MediaTime(seconds: 2), duration: MediaTime(seconds: length), fadeIn: 1, fadeOut: 1)
    }
    private func span(_ a: Double, _ b: Double) -> TimeSpan { TimeSpan(start: MediaTime(seconds: a), end: MediaTime(seconds: b)) }

    @Test func aSoundInsideTheSpanMovesBackToWhereTheFileStarts() throws {
        let c = try #require(clip(12, 5).cropped(to: span(10, 30)))
        #expect(abs(c.start.seconds - 2) < 1e-3 && abs(c.duration.seconds - 5) < 1e-3 && c.sourceStart.seconds == 2)
        #expect(c.fadeIn == 1 && c.fadeOut == 1, "it still starts and ends where it did, so its fades stay")
    }

    @Test func aSoundThatStartsBeforeIsCutAndPlaysFromTheRightPlace() throws {
        let c = try #require(clip(8, 10).cropped(to: span(10, 30)))      // 8...18 cut to 10...18
        #expect(c.start.seconds == 0 && abs(c.duration.seconds - 8) < 1e-3)
        #expect(abs(c.sourceStart.seconds - 4) < 1e-3, "2 s of the file are skipped: it was already 2 s in")
        #expect(c.fadeIn == 0 && c.fadeOut == 1)
    }

    @Test func aSoundThatEndsAfterIsCutShortAndOneOutsideIsDropped() throws {
        let c = try #require(clip(25, 10).cropped(to: span(10, 30)))
        #expect(abs(c.start.seconds - 15) < 1e-3 && abs(c.duration.seconds - 5) < 1e-3 && c.fadeOut == 0)
        #expect(clip(40, 5).cropped(to: span(10, 30)) == nil && clip(0, 10).cropped(to: span(10, 30)) == nil, "touching or outside: nothing to play")
    }

    @Test func aFasterVideoShortensTheStretchTheSoundCovers() throws {
        let c = try #require(clip(10, 8).cropped(to: span(10, 30), speed: 2))
        #expect(abs(c.duration.seconds - 4) < 1e-3, "8 s of video at double speed is 4 s")
    }

    @Test func recipesForOneAndSeveralSpansCarryTheSounds() throws {
        let doc = SubtitleDocument()
        let one = RecipeBuilder.recipe(look: VideoLook(), audio: AudioSettings(), overlays: [], subtitles: doc, burnIn: false, span: span(10, 20), soundClips: [clip(5, 30)])
        #expect(one.soundClips.count == 1 && one.soundClips[0].start.seconds == 0 && abs(one.soundClips[0].duration.seconds - 10) < 1e-3)
        let joined = RecipeBuilder.joinedRecipe(look: VideoLook(), audio: AudioSettings(), overlays: [], subtitles: doc, burnIn: false, spans: [span(10, 20), span(40, 45)], soundClips: [clip(0, 100)])
        #expect(joined.soundClips.count == 2)
        #expect(abs(joined.soundClips[1].start.seconds - 10) < 1e-3 && abs(joined.soundClips[1].duration.seconds - 5) < 1e-3, "the second part follows the first")
        #expect(abs(joined.soundClips[1].sourceStart.seconds - 42) < 1e-3, "and plays the music from where it would have been at 40 s: 2 s into the file + 40")
        #expect(joined.soundClips[0].id != joined.soundClips[1].id)
    }
}
