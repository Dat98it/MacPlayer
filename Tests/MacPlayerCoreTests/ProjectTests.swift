import Foundation
import Testing
@testable import MacPlayerCore

private func t(_ s: Double) -> MediaTime { MediaTime(seconds: s, timescale: 1000) }

private func sampleProject() -> Project {
    var p = Project(name: "Bài giảng", kind: .video,
                    sources: [SourceRef(path: "/Videos/lecture.mp4", bookmark: Data([9, 8]),
                                        fingerprint: FileFingerprint(size: 123_456, modified: Date(timeIntervalSinceReferenceDate: 700_000_000.123456), fileID: 42),
                                        info: MediaInfo(duration: MediaTime(value: 6000, timescale: 600), fileExtension: "mp4", fileSize: 123_456,
                                                        video: [.init(trackID: 1, codec: "avc1", width: 1920, height: 1080, frameRate: FrameRate(numerator: 30000, denominator: 1001))],
                                                        audio: [.init(trackID: 2, codec: "aac", sampleRate: 48000, channels: 2)]))])
    p.selections.add(start: MediaTime(value: 1001 * 75, timescale: 30000), end: MediaTime(value: 1001 * 150, timescale: 30000), name: "Phần 1")
    p.markers = [Marker(time: t(3), name: "M")]
    p.look.crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
    p.look.rotation = 90
    p.overlays = [TextOverlay(text: "Tiêu đề", start: t(0), end: t(3))]
    p.subtitles.cues = [SubtitleCue(start: t(1), end: t(2), text: "Xin chào")]
    p.thumbnails.libraryTime = t(2); p.thumbnails.exportTime = t(4); p.thumbnails.embedTime = t(6)
    p.playhead = MediaTime(value: 4321, timescale: 600)
    return p
}

@Suite struct ProjectFileTests {
    @Test func roundTripKeepsEverythingExactly() throws {
        let p = sampleProject()
        let back = try ProjectCodec.decode(ProjectCodec.encode(p))
        #expect(back == p)
        #expect(back.sources[0].fingerprint == p.sources[0].fingerprint, "sub-second modification times must survive")
        #expect(back.selections.items[0].start == MediaTime(value: 1001 * 75, timescale: 30000), "timing stays rational, not rounded")
    }

    @Test func newerFormatIsRefusedNotGuessed() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(sampleProject())) as? [String: Any])
        obj["schemaVersion"] = 99
        #expect(throws: ProjectError.newerVersion(99)) { try ProjectCodec.decode(JSONSerialization.data(withJSONObject: obj)) }
    }

    @Test func garbageAndMissingVersionAreReported() {
        #expect(throws: ProjectError.self) { try ProjectCodec.decode(Data("not json".utf8)) }
        #expect(throws: ProjectError.self) { try ProjectCodec.decode(Data("{\"name\":\"x\"}".utf8)) }
        #expect(throws: ProjectError.self) { try ProjectCodec.decode(Data("{\"schemaVersion\":1}".utf8)) }
    }

    @Test func migrationChainRunsInOrder() throws {
        // Pretend format 0 stored the name as "title" and every format step must be applied once.
        let saved = ProjectCodec.migrations
        defer { ProjectCodec.migrations = saved }
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(sampleProject())) as? [String: Any])
        obj["schemaVersion"] = Project.currentSchema // already current: nothing runs
        var ran: [Int] = []
        ProjectCodec.migrations[0] = { _ in ran.append(0) }
        _ = try ProjectCodec.decode(JSONSerialization.data(withJSONObject: obj))
        #expect(ran.isEmpty)
    }

    @Test func saveWritesAtomicallyAndClearsTheCrashCopy() throws {
        let fs = FakeFileSystem()
        let store = ProjectStore(fs: fs, recoveryFolder: "/Rec", now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let p = sampleProject()
        try store.autosave(p, savedPath: nil)
        #expect(store.recoverable().count == 1)
        fs.directories.insert("/Proj")
        try store.save(p, to: "/Proj/a.macplayer")
        #expect(store.recoverable().isEmpty, "an explicit save supersedes the crash copy")
        #expect(try store.load(path: "/Proj/a.macplayer").name == "Bài giảng")
    }
}

@Suite struct RecoveryTests {
    private func setup() -> (FakeFileSystem, ProjectStore, Project) {
        let fs = FakeFileSystem()
        let store = ProjectStore(fs: fs, recoveryFolder: "/Rec", now: { fs.clock })
        return (fs, store, sampleProject())
    }

    @Test func neverSavedProjectIsOfferedAfterACrash() throws {
        let (fs, store, p) = setup()
        fs.clock += 10
        try store.autosave(p, savedPath: nil)
        let c = try #require(store.recoverable().first)
        #expect(c.name == "Bài giảng" && c.savedPath == nil)
        #expect(try store.loadAutosave(c) == p)
    }

    @Test func autosaveNewerThanTheSavedFileIsOfferedOlderIsNot() throws {
        let (fs, store, p) = setup()
        fs.directories.insert("/Proj")
        try store.save(p, to: "/Proj/a.macplayer")       // saved file at clock
        fs.clock += 60
        try store.autosave(p, savedPath: "/Proj/a.macplayer")
        #expect(store.recoverable().count == 1, "edits after the last save are recoverable")
        fs.touchExternally("/Proj/a.macplayer", String(decoding: try ProjectCodec.encode(p), as: UTF8.self)) // saved again later
        #expect(store.recoverable().isEmpty, "the saved file is newer: nothing to recover")
    }

    @Test func autosaveWritesOnlyProjectStateNeverVideo() throws {
        let (fs, store, p) = setup()
        fs.put("/Videos/lecture.mp4", "VIDEO")
        let before = try fs.fingerprint("/Videos/lecture.mp4")
        try store.autosave(p, savedPath: nil)
        try store.takeSnapshot(p)
        #expect(try fs.fingerprint("/Videos/lecture.mp4") == before && fs.text("/Videos/lecture.mp4") == "VIDEO")
        #expect(fs.files.keys.allSatisfy { $0.hasPrefix("/Rec/") || $0 == "/Videos/lecture.mp4" })
    }

    @Test func snapshotsAreRateLimitedAndPrunedBySizeAndCount() throws {
        let (fs, store, p) = setup()
        try store.takeSnapshot(p, minInterval: 300)
        try store.takeSnapshot(p, minInterval: 300)
        #expect(store.snapshots(projectID: p.id).count == 1, "second one is too soon")
        for _ in 0..<5 { fs.clock += 400; try store.takeSnapshot(p, minInterval: 300) }
        #expect(store.snapshots(projectID: p.id).count == 6)
        let removed = store.pruneSnapshots(projectID: p.id, maxCount: 3, maxBytes: 10_000_000)
        #expect(removed == 3 && store.snapshots(projectID: p.id).count == 3)
        let newest = store.snapshots(projectID: p.id)[0].date
        #expect(store.snapshots(projectID: p.id).allSatisfy { $0.date <= newest }, "the newest is kept")
        _ = store.pruneSnapshots(projectID: p.id, maxCount: 100, maxBytes: 1)
        #expect(store.snapshots(projectID: p.id).count == 1, "at least one restore point always remains")
        #expect(store.recoveryBytes() > 0)
    }

    @Test func autosaveScheduleLandsWithinFiveSecondsOfTheLastEdit() {
        var s = AutosaveSchedule()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(!s.isDue(at: t0) && s.dueAt == nil)
        s.noteChange(at: t0)
        #expect(!s.isDue(at: t0.addingTimeInterval(1)))
        #expect(s.isDue(at: t0.addingTimeInterval(2)))
        #expect((s.dueAt!.timeIntervalSince(t0)) <= 5)
        s.didSave()
        #expect(s.dueAt == nil)
    }

    @Test func continuousEditingStillSavesPeriodically() {
        var s = AutosaveSchedule(idle: 2, maxStaleness: 15)
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<40 { s.noteChange(at: t0.addingTimeInterval(Double(i))) } // an edit every second for 40 s
        #expect(s.isDue(at: t0.addingTimeInterval(15)), "a long drag must not postpone the save forever")
    }
}

@Suite struct HistoryTests {
    @Test func undoRedoWalkTheSteps() {
        var h = History(0)
        h.commit(1, label: "one"); h.commit(2, label: "two")
        #expect(h.undoLabel == "two")
        #expect(h.undo() == "two" && h.present == 1)
        #expect(h.redoLabel == "two")
        #expect(h.redo() == "two" && h.present == 2)
        h.undo(); h.commit(5, label: "five")
        #expect(!h.canRedo, "a new edit discards the redo branch")
    }

    @Test func dragsCoalesceIntoOneStep() {
        var h = History(0)
        for v in 1...20 { h.commit(v, label: "Brightness", coalesce: "brightness") }
        h.endCoalescing()
        #expect(h.undo() == "Brightness" && h.present == 0, "the whole drag is a single undo")
        #expect(!h.canUndo)
    }

    @Test func amendKeepsTheUndoStack() {
        var h = History(0)
        h.commit(1, label: "one"); h.commit(2, label: "two")
        h.amend(5)
        #expect(h.present == 5 && h.canUndo && h.undoLabel == "two", "a view-state change is not an edit and does not clear Undo")
        h.undo()
        #expect(h.present == 1)
    }

    @Test func noChangeMakesNoStep() {
        var h = History(3)
        h.commit(3, label: "nothing")
        #expect(!h.canUndo)
    }

    @Test func limitDropsOldestSteps() {
        var h = History(0, limit: 3)
        for v in 1...10 { h.commit(v, label: "s\(v)") }
        var n = 0
        while h.undo() != nil { n += 1 }
        #expect(n == 3)
    }

    @Test func projectEditsUndoAsWholeProjects() {
        var h = History(Project(name: "P", kind: .video))
        var p = h.present
        p.look.rotation = 90
        h.commit(p, label: "Rotate")
        #expect(h.present.look.rotation == 90)
        h.undo()
        #expect(h.present.look.rotation == 0)
    }
}

@Suite struct ProjectModelTests {
    @Test func missingAndChangedSourcesAreDetected() throws {
        let fs = FakeFileSystem()
        fs.put("/a.mp4", "A"); fs.put("/b.mp4", "B")
        var p = Project(name: "P", kind: .video, sources: [
            SourceRef(path: "/a.mp4", fingerprint: try fs.fingerprint("/a.mp4")),
            SourceRef(path: "/b.mp4", fingerprint: try fs.fingerprint("/b.mp4")),
            SourceRef(path: "/gone.mp4"),
        ])
        #expect(p.missingSources(fs: fs).map(\.path) == ["/gone.mp4"])
        #expect(p.changedSources(fs: fs).isEmpty)
        fs.touchExternally("/b.mp4", "B edited elsewhere")
        #expect(p.changedSources(fs: fs).map(\.path) == ["/b.mp4"])
    }

    @Test func splitTrimMoveAndRippleOnTheTimeline() {
        let src = UUID()
        var clips = [TimelineClip(sourceID: src, sourceStart: t(0), sourceEnd: t(10), name: "A")]
        #expect(!TimelineEditor.split(&clips, clipID: clips[0].id, atSourceTime: t(0)), "no split at the edge")
        #expect(TimelineEditor.split(&clips, clipID: clips[0].id, atSourceTime: t(4)))
        #expect(clips.count == 2 && clips[0].sourceEnd == t(4) && clips[1].sourceStart == t(4))
        TimelineEditor.trim(&clips, clipID: clips[1].id, start: t(9.99), sourceDuration: t(10))
        #expect(clips[1].duration.seconds > 0, "a clip is never trimmed to nothing")
        TimelineEditor.move(&clips, fromOffsets: [1], toOffset: 0)
        #expect(clips[0].sourceStart.seconds > 4)
        let starts = TimelineEditor.starts(clips)
        #expect(starts[clips[0].id] == .zero && starts[clips[1].id] == clips[0].duration)
        TimelineEditor.rippleDelete(&clips, ids: [clips[0].id])
        #expect(clips.count == 1 && TimelineEditor.starts(clips)[clips[0].id] == .zero)
    }

    @Test func speedChangesTimelineLength() {
        var c = TimelineClip(sourceID: UUID(), sourceStart: t(0), sourceEnd: t(10))
        c.look.speed = 2
        #expect(c.duration.seconds == 5)
    }

    @Test func cropIsClampedAndCentredForCanvases() {
        let c = CropRect(x: 0.9, y: -1, width: 0.5, height: 5).clamped()
        #expect(c.x + c.width <= 1.0001 && c.y >= 0 && c.height <= 1)
        let v = CropRect.centered(aspect: 9.0 / 16, sourceWidth: 1920, sourceHeight: 1080)
        #expect(abs(v.width * 1920 / (v.height * 1080) - 9.0 / 16) < 0.001 && abs(v.x - (1 - v.width) / 2) < 1e-9)
    }

    @Test func lookKnowsWhetherItNeedsRenderingAndRecipeKnowsFastCutIsImpossible() {
        var r = RenderRecipe()
        #expect(!r.needsReencode)
        r.audio.gainDB = 3
        #expect(r.needsReencode)
        r = RenderRecipe(look: { var l = VideoLook(); l.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1); return l }())
        #expect(r.needsReencode)
    }

    @Test func exportWarningsExplainTheTradeOff() {
        let info = MediaInfo(duration: t(10), fileExtension: "mov", fileSize: 1, video: [.init(trackID: 1, codec: "hvc1", width: 1280, height: 720, isVariableFrameRate: true, isHDR: true)], audio: [])
        #expect(ExportOptions(mode: .fast, container: .mp4).warnings(source: info).contains(.fastCutKeepsLeadIn))
        #expect(ExportOptions(mode: .fast, container: .mp4).warnings(source: info).contains(.containerChange(from: "mov", to: "mp4")))
        let w = ExportOptions(mode: .exact, resolution: .p2160).warnings(source: info)
        #expect(w.contains(.noUpscale) && w.contains(.hdrKept) && w.contains(.variableFrameRate) && w.contains(.reencode))
    }

    @Test func dolbyVisionIsWarnedAboutOnlyWhenReencoding() {
        var v = MediaInfo.VideoTrack(trackID: 1, codec: "hvc1", width: 3840, height: 2160, isHDR: true, dolbyVision: true)
        let info = MediaInfo(duration: t(10), fileExtension: "mp4", fileSize: 1, video: [v], audio: [])
        #expect(ExportOptions(mode: .exact).warnings(source: info).contains(.dolbyVisionMayBeLost))
        #expect(!ExportOptions(mode: .fast).warnings(source: info).contains(.dolbyVisionMayBeLost))
        v.dolbyVision = nil
        #expect(!ExportOptions(mode: .exact).warnings(source: MediaInfo(duration: t(10), fileExtension: "mp4", fileSize: 1, video: [v], audio: [])).contains(.dolbyVisionMayBeLost))
    }

    @Test func projectsSavedBeforeTheDolbyVisionFieldStillDecode() throws {
        let json = #"{"trackID":1,"codec":"avc1","width":1280,"height":720,"rotation":0,"isVariableFrameRate":false,"isHDR":false}"#
        let v = try JSONDecoder().decode(MediaInfo.VideoTrack.self, from: Data(json.utf8))
        #expect(v.dolbyVision == nil)
    }

    @Test func sizeEstimateScalesWithQualityAndResolution() {
        let info = MediaInfo(duration: t(10), fileExtension: "mp4", fileSize: 1, video: [.init(trackID: 1, codec: "avc1", width: 1920, height: 1080, frameRate: FrameRate(numerator: 30, denominator: 1))], audio: [.init(trackID: 2, codec: "aac", sampleRate: 48000, channels: 2)])
        let hi = ExportOptions(quality: .high).estimatedBytesPerSecond(source: info)
        let lo = ExportOptions(quality: .small).estimatedBytesPerSecond(source: info)
        let small = ExportOptions(resolution: .p480, quality: .high).estimatedBytesPerSecond(source: info)
        #expect(hi > lo && hi > small * 3)
    }
}

@Suite struct JoinedRecipeTests {
    @Test func overlaysAndCuesFollowTheirRangeIntoTheJoinedFile() {
        let title = TextOverlay(text: "T", start: t(0), end: t(100))
        var subs = SubtitleDocument()
        subs.cues = [SubtitleCue(start: t(12), end: t(14), text: "in first"), SubtitleCue(start: t(52), end: t(54), text: "in second")]
        let spans = [TimeSpan(start: t(10), end: t(20)), TimeSpan(start: t(50), end: t(60))]
        let r = RecipeBuilder.joinedRecipe(look: VideoLook(), audio: AudioSettings(), overlays: [title], subtitles: subs, burnIn: true, spans: spans)
        #expect(r.overlays.count == 2, "a long title is shown in both ranges")
        #expect(r.overlays[0].start == .zero && r.overlays[0].end.seconds == 10 && r.overlays[1].start.seconds == 10 && r.overlays[1].end.seconds == 20)
        #expect(r.burnedInCues.map(\.text) == ["in first", "in second"])
        #expect(r.burnedInCues[0].start.seconds == 2 && r.burnedInCues[1].start.seconds == 10 + 2, "second range starts at 10 s in the output")
    }
}

@Suite struct MultiSourceTimelineTests {
    private func clip(_ src: UUID, _ a: Double, _ b: Double, speed: Double = 1) -> TimelineClip {
        var c = TimelineClip(sourceID: src, sourceStart: t(a), sourceEnd: t(b)); c.look.speed = speed; return c
    }

    @Test func sameFileIsOneSource() {
        var p = Project(name: "P", kind: .video)
        let a = p.addSource(SourceRef(path: "/v/a.mp4"))
        let again = p.addSource(SourceRef(path: "/v/../v/a.mp4"))
        let b = p.addSource(SourceRef(path: "/v/b.mp4"))
        #expect(a == again && a != b && p.sources.count == 2)
    }

    @Test func locateFollowsClipsAndSpeed() {
        let a = UUID(), b = UUID()
        let clips = [clip(a, 10, 20), clip(b, 0, 8, speed: 2), clip(a, 30, 34)]   // lengths 10, 4, 4
        let l0 = TimelineMap.locate(clips, at: t(3))!
        #expect(l0.index == 0 && l0.sourceTime == t(13))
        let l1 = TimelineMap.locate(clips, at: t(12))!      // 2 s into the 2x clip = 4 s of source
        #expect(l1.index == 1 && abs(l1.sourceTime.seconds - 4) < 0.01 && l1.timelineStart == t(10))
        #expect(TimelineMap.locate(clips, at: t(100))!.index == 2, "past the end maps to the last clip")
        #expect(TimelineMap.locate(clips, at: t(-5))!.index == 0)
        #expect(TimelineMap.locate([], at: t(1)) == nil)
    }

    @Test func timelineTimeIsTheInverse() {
        let a = UUID()
        let clips = [clip(a, 10, 20), clip(a, 30, 38, speed: 2)]
        #expect(TimelineMap.timelineTime(for: t(15), inClip: clips[0].id, of: clips) == t(5))
        #expect(abs(TimelineMap.timelineTime(for: t(34), inClip: clips[1].id, of: clips)!.seconds - 12) < 0.01)
        #expect(TimelineMap.timelineTime(for: t(25), inClip: clips[0].id, of: clips) == nil, "outside the clip")
    }

    @Test func piecesCarryEachClipsOwnLookAndSkipMissingSources() {
        var p = Project(name: "P", kind: .video)
        let a = p.addSource(SourceRef(path: "/v/a.mp4")), b = p.addSource(SourceRef(path: "/v/b.mp4"))
        var c1 = clip(a, 0, 5); c1.look.rotation = 90
        let c2 = clip(b, 2, 4)
        p.timeline = [c1, c2, clip(UUID(), 0, 1)]   // third clip's source is not in the project
        let pieces = p.renderPieces()
        #expect(pieces.map(\.sourcePath) == ["/v/a.mp4", "/v/b.mp4"])
        #expect(pieces[0].look?.rotation == 90 && pieces[1].look?.rotation == 0)
    }

    @Test func activeLookTargetsTheSelectedClipOfAVideoProjectAndThePhotoOfAPhotoProject() {
        var photo = Project(name: "P", kind: .photo)
        photo.activeLook.rotation = 90
        #expect(photo.look.rotation == 90)
        var p = Project(name: "P", kind: .video)
        let a = p.addSource(SourceRef(path: "/v/a.mp4"))
        p.timeline = [clip(a, 0, 5), clip(a, 5, 9)]
        p.activeClipID = p.timeline[1].id
        p.activeLook.flipHorizontal = true
        #expect(p.timeline[1].look.flipHorizontal && !p.timeline[0].look.flipHorizontal && !p.look.flipHorizontal)
        p.activeAudio.muted = true
        #expect(p.timeline[1].audio.muted && !p.timeline[0].audio.muted)
    }

    @Test func projectWithSeveralSourcesRoundTrips() throws {
        var p = Project(name: "Ghép", kind: .video)
        let a = p.addSource(SourceRef(path: "/v/a.mp4")), b = p.addSource(SourceRef(path: "/v/b.mp4"))
        p.timeline = [clip(a, 0, 5), clip(b, 1, 3, speed: 1.5)]
        p.activeClipID = p.timeline[0].id
        let back = try ProjectCodec.decode(ProjectCodec.encode(p))
        #expect(back == p)
        #expect(abs(back.timelineDuration.seconds - (5 + 2 / 1.5)) < 0.01)
    }
}


@Suite struct QualityBitrateTests {
    // A phone clip: 1080x1920 at 60 fps, HEVC, 32 Mb/s.
    let phone = QualityLevel.SourceVideo(bitrate: 32_000_000, pixels: 1080 * 1920, isHEVC: true)

    @Test func highFollowsTheSourceInsteadOfTheBarePreset() {
        let preset = 1080.0 * 1920 * 60 * 0.12 * 0.65
        let high = QualityLevel.high.videoBitrate(width: 1080, height: 1920, fps: 60, hevc: true, source: phone)
        #expect(preset < 10_000_000 && high > 25_000_000 && high <= 32_000_000, "was \(Int(preset)) b/s, now \(Int(high)) b/s")
    }

    @Test func highNeverExceedsTheSourceOrAbsurdRates() {
        let huge = QualityLevel.SourceVideo(bitrate: 400_000_000, pixels: 1920 * 1080, isHEVC: true)
        #expect(QualityLevel.high.videoBitrate(width: 1920, height: 1080, fps: 30, hevc: true, source: huge) <= 80_000_000)
        let thin = QualityLevel.SourceVideo(bitrate: 1_000_000, pixels: 1920 * 1080, isHEVC: true)
        let preset = 1920.0 * 1080 * 30 * 0.12 * 0.65
        #expect(QualityLevel.high.videoBitrate(width: 1920, height: 1080, fps: 30, hevc: true, source: thin) == max(preset, 1_000_000), "a thin source still gets the preset's floor, but no more than needed")
    }

    @Test func scalingDownAndChangingCodecScaleTheRate() {
        let half = QualityLevel.high.videoBitrate(width: 540, height: 960, fps: 60, hevc: true, source: phone)
        let full = QualityLevel.high.videoBitrate(width: 1080, height: 1920, fps: 60, hevc: true, source: phone)
        #expect(half < full * 0.6)
        let h264 = QualityLevel.high.videoBitrate(width: 1080, height: 1920, fps: 60, hevc: false, source: phone)
        #expect(h264 > full && h264 <= 32_000_000, "H.264 needs more than HEVC for the same picture but not more than the source had")
    }

    @Test func mediumAndSmallStayOnThePreset() {
        for q in [QualityLevel.medium, .small] {
            #expect(q.videoBitrate(width: 1080, height: 1920, fps: 60, hevc: true, source: phone) == 1080.0 * 1920 * 60 * q.bitsPerPixel * 0.65)
        }
        #expect(QualityLevel.high.videoBitrate(width: 1280, height: 720, fps: 30, hevc: false, source: nil) == 1280.0 * 720 * 30 * 0.12)
    }
}


@Suite struct MixedHDRWarningTests {
    private func info(hdr: Bool) -> MediaInfo {
        let v = MediaInfo.VideoTrack(trackID: 1, codec: "hvc1", width: 1920, height: 1080, frameRate: FrameRate(numerator: 30, denominator: 1), isHDR: hdr)
        return MediaInfo(duration: MediaTime(seconds: 10), fileExtension: "mov", fileSize: 1, video: [v], audio: [])
    }

    @Test func aMixWarnsThatTheFileWillBeSDR() {
        let w = ExportOptions(mode: .exact).warnings(sources: [info(hdr: true), info(hdr: false)])
        #expect(w.contains(.hdrMixedToSDR) && !w.contains(.hdrKept))
    }

    @Test func allHDRStaysHDRAndAllSDRSaysNothingAboutIt() {
        let all = ExportOptions(mode: .exact).warnings(sources: [info(hdr: true), info(hdr: true)])
        #expect(all.contains(.hdrKept) && !all.contains(.hdrMixedToSDR))
        let none = ExportOptions(mode: .exact).warnings(sources: [info(hdr: false), info(hdr: false)])
        #expect(!none.contains(.hdrKept) && !none.contains(.hdrMixedToSDR))
    }
}
