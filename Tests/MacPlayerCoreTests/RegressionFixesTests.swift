import Foundation
import Testing
@testable import MacPlayerCore

/// Regression tests for the faults found by running the app on real footage (0.7.1).
struct RegressionFixesTests {
    // MARK: One test for "can this be a fast cut" (the Export panel and the export plan used to disagree)

    @Test func aFastCutNeedsNothingToChange() {
        var p = Project(name: "t")
        #expect(p.allowsFastCut)
        var sped = p; sped.look.speed = 2
        #expect(!sped.allowsFastCut, "a different speed changes the picture and sound")
        var music = p; music.soundClips = [SoundClip(name: "m", path: "/x.m4a", kind: .music, start: .zero, duration: MediaTime(seconds: 5))]
        #expect(!music.allowsFastCut, "a sound added on top cannot be copied through")
        var gain = p; gain.audio.gainDB = 3
        #expect(!gain.allowsFastCut)
        var over = p; over.overlays = [TextOverlay(text: "hi", start: .zero, end: MediaTime(seconds: 1))]
        #expect(!over.allowsFastCut)
        p.subtitles.cues = [SubtitleCue(start: .zero, end: MediaTime(seconds: 1), text: "a")]
        p.subtitles.burnIn = false
        #expect(p.allowsFastCut, "subtitles kept beside the video do not stop a fast cut")
        p.subtitles.burnIn = true
        #expect(!p.allowsFastCut, "burned-in subtitles do")
    }

    // MARK: Several ranges joined into one file keep the "burn subtitles in" choice

    @Test func joinedRangesBurnSubtitlesOnlyWhenAsked() {
        var subs = SubtitleDocument()
        subs.cues = [SubtitleCue(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2), text: "xin chào")]
        let spans = [TimeSpan(start: .zero, end: MediaTime(seconds: 3)), TimeSpan(start: MediaTime(seconds: 5), end: MediaTime(seconds: 8))]
        let off = RecipeBuilder.joinedRecipe(look: VideoLook(), audio: AudioSettings(), overlays: [], subtitles: subs, burnIn: false, spans: spans)
        #expect(off.burnedInCues.isEmpty && !off.needsReencode)
        let on = RecipeBuilder.joinedRecipe(look: VideoLook(), audio: AudioSettings(), overlays: [], subtitles: subs, burnIn: true, spans: spans)
        #expect(on.burnedInCues.count == 1 && on.needsReencode)
    }

    // MARK: A cut zoom-and-move animation keeps turning

    @Test func cuttingAnAnimationKeepsItsTurnAndEasing() {
        let kf = [MotionKeyframe(time: 0, scale: 1, rotation: 0, easing: .easeIn), MotionKeyframe(time: 4, scale: 1, rotation: 90)]
        let at2 = Motion.state(kf, at: 2)!
        let cut = Motion.shifted(kf, by: -2)
        #expect(cut.first?.time == 0)
        #expect(abs((cut.first?.rotation ?? 0) - at2.rotation) < 0.001, "the first keyframe starts at the angle the picture had at the cut")
        #expect(cut.first?.easing == .easeIn)
        #expect(Motion.state(cut, at: 0)!.rotation > 0)
    }

    // MARK: A freeze frame holds for as long as asked

    @Test func aLongFreezeFrameIsAsLongAsRequested() {
        let src = UUID()
        let fd = MediaTime(value: 1, timescale: 30)
        for hold in [0.5, 2, 8, 10] {
            var clips = [TimelineClip(sourceID: src, sourceStart: .zero, sourceEnd: MediaTime(seconds: 20))]
            let id = TimelineEditor.freezeFrame(&clips, clipID: clips[0].id, atSourceTime: MediaTime(seconds: 5), frameDuration: fd, hold: hold)!
            let frozen = clips.first { $0.id == id }!
            #expect(abs(frozen.duration.seconds - hold) < 0.05, "held \(frozen.duration.seconds) s for \(hold) s")
        }
    }

    // MARK: Old files and files that lack a setting still open

    @Test func soundSettingsMissingFromAFileOpenWithThemOff() throws {
        let old = #"{"gainDB":3,"muted":false}"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(AudioSettings.self, from: old)
        #expect(a.gainDB == 3 && a.fadeIn == 0 && a.fadeOut == 0 && a.offsetSeconds == 0 && a.denoise == nil && a.fx == nil)
        let none = try JSONDecoder().decode(AudioSettings.self, from: "{}".data(using: .utf8)!)
        #expect(none.isNeutral)
        // And a full round trip is unchanged.
        var full = AudioSettings(); full.gainDB = -2; full.offsetSeconds = 0.4; full.denoise = 0.5; full.replacementPath = "/a.m4a"
        #expect(try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(full)) == full)
    }

    // MARK: Jobs restored after a crash wait for the person, and never hold up a new job

    private func job(_ name: String, restored: Bool, at t: Double) -> ExportJob {
        var j = ExportJob(label: name, pieces: [JobPiece(sourcePath: "/s.mp4", span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)))],
                          options: ExportOptions(), target: .newCopy(path: "/o/\(name).mp4", overwrite: false), now: Date(timeIntervalSince1970: t))
        j.restoredAfterCrash = restored
        return j
    }

    @Test func restoredJobsDoNotTakeTheNewJobsPlace() {
        var q = ExportQueueModel(); q.maxConcurrent = 1
        q.enqueue([job("old", restored: true, at: 1), job("new", restored: false, at: 2)])
        #expect(q.nextToStart(includeRestored: false).map(\.label) == ["new"], "the new job starts although an older, restored one is waiting")
        #expect(q.nextToStart().first?.label == "old")
        q.releaseRestored()
        #expect(q.pending.allSatisfy { !$0.restoredAfterCrash })
        #expect(q.nextToStart(includeRestored: false).first?.label == "old", "once released, the oldest job goes first")
    }
}
