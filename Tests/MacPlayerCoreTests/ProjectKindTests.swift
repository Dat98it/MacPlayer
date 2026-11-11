import Foundation
import Testing
@testable import MacPlayerCore

private func t(_ s: Double) -> MediaTime { MediaTime(seconds: s, timescale: 6000) }
private func info(_ seconds: Double, w: Int = 1920, h: Int = 1080) -> MediaInfo {
    MediaInfo(duration: t(seconds), fileExtension: "mp4", fileSize: 1000, video: [.init(trackID: 1, codec: "avc1", width: w, height: h)], audio: [])
}

/// What MacPlayer 0.7 wrote: a "quick" edit (one video or photo, edited directly) in schema 2.
private func oldFile(_ p: Project, mode: String = "quick", schema: Int = 2) throws -> Data {
    var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(p)) as? [String: Any])
    obj["schemaVersion"] = schema
    obj["mode"] = mode
    obj.removeValue(forKey: "kind")
    return try JSONSerialization.data(withJSONObject: obj)
}

@Suite struct ProjectUpgradeTests {
    @Test func anOldQuickEditOfAVideoBecomesAVideoProjectWithOneClipCarryingTheEdit() throws {
        var p = Project(name: "Lecture", kind: .video, sources: [SourceRef(path: "/v/lecture.mp4", info: info(60))])
        p.look.rotation = 90; p.look.color.brightness = 0.2; p.audio.gainDB = 3
        p.overlays = [TextOverlay(text: "Title", start: t(1), end: t(3))]
        p.subtitles.cues = [SubtitleCue(start: t(2), end: t(4), text: "hi")]
        p.selections.add(start: t(5), end: t(10), name: "Part 1")
        let (back, schema) = try ProjectCodec.decodeDetailed(oldFile(p))
        #expect(schema == 2 && back.schemaVersion == Project.currentSchema)
        #expect(back.kind == .video && back.mode == nil)
        #expect(back.timeline.count == 1 && back.timeline[0].sourceStart == .zero && back.timeline[0].sourceEnd == t(60))
        #expect(back.timeline[0].look.rotation == 90 && back.timeline[0].look.color.brightness == 0.2 && back.timeline[0].audio.gainDB == 3, "the edit moves onto the clip")
        #expect(back.look.isNeutral && back.audio.isNeutral, "and the whole-video settings are cleared, as in a video project")
        #expect(back.activeClipID == back.timeline[0].id)
        #expect(back.overlays == p.overlays && back.subtitles.cues == p.subtitles.cues, "text and subtitles stay where they were")
        #expect(back.selections.items.count == 1 && back.selections.items[0].name == "Part 1", "In/Out ranges are kept in the file, not lost")
        let written = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(back)) as? [String: Any])
        #expect(written["mode"] == nil && written["kind"] as? String == "video", "the old mode is never written again")
    }

    @Test func soundsAndMarkersFollowTheSpeedAsTheOldExportDid() throws {
        var p = Project(name: "Fast", kind: .video, sources: [SourceRef(path: "/v/a.mp4", info: info(20))])
        p.look.speed = 2
        p.soundClips = [SoundClip(name: "m", path: "/m.m4a", kind: .music, start: t(4), duration: t(4))]
        p.markers = [Marker(time: t(10), name: "M")]
        let back = try ProjectCodec.decode(oldFile(p))
        #expect(abs(back.timelineDuration.seconds - 10) < 0.01)
        #expect(abs(back.soundClips[0].start.seconds - 2) < 0.01 && abs(back.soundClips[0].duration.seconds - 2) < 0.01)
        #expect(abs(back.markers[0].time.seconds - 5) < 0.01)
    }

    @Test func anOldQuickEditOfAPhotoBecomesAPhotoProjectWithItsOnePhoto() throws {
        var p = Project(name: "Pic", kind: .video, sources: [SourceRef(path: "/p/a.JPG", info: info(0, w: 800, h: 400))])
        p.look.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        p.overlays = [TextOverlay(text: "Hi", start: .zero, end: t(100_000))]
        let back = try ProjectCodec.decode(oldFile(p))
        #expect(back.kind == .photo && back.sources.count == 1 && back.timeline.isEmpty)
        #expect(back.look.crop == p.look.crop && back.overlays == p.overlays, "a photo keeps its edit where it was")
        #expect(ProjectRules.violations(back).isEmpty)
    }

    @Test func anOldTimelineProjectIsAVideoProjectAsItWas() throws {
        var p = Project(name: "T", kind: .video)
        let a = p.addSource(SourceRef(path: "/v/a.mp4", info: info(10)))
        p.timeline = [TimelineClip(sourceID: a, sourceStart: .zero, sourceEnd: t(5))]
        let back = try ProjectCodec.decode(oldFile(p, mode: "project"))
        #expect(back.kind == .video && back.timeline == p.timeline && back.look.isNeutral)
    }

    @Test func aQuickEditWhoseLengthIsUnknownIsFinishedWhenTheVideoIsRead() throws {
        var p = Project(name: "NoInfo", kind: .video, sources: [SourceRef(path: "/v/a.mp4")])
        p.look.rotation = 180
        var back = try ProjectCodec.decode(oldFile(p))
        #expect(back.pendingQuickUpgrade == true && back.timeline.isEmpty && back.look.rotation == 180, "nothing is guessed")
        ProjectUpgrade.finishQuickVideo(&back, duration: t(12))
        #expect(back.pendingQuickUpgrade == nil && back.timeline.count == 1 && back.timeline[0].look.rotation == 180 && back.look.isNeutral)
    }

    @Test func aSchemaOneQuickFileGoesThroughEveryStep() throws {
        var p = Project(name: "Old", kind: .video, sources: [SourceRef(path: "/v/a.mov", info: info(3))])
        p.look.rotation = 270
        var obj = try #require(try JSONSerialization.jsonObject(with: oldFile(p, schema: 1)) as? [String: Any])
        obj.removeValue(forKey: "overlayClips")
        let back = try ProjectCodec.decode(JSONSerialization.data(withJSONObject: obj))
        #expect(back.kind == .video && back.timeline.count == 1 && back.timeline[0].look.rotation == 270 && back.overlayClips.isEmpty)
    }

    @Test func aNewProjectRoundTripsWithItsKind() throws {
        for kind in ProjectKind.allCases {
            let p = Project(name: "N", kind: kind)
            let back = try ProjectCodec.decode(ProjectCodec.encode(p))
            #expect(back == p && back.kind == kind)
        }
    }
}

@Suite struct ProjectRulesTests {
    @Test func aVideoProjectTakesVideosOnly() {
        let p = Project(name: "V", kind: .video)
        #expect(ProjectRules.canAdd(paths: ["/a.mp4", "/b.MOV"], to: p) == .ok)
        #expect(ProjectRules.canAdd(paths: ["/a.mp4", "/b.jpg"], to: p) == .wrongKind(project: .video))
        #expect(ProjectRules.canAdd(paths: ["/notes.txt"], to: p) == .notMedia)
        #expect(ProjectRules.canAdd(paths: [], to: p) == .notMedia)
    }

    @Test func aPhotoProjectTakesExactlyOnePhoto() {
        var p = Project(name: "P", kind: .photo)
        #expect(ProjectRules.canAdd(paths: ["/a.heic"], to: p) == .ok)
        #expect(ProjectRules.canAdd(paths: ["/a.jpg", "/b.jpg"], to: p) == .onePhotoOnly)
        #expect(ProjectRules.canAdd(paths: ["/a.mp4"], to: p) == .wrongKind(project: .photo))
        p.sources = [SourceRef(path: "/a.jpg")]
        #expect(ProjectRules.canAdd(paths: ["/b.png"], to: p) == .photoAlreadyChosen)
    }

    @Test func aPhotoProjectThatBreaksTheRulesIsNoticed() {
        var p = Project(name: "P", kind: .photo, sources: [SourceRef(path: "/a.jpg"), SourceRef(path: "/b.mp4")])
        p.timeline = [TimelineClip(sourceID: p.sources[1].id, sourceStart: .zero, sourceEnd: t(1))]
        let v = ProjectRules.violations(p)
        #expect(v.contains(.photoProjectHasSeveralSources(2)) && v.contains(.photoProjectHasTimeline) && v.contains(.photoSourceIsNotAPicture("/b.mp4")))
        #expect(ProjectRules.violations(Project(name: "ok", kind: .photo)).isEmpty)
    }
}

@Suite struct ProjectFileWritingTests {
    private func setup() -> (FakeFileSystem, ProjectStore) {
        let fs = FakeFileSystem()
        fs.directories.insert("/Proj")
        return (fs, ProjectStore(fs: fs, recoveryFolder: "/Rec", now: { fs.clock }))
    }

    @Test func aNewProjectNeverLandsOnAnExistingFile() throws {
        let (fs, store) = setup()
        fs.put("/Proj/a.macplayer", "someone else's")
        #expect(throws: ProjectSaveError.exists("/Proj/a.macplayer")) { try store.create(Project(name: "a", kind: .video), at: "/Proj/a.macplayer") }
        #expect(fs.text("/Proj/a.macplayer") == "someone else's")
        #expect(throws: ProjectSaveError.folderMissing("/Nope")) { try store.create(Project(name: "a", kind: .video), at: "/Nope/a.macplayer") }
    }

    @Test func onlyProjectFilesAreEverWritten() throws {
        let (fs, store) = setup()
        fs.put("/Proj/clip.mp4", "VIDEO")
        #expect(throws: ProjectSaveError.notAProjectFile("/Proj/clip.mp4")) { try store.saveFile(Project(name: "x", kind: .video), to: "/Proj/clip.mp4", expected: nil, force: true) }
        #expect(throws: ProjectSaveError.notAProjectFile("/Proj/x.jpg")) { try store.create(Project(name: "x", kind: .photo), at: "/Proj/x.jpg") }
        #expect(fs.text("/Proj/clip.mp4") == "VIDEO")
    }

    @Test func aFileChangedBySomeoneElseIsNotOverwritten() throws {
        let (fs, store) = setup()
        var p = Project(name: "a", kind: .video)
        let fp = try store.create(p, at: "/Proj/a.macplayer")
        p.markers = [Marker(time: t(1))]
        let fp2 = try store.saveFile(p, to: "/Proj/a.macplayer", expected: fp)
        fs.touchExternally("/Proj/a.macplayer", "changed elsewhere")
        p.markers.append(Marker(time: t(2)))
        #expect(throws: ProjectSaveError.changedOnDisk("/Proj/a.macplayer")) { try store.saveFile(p, to: "/Proj/a.macplayer", expected: fp2) }
        #expect(fs.text("/Proj/a.macplayer") == "changed elsewhere")
        _ = try store.saveFile(p, to: "/Proj/a.macplayer", expected: fp2, force: true)
        #expect(try store.load(path: "/Proj/a.macplayer").markers.count == 2, "only when the person chooses to keep their edits")
    }

    @Test func aFailedWriteLeavesTheLastGoodFile() throws {
        let (fs, store) = setup()
        var p = Project(name: "a", kind: .video)
        let fp = try store.create(p, at: "/Proj/a.macplayer")
        p.markers = [Marker(time: t(1))]
        fs.hook = { op, _ in if op == "write" { throw InjectedFailure(op: op) } }
        #expect(throws: InjectedFailure.self) { try store.saveFile(p, to: "/Proj/a.macplayer", expected: fp) }
        fs.hook = nil
        #expect(try store.load(path: "/Proj/a.macplayer").markers.isEmpty)
        #expect(fs.leftovers.isEmpty)
    }

    @Test func theFileOfAnOlderFormatIsKeptOnceBeforeItIsUpgraded() throws {
        let (fs, store) = setup()
        let id = UUID()
        fs.put("/Proj/old.macvideo", "{old}")
        store.keepPreUpgradeCopy(of: "/Proj/old.macvideo", projectID: id, fileSchema: 2)
        fs.touchExternally("/Proj/old.macvideo", "{newer}")
        store.keepPreUpgradeCopy(of: "/Proj/old.macvideo", projectID: id, fileSchema: 2)
        let copies = store.preUpgradeCopies(projectID: id)
        #expect(copies.count == 1 && fs.text(copies[0]) == "{old}" && copies[0].hasSuffix(".macvideo"))
        store.keepPreUpgradeCopy(of: "/Proj/old.macvideo", projectID: UUID(), fileSchema: Project.currentSchema)
        #expect(fs.files.keys.filter { $0.contains("pre-upgrade") }.count == 1, "a current file needs no copy")
    }

    @Test func aRenamedProjectKeepsItsCrashCopyAndATrashedOneLosesIt() throws {
        let (fs, store) = setup()
        let p = Project(name: "a", kind: .video)
        fs.clock += 10
        try store.autosave(p, savedPath: "/Proj/a.macplayer")
        store.updateSavedPath(projectID: p.id, to: "/Proj/b.macplayer")
        #expect(store.recoverable().first?.savedPath == "/Proj/b.macplayer")
        try store.takeSnapshot(p)
        store.removeRecovery(projectID: p.id)
        #expect(store.recoverable().isEmpty && store.snapshots(projectID: p.id).isEmpty, "nothing can bring a trashed project back")
    }
}

@Suite struct ProjectRegistryTests {
    private func project(_ fs: FakeFileSystem, _ path: String, kind: ProjectKind = .video, clips: Int = 0) throws {
        var p = Project(name: "x", kind: kind)
        let s = p.addSource(SourceRef(path: "/v/a.mp4", info: info(10)))
        for _ in 0..<clips { p.timeline.append(TimelineClip(sourceID: s, sourceStart: .zero, sourceEnd: t(2))) }
        fs.directories.insert(PathUtil.directory(of: path))
        try fs.writeAtomically(ProjectCodec.encode(p), to: path)
    }

    @Test func registeringReadsWhatTheCardShowsAndNeverWritesTheProject() throws {
        let fs = FakeFileSystem()
        try project(fs, "/Proj/Trip.macplayer", clips: 3)
        let before = try fs.fingerprint("/Proj/Trip.macplayer")
        let r = ProjectRegistry(fs: fs, path: "/Data/registry.json")
        let e = try #require(r.register(path: "/Proj/Trip.macplayer", opened: true))
        #expect(e.name == "Trip" && e.kind == .video && e.clipCount == 3 && abs(e.seconds - 6) < 0.01 && e.status == .ok && e.lastOpened != nil)
        #expect(e.missingSources == 1, "/v/a.mp4 is not there")
        #expect(try fs.fingerprint("/Proj/Trip.macplayer") == before)
        #expect(r.register(path: "/Proj/clip.mp4") == nil, "only project files are listed")
        try r.save()
        #expect(ProjectRegistry(fs: fs, path: "/Data/registry.json").entries.count == 1, "the list is kept")
    }

    @Test func movedFilesAreFollowedOfflineDrivesAreNotMissingAndNothingIsDropped() throws {
        let fs = FakeFileSystem()
        try project(fs, "/Proj/a.macplayer"); try project(fs, "/Proj/b.macplayer"); try project(fs, "/Volumes/X/c.macplayer"); try project(fs, "/Proj/d.macplayer")
        var bookmarks: [String: String] = [:]
        let env = ProjectRegistry.Environment(resolveBookmark: { $0.flatMap { bookmarks[String(decoding: $0, as: UTF8.self)] } },
                                              makeBookmark: { Data($0.utf8) },
                                              driveConnected: { !$0.hasPrefix("/Volumes/X") },
                                              isInTrash: { $0.contains("/.Trash/") })
        let r = ProjectRegistry(fs: fs, path: "/Data/registry.json", environment: env)
        for p in ["/Proj/a.macplayer", "/Proj/b.macplayer", "/Volumes/X/c.macplayer", "/Proj/d.macplayer"] { r.register(path: p) }
        // a: renamed in Finder; b: gone; c: on a disk that is unplugged; d: moved to the Trash.
        fs.directories.insert("/Other"); fs.directories.insert("/Users/me/.Trash")
        try fs.move(from: "/Proj/a.macplayer", to: "/Other/a2.macplayer"); bookmarks["/Proj/a.macplayer"] = "/Other/a2.macplayer"
        try fs.remove("/Proj/b.macplayer")
        try fs.remove("/Volumes/X/c.macplayer")
        try fs.move(from: "/Proj/d.macplayer", to: "/Users/me/.Trash/d.macplayer"); bookmarks["/Proj/d.macplayer"] = "/Users/me/.Trash/d.macplayer"
        r.refresh()
        let byName = Dictionary(uniqueKeysWithValues: r.entries.map { (PathUtil.fileName(of: $0.path), $0) })
        #expect(byName["a2.macplayer"]?.status == .ok && byName["a2.macplayer"]?.name == "a2")
        #expect(byName["b.macplayer"]?.status == .missing)
        #expect(byName["c.macplayer"]?.status == .driveOffline)
        #expect(byName["d.macplayer"]?.status == .inTrash)
        #expect(r.entries.count == 4, "entries are never dropped by a refresh")
        #expect(r.visible().count == 3 && r.inTrashCount == 1, "a project in the Trash is not shown")
    }

    @Test func filterSortSearchAndCopiesWithTheSameID() throws {
        let fs = FakeFileSystem()
        try project(fs, "/Proj/Đà Lạt.macplayer", kind: .photo)
        try project(fs, "/Proj/Trip.macplayer")
        let r = ProjectRegistry(fs: fs, path: "/Data/registry.json")
        r.register(path: "/Proj/Đà Lạt.macplayer"); r.register(path: "/Proj/Trip.macplayer")
        #expect(r.visible(filter: .photo).map(\.name) == ["Đà Lạt"])
        #expect(r.visible(query: "da lat").map(\.name) == ["Đà Lạt"], "search ignores accents and case")
        #expect(r.visible(sort: .name).map(\.name) == ["Đà Lạt", "Trip"])
        let id = try #require(r.entry(forPath: "/Proj/Trip.macplayer")?.projectID)
        try fs.copy(from: "/Proj/Trip.macplayer", to: "/Proj/Trip copy.macplayer")
        #expect(r.idIsTaken(id, byOtherThan: "/Proj/Trip copy.macplayer"), "a Finder copy shares the id and must get its own")
        #expect(!r.idIsTaken(id, byOtherThan: "/Proj/Trip.macplayer"))
    }

    @Test func aRenameMovesTheEntry() throws {
        let fs = FakeFileSystem()
        try project(fs, "/Proj/a.macplayer")
        let r = ProjectRegistry(fs: fs, path: "/Data/registry.json")
        r.register(path: "/Proj/a.macplayer")
        try fs.move(from: "/Proj/a.macplayer", to: "/Proj/b.macplayer")
        r.moved(from: "/Proj/a.macplayer", to: "/Proj/b.macplayer")
        #expect(r.entries.count == 1 && r.entries[0].path == "/Proj/b.macplayer" && r.entries[0].name == "b")
    }
}

@Suite struct LegacyReplaceTests {
    @Test func anOldReplaceJobInTheQueueNeverRunsAndTheRestOfTheQueueSurvives() throws {
        let fs = FakeFileSystem()
        let keep = ExportJob(label: "keep", pieces: [JobPiece(sourcePath: "/v/a.mp4", span: TimeSpan(start: .zero, end: t(1)))], options: ExportOptions(), target: .newCopy(path: "/o/keep.mp4", overwrite: false))
        var q = ExportQueueModel(); q.enqueue(keep)
        // The queue file of MacPlayer 0.7 with a "replace the original" job in it, as it wrote it.
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as? [String: Any])
        var jobs = try #require(obj["jobs"] as? [[String: Any]])
        var old = jobs[0]
        old["id"] = UUID().uuidString; old["label"] = "replace"
        old["target"] = ["replaceOriginal": ["path": "/v/a.mp4", "expected": ["size": 5, "modified": 0, "fileID": 7], "backupFolder": "/v/MacPlayer Backups"]]
        old["state"] = ["running": [String: Any]()]
        jobs.append(old); obj["jobs"] = jobs
        fs.directories.insert("/Data")
        try fs.writeAtomically(JSONSerialization.data(withJSONObject: obj), to: "/Data/queue.json")
        let loaded = QueueStore(fs: fs, path: "/Data/queue.json").load()
        #expect(loaded.jobs.count == 2, "the queue is not thrown away")
        let legacy = try #require(loaded.jobs.first { $0.label == "replace" })
        #expect(legacy.state == .failed(message: SaveTarget.legacyReplaceMessage) && legacy.target == .legacyReplaceOriginal(path: "/v/a.mp4"))
        var again = loaded; again.retry(legacy.id)
        #expect(again.jobs.first { $0.id == legacy.id }?.state.isFinished == true, "it cannot be retried either")
        #expect(loaded.jobs.first { $0.label == "keep" }?.target == .newCopy(path: "/o/keep.mp4", overwrite: false))
        // Written again and read again: still the same.
        let round = try JSONDecoder().decode(ExportQueueModel.self, from: JSONEncoder().encode(loaded))
        #expect(round.jobs.map(\.target) == loaded.jobs.map(\.target))
    }

    @Test func aNewCopyTargetKeepsItsOldShapeOnDisk() throws {
        let data = try JSONEncoder().encode(SaveTarget.newCopy(path: "/o/a.mp4", overwrite: true))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inner = try #require(obj["newCopy"] as? [String: Any])
        #expect(inner["path"] as? String == "/o/a.mp4" && inner["overwrite"] as? Bool == true, "an older MacPlayer can still read the queue")
    }
}

/// The strip under the picture follows a project that grows (0.8.1: a new project started empty, and after videos were added the
/// strip still showed almost nothing, scrolled on every frame while playing and looked frozen and flickering).
@Suite struct TimelineViewportTests {
    @Test func anEmptyProjectThatGetsVideosShowsAllOfThem() {
        var v = TimelineViewport()
        v.fitAll(total: 0)
        #expect(v.start == 0 && v.length == TimelineViewport.minimumLength)
        v.totalChanged(to: 109.6)
        #expect(v.start == 0 && abs(v.length - 109.6) < 1e-9, "three videos added: the whole 1:50 shows")
        // Playing does not scroll a view that shows everything.
        for t in stride(from: 0.0, to: 109.0, by: 1.0 / 30) { v.follow(playhead: t) }
        #expect(v.start == 0)
    }

    @Test func aViewShowingEverythingKeepsShowingEverythingAsClipsComeAndGo() {
        var v = TimelineViewport()
        v.fitAll(total: 14.3)
        v.totalChanged(to: 65.5)
        #expect(abs(v.length - 65.5) < 1e-9)
        v.totalChanged(to: 20)
        #expect(abs(v.length - 20) < 1e-9 && v.start == 0)
    }

    @Test func aZoomedViewStaysWhereItWasInsideTheNewLength() {
        var v = TimelineViewport()
        v.fitAll(total: 100)
        v.zoom(by: 0.1, anchor: 50, fraction: 0.5)
        #expect(abs(v.length - 10) < 1e-9 && abs(v.start - 45) < 1e-9)
        v.totalChanged(to: 200)
        #expect(abs(v.length - 10) < 1e-9 && abs(v.start - 45) < 1e-9, "adding a video keeps the zoomed part in view")
        v.totalChanged(to: 30)
        #expect(abs(v.length - 10) < 1e-9 && abs(v.start - 20) < 1e-9, "a shorter timeline pulls the view back inside it")
        v.follow(playhead: 29.9)
        #expect(v.start <= 20 + 1e-9 && v.start + v.length >= 29.9)
    }

    @Test func zoomAndScrollStayInsideTheTimeline() {
        var v = TimelineViewport()
        v.fitAll(total: 8)
        v.zoom(by: 100, anchor: 4, fraction: 0.5)
        #expect(v.length == 8 && v.start == 0, "never wider than the timeline")
        v.zoom(by: 0.0001, anchor: 4, fraction: 0.5)
        #expect(v.length == TimelineViewport.minimumLength)
        v.scroll(by: -100); #expect(v.start == 0)
        v.scroll(by: 100); #expect(abs(v.start - (8 - TimelineViewport.minimumLength)) < 1e-9)
    }
}
