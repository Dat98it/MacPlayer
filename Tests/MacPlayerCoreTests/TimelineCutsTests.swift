import Foundation
import Testing
@testable import MacPlayerCore

/// 0.19: removing the part before/after the playhead, deleting several clips, and what lies over the main track following along.
struct TimelineCutsTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 6000) }
    private func near(_ a: MediaTime, _ b: Double) -> Bool { abs(a.seconds - b) < 0.002 }

    /// Three clips of 10 s (0–10, 10–20, 20–30), a text over each, a song over everything, a sound effect and a layer over the last clip.
    private func project() -> (Project, [UUID]) {
        var p = Project(name: "Cuts", kind: .video)
        let src = UUID()
        p.timeline = (0..<3).map { i in TimelineClip(sourceID: src, sourceStart: s(Double(i) * 100), sourceEnd: s(Double(i) * 100 + 10), name: "C\(i + 1)") }
        p.overlays = (0..<3).map { i in TextOverlay(text: "T\(i + 1)", start: s(Double(i) * 10 + 2), end: s(Double(i) * 10 + 6)) }
        p.soundClips = [SoundClip(name: "song", path: "/song.mp3", start: .zero, duration: s(30)),
                        SoundClip(name: "boom", path: "/boom.wav", kind: .effect, start: s(23), duration: s(2))]
        p.overlayClips = [OverlayClip(name: "logo", kind: .image(path: "/logo.png", bookmark: nil), start: s(21), duration: s(5))]
        p.markers = [Marker(time: s(15)), Marker(time: s(25))]
        p.subtitles.cues = [SubtitleCue(start: s(12), end: s(14), text: "middle"), SubtitleCue(start: s(25), end: s(27), text: "last")]
        return (p, p.timeline.map(\.id))
    }

    @Test func removingThePartBeforeThePlayheadShortensTheClipAndPullsTheRestIn() throws {
        var (p, ids) = project()
        // The playhead at 14 s on the timeline = 4 s into clip 2 (source 104).
        let span = try #require(TimelineCuts.trim(&p, clip: ids[1], at: s(104), removing: .beforePlayhead, ripple: true))
        #expect(near(span.start, 10) && near(span.end, 14))
        #expect(near(p.timeline[1].sourceStart, 104) && near(p.timeline[1].duration, 6))
        // Clip 2's text (12–16) started inside the removed part: it now starts at the cut and keeps its last 2 s over the same pictures.
        #expect(near(p.overlays[1].start, 10) && near(p.overlays[1].end, 12))
        #expect(near(p.overlays[0].start, 2), "before the cut: unchanged")
        #expect(near(p.overlays[2].start, 18) && near(p.overlays[2].end, 22), "after the cut: 4 s earlier")
        #expect(near(p.soundClips[0].start, 0) && near(p.soundClips[0].duration, 26), "the song runs across: it goes on, 4 s shorter")
        #expect(near(p.soundClips[1].start, 19), "the effect stays on its picture")
        #expect(near(p.overlayClips[0].start, 17))
        #expect(near(p.markers[0].time, 11) && near(p.markers[1].time, 21))
        #expect(p.subtitles.cues.map(\.text) == ["last"] && near(p.subtitles.cues[0].start, 21), "the line said over the removed pictures goes")
    }

    @Test func removingThePartAfterThePlayheadKeepsTheStart() throws {
        var (p, ids) = project()
        let span = try #require(TimelineCuts.trim(&p, clip: ids[0], at: s(5), removing: .afterPlayhead, ripple: true))
        #expect(near(span.start, 5) && near(span.end, 10))
        #expect(near(p.timeline[0].sourceStart, 0) && near(p.timeline[0].sourceEnd, 5))
        #expect(near(p.overlays[0].start, 2) && near(p.overlays[0].end, 5), "text 2–6 crossed the cut: it ends at the cut")
        #expect(near(p.overlays[1].start, 7))
    }

    @Test func withoutFollowingNothingElseMoves() throws {
        var (p, ids) = project()
        let before = p
        _ = try #require(TimelineCuts.trim(&p, clip: ids[1], at: s(104), removing: .beforePlayhead, ripple: false))
        #expect(p.overlays == before.overlays && p.soundClips == before.soundClips && p.markers == before.markers && p.overlayClips == before.overlayClips)
    }

    @Test func aPlayheadOnAClipsEdgeRemovesNothing() {
        var (p, ids) = project()
        let before = p
        #expect(TimelineCuts.trim(&p, clip: ids[1], at: s(100), removing: .beforePlayhead, ripple: true) == nil)
        #expect(TimelineCuts.trim(&p, clip: ids[1], at: s(110), removing: .afterPlayhead, ripple: true) == nil)
        #expect(p == before)
    }

    @Test func deletingSeveralClipsCarriesTheirNeighboursAlong() {
        var (p, ids) = project()
        TimelineCuts.delete(&p, clips: [ids[0], ids[1]], ripple: true)
        #expect(p.timeline.map(\.id) == [ids[2]])
        // The last clip's text (22–26) is now at 2–6; texts that were over deleted clips are kept, at the cut, with their own length.
        #expect(near(p.overlays[2].start, 2) && near(p.overlays[2].end, 6))
        #expect(p.overlays.count == 3 && near(p.overlays[0].start, 0) && near(p.overlays[0].end, 4))
        #expect(near(p.soundClips[1].start, 3) && near(p.overlayClips[0].start, 1))
        #expect(near(p.soundClips[0].duration, 10), "the song now lasts as long as what is left")
        #expect(p.subtitles.cues.map(\.text) == ["last"], "the words of deleted pictures go with them")
        #expect(near(p.subtitles.cues[0].start, 5))
    }

    @Test func aSoundStartingInsideTheCutSkipsItsFirstPart() throws {
        var (p, ids) = project()
        p.soundClips = [SoundClip(name: "voice", path: "/v.m4a", kind: .voice, start: s(12), sourceStart: s(1), duration: s(6))]
        p.soundClips[0].volumeCurve = [VolumePoint(time: 0, gainDB: -10), VolumePoint(time: 4, gainDB: 0)]
        _ = try #require(TimelineCuts.trim(&p, clip: ids[1], at: s(104), removing: .beforePlayhead, ripple: true))
        // 12–18 with 10–14 removed: 2 s of it went; it now starts at 10, 2 s further into its file, for 4 s.
        #expect(near(p.soundClips[0].start, 10) && near(p.soundClips[0].sourceStart, 3) && near(p.soundClips[0].duration, 4))
        #expect(abs((p.soundClips[0].volumeCurve?.first?.gainDB ?? 99) - -5) < 0.01, "the volume curve moves with it")
    }

    @Test func aVideoLayerStartingInsideTheCutSkipsItsFirstPart() throws {
        var (p, ids) = project()
        let v = UUID()
        p.overlayClips = [OverlayClip(name: "pip", kind: .video(sourceID: v, sourceStart: s(50), sourceEnd: s(56)), start: s(12), duration: s(6),
                                      keyframes: [OverlayKeyframe(time: s(3), centerX: 0.2, centerY: 0.2, width: 0.3, opacity: 1)])]
        _ = try #require(TimelineCuts.trim(&p, clip: ids[1], at: s(104), removing: .beforePlayhead, ripple: true))
        guard case .video(_, let ss, let se) = p.overlayClips[0].kind else { Issue.record("kind changed"); return }
        #expect(near(p.overlayClips[0].start, 10) && near(p.overlayClips[0].duration, 4) && near(ss, 52) && near(se, 56))
        #expect(near(p.overlayClips[0].keyframes[0].time, 1), "its keyframe stays on the same picture")
    }

    @Test func draggingAnEdgeOutPushesLaterThingsAndInPullsThem() {
        var (p, ids) = project()
        let before = p.timeline
        TimelineEditor.trim(&p.timeline, clipID: ids[0], end: s(13), sourceDuration: s(1000))   // clip 1: 10 → 13 s
        TimelineRipple.followTrim(of: ids[0], leftEdge: false, before: before, in: &p)
        #expect(near(p.overlays[0].start, 2), "over the clip that grew: stays")
        #expect(near(p.overlays[1].start, 15) && near(p.markers[0].time, 18))
        let before2 = p.timeline
        TimelineEditor.trim(&p.timeline, clipID: ids[2], start: s(203), sourceDuration: s(1000))   // clip 3 loses its first 3 s
        TimelineRipple.followTrim(of: ids[2], leftEdge: true, before: before2, in: &p)
        #expect(near(p.overlays[2].start, 23) && near(p.overlays[2].end, 26), "text 25–29 → 2 s of it was over the removed part")
    }

    @Test func shiftClickPicksEveryClipBetween() {
        let (p, ids) = project()
        #expect(TimelineCuts.range(in: p.timeline, from: ids[2], to: ids[0]) == ids)
        #expect(TimelineCuts.range(in: p.timeline, from: ids[1], to: ids[1]) == [ids[1]])
    }

    @Test func reorderingCarriesWhatLiesOverEachClip() {
        var (p, ids) = project()
        let before = p.timeline
        TimelineEditor.move(&p.timeline, fromOffsets: [2], toOffset: 0)       // clip 3 first: 3, 1, 2
        TimelineRipple.followReorder(before: before, in: &p)
        #expect(near(p.overlays[2].start, 2) && near(p.overlays[2].end, 6), "clip 3's text (22–26) is now over it at 0–10")
        #expect(near(p.overlays[0].start, 12) && near(p.overlays[1].start, 22))
        #expect(near(p.soundClips[0].start, 0) && near(p.soundClips[0].duration, 30), "the song under everything stays")
        #expect(near(p.soundClips[1].start, 3) && near(p.overlayClips[0].start, 1))
        #expect(near(p.markers[0].time, 25) && near(p.markers[1].time, 5))
        #expect(near(p.subtitles.cues.first { $0.text == "last" }!.start, 5))
    }

    @Test func movingSeveralClipsKeepsTheirOrder() {
        var (p, ids) = project()
        TimelineEditor.move(&p.timeline, fromOffsets: [0, 1], toOffset: 3)
        #expect(p.timeline.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func aFasterClipKeepsItsTextsOnItsPicturesAndPullsTheRestIn() {
        var (p, ids) = project()
        let before = p.timeline
        p.timeline[1].look.speed = 2                                         // clip 2: 10 s → 5 s
        TimelineRipple.followSpeed(of: ids[1], before: before, in: &p)
        #expect(near(p.overlays[1].start, 11) && near(p.overlays[1].end, 13), "12–16 over clip 2 → 11–13")
        #expect(near(p.overlays[0].start, 2), "before it: unchanged")
        #expect(near(p.overlays[2].start, 17), "after it: 5 s earlier")
        #expect(near(p.soundClips[0].start, 0) && near(p.soundClips[0].duration, 30), "the song starts before it: unchanged")
        #expect(near(p.markers[0].time, 12.5) && near(p.markers[1].time, 20))
        #expect(near(p.subtitles.cues[0].start, 11) && near(p.subtitles.cues[0].end, 12))
    }

    @Test func aSubtitleRunningIntoTheNextClipGoesWithItsOwnClip() {
        var (p, _) = project()
        p.subtitles.cues = [SubtitleCue(start: s(8), end: s(10.5), text: "end of one")]   // mostly over clip 1 (0–10)
        p.overlays = [TextOverlay(text: "title", start: s(5), end: s(25))]               // over all three
        let before = p.timeline
        TimelineEditor.move(&p.timeline, fromOffsets: [0], toOffset: 3)                // 2, 3, 1
        TimelineRipple.followReorder(before: before, in: &p)
        #expect(near(p.subtitles.cues[0].start, 28) && near(p.subtitles.cues[0].end, 30), "with clip 1, now at 20–30, cut to its end")
        #expect(near(p.overlays[0].start, 5) && near(p.overlays[0].end, 25), "a title over several clips stays")
    }
}
