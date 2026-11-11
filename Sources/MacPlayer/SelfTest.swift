import AppKit
import AVFoundation
import Foundation
import MacPlayerCore
import MacPlayerMedia
import ImageIO
import UniformTypeIdentifiers

/// `MacPlayer --sandbox <dir> --selftest <media-dir>`: runs the main flows inside the real app process, with the real
/// session, export queue and playlist model, then prints one PASS/FAIL line per check and exits.
/// Uses only the synthetic videos in <media-dir>; never touches the user's own files or settings.
@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func waitForQueue(_ env: AppEnvironment, timeout: Double = 90) async {
        let end = Date().addingTimeInterval(timeout)
        while env.exports.queue.hasWork && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// A project made from `url` in the test's data folder and opened in the editor, as after "Edit" (the file itself is only read).
    static func editor(_ url: URL, kind: ProjectKind? = nil) async -> EditorSession? {
        let dir = AppEnvironment.shared.support.appendingPathComponent("SelfTestProjects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).macplayer").path
        return try? await EditorSession.makeProjectFile(kind: kind ?? (ImageFiles.isCandidate(url.path) ? .photo : .video), media: url, at: path)
    }

    static func frames(_ path: String) async -> [Int] { ((try? await FrameScanner.scanVideo(url: URL(fileURLWithPath: path))) ?? []).compactMap(\.index) }

    static func run(mediaDir: URL, app: AppDelegate) async {
        setvbuf(stdout, nil, _IONBF, 0) // keep the output even if something crashes
        let env = AppEnvironment.shared!
        let fm = FileManager.default
        let work = mediaDir.appendingPathComponent("work-\(UUID().uuidString.prefix(6))")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let demo = work.appendingPathComponent("demo.mp4")
        try? fm.copyItem(at: mediaDir.appendingPathComponent("demo.mp4"), to: demo)
        let original = (try? Data(contentsOf: demo)) ?? Data()

        if ProcessInfo.processInfo.environment["MACPLAYER_ONLY_SWITCH"] != nil { await toolSwitchFlow(env: env, work: work, app: app); finish(); return }
        if ProcessInfo.processInfo.environment["MACPLAYER_ONLY_DRAG"] != nil { await dragSmoothnessFlow(env: env, work: work, app: app); finish(); return }
        if ProcessInfo.processInfo.environment["MACPLAYER_ONLY_CANVAS"] != nil { await canvasFlow(env: env, work: work, app: app); await selectionFlow(env: env, work: work, app: app); await centringAndTypingFlow(env: env, work: work, app: app); finish(); return }
        if ProcessInfo.processInfo.environment["MACPLAYER_ONLY_WORKSPACE"] != nil { await workspaceFlow(env: env, work: work, app: app); await photoWorkspaceFlow(env: env, work: work, app: app); await canvasFlow(env: env, work: work, app: app); finish(); return }
        if ProcessInfo.processInfo.environment["MACPLAYER_ONLY_THREE"] != nil {
            for _ in 0..<(Int(ProcessInfo.processInfo.environment["MACPLAYER_ONLY_THREE"] ?? "") ?? 1) { await threeVideosFlow(env: env, work: work, app: app) }
            finish(); return
        }
        if ProcessInfo.processInfo.environment["MACPLAYER_TREE_SPEED_ONLY"] != nil {
            await treeSpeedFlow(app: app)
            await treeClickFlow(app: app)
            await treeClickFlow(app: app, layout: .grid)
            fflush(stdout)
            _exit(failures == 0 ? 0 : 1)      // this development shortcut leaves hidden test windows behind; leaving at once avoids waiting for them
        }
        if CommandLine.arguments.contains("--real-only"), let i = CommandLine.arguments.firstIndex(of: "--library"), i + 1 < CommandLine.arguments.count {
            await libraryFlow(env: env, work: work, library: URL(fileURLWithPath: CommandLine.arguments[i + 1]), app: app)
            if failures == 0 { print("ALL CHECKS PASSED"); exit(0) } else { finish() }
        }
        if CommandLine.arguments.contains("--real-only"), let i = CommandLine.arguments.firstIndex(of: "--real-photos"), i + 1 < CommandLine.arguments.count {
            await realPhotosFlow(env: env, work: work, real: URL(fileURLWithPath: CommandLine.arguments[i + 1]), app: app)
            if failures == 0 { print("ALL CHECKS PASSED"); exit(0) } else { finish() }
        }
        if CommandLine.arguments.contains("--real-only"), let i = CommandLine.arguments.firstIndex(of: "--real-media"), i + 1 < CommandLine.arguments.count {
            await realFlow(env: env, work: work, real: URL(fileURLWithPath: CommandLine.arguments[i + 1]), app: app)
            if failures == 0 { print("ALL CHECKS PASSED"); exit(0) } else { finish() }
        }

        // First, while no other window is open to draw the same playlists as well.
        await treeSpeedFlow(app: app)
        // The mouse-click flows (treeClickFlow) are run on their own with MACPLAYER_TREE_SPEED_ONLY=1: clicks sent into a window by a test are not
        // reliable enough to be part of every run.

        // A. open to watch -> play/seek -> make a project -> export a part as a new file
        print("== A: watch, seek, make a project, export a part")
        guard let s = try? await EditorSession.open(url: demo) else { check(false, "open demo.mp4"); finish(); return }
        check(s.role == .viewer && s.info?.primaryVideo?.codec == "avc1" && s.duration.seconds > 19, "opened to watch: H.264, \(Int(s.duration.seconds)) s")
        s.player.play()
        try? await Task.sleep(nanoseconds: 800_000_000) // start-up latency is not what is being measured
        let t0 = s.player.currentTime.seconds
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let rate = (s.player.currentTime.seconds - t0) / 2.5
        check(rate > 0.9 && rate < 1.1, "playback runs at normal speed (\(String(format: "%.2f", rate)) s of video per second, after start-up)")
        s.player.pause()
        await s.player.seek(to: MediaTime.frameStart(index: 75, frameRate: s.frameRate))
        check(abs(s.player.currentTime.seconds - 2.5) < 0.04, "exact seek to frame 75")
        s.player.step(frames: 1); try? await Task.sleep(nanoseconds: 700_000_000)
        check(abs(s.player.currentTime.seconds - (2.5 + 1.0 / 30)) < 0.04, "step one frame forward (now \(s.player.currentTime.seconds))")
        s.edit("nothing", refreshPreview: false) { $0.look.rotation = 90 }
        check(s.project.look.rotation == 0 && !s.isDirty, "watching never edits")
        s.close()
        let projPath = work.appendingPathComponent("demo.macplayer").path
        guard let p = try? await EditorSession.makeProjectFile(kind: .video, media: demo, at: projPath) else { check(false, "make a video project from demo.mp4"); finish(); return }
        check(p.isProject && p.project.timeline.count == 1 && fm.fileExists(atPath: projPath), "a video project with the video in it, saved where chosen")
        if let id = p.project.timeline.first?.id {
            p.edit("Trim", refreshPreview: false) { TimelineEditor.trim(&$0.timeline, clipID: id, start: MediaTime.frameStart(index: 75, frameRate: p.frameRate), end: MediaTime.frameStart(index: 150, frameRate: p.frameRate), sourceDuration: p.info?.duration ?? .zero) }
        }
        var req = ExportRequest(options: ExportOptions(mode: .exact), folder: work.path, baseName: "part")
        if let (jobs, _) = try? p.planExport(req) {
            env.exports.enqueue(jobs); await waitForQueue(env)
            let f = await frames(jobs[0].outputPath)
            check(f.first == 75 && f.last == 149 && f.count == 75, "exported a NEW file with frames 75...149 (\(f.first ?? -1)...\(f.last ?? -1))")
        } else { check(false, "plan export") }
        check((try? Data(contentsOf: demo)) == original, "source untouched, byte for byte")

        // C. several clips joined
        print("== C: several clips on the timeline, joined in one new file")
        if let first = p.project.timeline.first {
            let second = TimelineClip(sourceID: first.sourceID, sourceStart: MediaTime(seconds: 10), sourceEnd: MediaTime(seconds: 11), name: "Q&A")
            p.edit("more clips", refreshPreview: false) { $0.timeline.append(second) }
        }
        req.baseName = "joined"
        if let (jobs, _) = try? p.planExport(req) {
            env.exports.enqueue(jobs); await waitForQueue(env)
            let n = await frames(jobs[0].outputPath).count
            check(n == 105, "joined file has 75 + 30 frames (\(n))")
        } else { check(false, "plan joined export") }

        // E. autosave into the project file, reopen, crash copy, old quick projects
        print("== E: autosave into the project file, reopen, recovery, old projects")
        p.edit("look", refreshPreview: false) { $0.activeLook.rotation = 90; $0.activeLook.color.brightness = 0.2 }
        try? await Task.sleep(nanoseconds: 4_500_000_000) // autosave writes 2 s after the last edit
        if case .saved = p.saveState { check(!p.isDirty, "autosave wrote the edits into the project file") } else { check(false, "autosave wrote the edits (state \(p.saveState))") }
        check(!env.projectStore.recoverable().contains { $0.projectID == p.project.id }, "a project whose file is up to date is not offered for recovery")
        let projectID = p.project.id
        p.close()
        if let re = try? await EditorSession.openProject(path: projPath) {
            check(re.project.timeline.count == 2 && re.project.timeline[0].look.rotation == 90 && re.project.timeline[0].look.color.brightness == 0.2, "reopened with its clips and look")
            re.edit("after reopen", refreshPreview: false) { $0.markers.append(Marker(time: MediaTime(seconds: 3), name: "crash")) }
            // A crash before the file is written: only the crash copy has the edit.
            try? env.projectStore.autosave(re.project, savedPath: projPath)
            let rec = env.projectStore.recoverable()
            check(rec.contains { $0.projectID == projectID }, "a crash copy newer than the file is offered for recovery")
            check(re.saveNow(), "saving now writes the file")
            check(!env.projectStore.recoverable().contains { $0.projectID == projectID }, "after saving, nothing is left to recover")
            check((try? env.projectStore.load(path: projPath))?.markers.first?.name == "crash", "the file holds the edit")
            check((try? Data(contentsOf: demo)) == original, "saving did not touch the video")
            re.close()
        } else { check(false, "reopen project") }
        // A project made by MacPlayer 0.7 in "quick" mode opens as a video project with one clip; a copy of the old file is kept.
        let oldPath = work.appendingPathComponent("old quick.macvideo").path
        var old = Project(name: "old", kind: .video, sources: [SourceRef(path: demo.path, info: s.info)])
        old.look.rotation = 180
        if var obj = (try? JSONSerialization.jsonObject(with: ProjectCodec.encode(old))) as? [String: Any] {
            obj["schemaVersion"] = 2; obj["mode"] = "quick"; obj["kind"] = nil
            try? JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: oldPath))
        }
        let oldBytes = (try? Data(contentsOf: URL(fileURLWithPath: oldPath))) ?? Data()
        if let up = try? await EditorSession.openProject(path: oldPath) {
            check(up.isProject && up.project.timeline.count == 1 && up.project.timeline[0].look.rotation == 180 && up.project.look.isNeutral, "an old quick project opens as a video project with its edit on the clip")
            check(up.saveNow(), "the upgraded project is written")
            let copies = env.projectStore.preUpgradeCopies(projectID: up.project.id)
            check(copies.count == 1 && (try? Data(contentsOf: URL(fileURLWithPath: copies[0]))) == oldBytes, "a copy of the old file was kept before it was upgraded")
            check(ProjectCodec.schema(of: (try? Data(contentsOf: URL(fileURLWithPath: oldPath))) ?? Data()) == Project.currentSchema, "the file now has the new format")
            up.close()
        } else { check(false, "open an old quick project") }

        // F'. MacPlayer never writes over an original.
        print("== F: originals are never changed")
        check((try? Data(contentsOf: demo)) == original, "demo.mp4 is byte for byte what it was after projects, exports and autosave")
        check(((try? fm.contentsOfDirectory(atPath: work.path)) ?? []).allSatisfy { !$0.contains(".macplayer-") }, "no temp files left")

        // Cancel
        print("== Cancel: stops quickly, leaves nothing")
        let cancelDir = work.appendingPathComponent("cancel"); try? fm.createDirectory(at: cancelDir, withIntermediateDirectories: true)
        if let c = try? await EditorSession.makeProjectFile(kind: .video, media: demo, at: cancelDir.appendingPathComponent("c.macplayer").path) {
            let r = ExportRequest(options: ExportOptions(mode: .exact), folder: cancelDir.path, baseName: "cancelme")
            if let (jobs, _) = try? c.planExport(r) {
                let t0 = Date()
                env.exports.enqueue(jobs); try? await Task.sleep(nanoseconds: 250_000_000)
                env.exports.cancel(jobs[0].id); await waitForQueue(env, timeout: 10)
                let st = env.exports.queue.jobs.first(where: { $0.id == jobs[0].id })?.state
                check(st == .cancelled, "job is cancelled (\(String(describing: st)))")
                check(Date().timeIntervalSince(t0) < 5, "cancel took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                check(((try? fm.contentsOfDirectory(atPath: cancelDir.path)) ?? []).filter { !$0.hasSuffix(".macplayer") }.isEmpty, "no partial file remains")
            }
            c.close()
        }

        // G. multi-source timeline
        await threeVideosFlow(env: env, work: work, app: app)
        await toolSwitchFlow(env: env, work: work, app: app)
        await workspaceFlow(env: env, work: work, app: app)
        await photoWorkspaceFlow(env: env, work: work, app: app)
        await canvasFlow(env: env, work: work, app: app)
        await selectionFlow(env: env, work: work, app: app)
        await centringAndTypingFlow(env: env, work: work, app: app)
        await dragSmoothnessFlow(env: env, work: work, app: app)
        await timelineFlow(env: env, work: work, demo: demo, demoBytes: original)

        // H. layers over the timeline
        await layersFlow(env: env, work: work, demo: demo, demoBytes: original)
        await soundsFlow(env: env, work: work, demo: demo, demoBytes: original)
        await photosFlow(env: env, work: work, app: app)
        await photosMoreFlow(env: env, work: work)

        // J. shortcuts, menus, window level, parallel exports, audio track choice
        await interfaceFlow(env: env, work: work, demo: demo, app: app)

        // K. real videos, when a folder of them is named with --real-media
        if let i = CommandLine.arguments.firstIndex(of: "--real-media"), i + 1 < CommandLine.arguments.count {
            await realFlow(env: env, work: work, real: URL(fileURLWithPath: CommandLine.arguments[i + 1]), app: app)
        }

        // B. playlist
        print("== B: playlist from a folder, continuous play, order, skip")
        let pl = work.appendingPathComponent("lists"); try? fm.createDirectory(at: pl, withIntermediateDirectories: true)
        for n in ["clip 10", "clip 2", "clip 1"] {
            var spec = SyntheticMedia.Spec(); spec.width = 320; spec.height = 180; spec.seconds = 2; spec.withAudio = false
            try? await SyntheticMedia.generate(to: pl.appendingPathComponent("\(n).mp4"), spec: spec)
        }
        try? Data("not a video".utf8).write(to: pl.appendingPathComponent("notes.txt"))
        let host = SelfTestHost(); let model = app.playlists
        model.host = host
        let pid = model.create(name: "Self test")
        model.add(urls: [pl], to: pid)
        let names = model.selected?.items.map(\.title) ?? []
        check(names == ["clip 1", "clip 2", "clip 10"], "folder drop: natural order \(names)")
        let dup = model.add(urls: [pl.appendingPathComponent("clip 1.mp4")], to: pid)
        check(dup?.duplicates.count == 1 && model.selected?.count == 3, "a duplicate is skipped")
        model.setMode(pid, rep: .off)
        model.play(model.selected!.items[0].id, in: pid)
        var seen: [String] = []
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let t = host.current?.sourceURL?.deletingPathExtension().lastPathComponent, seen.last != t { seen.append(t) }
            if let s = host.current, s.player.duration.seconds > 0, s.player.currentTime.seconds < s.player.duration.seconds - 0.8, s.player.isPlaying { await s.player.seek(to: s.player.duration - MediaTime(seconds: 0.4)) }
            if seen.count == 3, host.messages.contains(L("End of the playlist.")) { break }
        }
        check(seen == ["clip 1", "clip 2", "clip 10"], "played in order and moved on by itself: \(seen)")
        check(host.messages.contains(L("End of the playlist.")), "stops at the end of the list")
        // A video that leaves the playlist must stop playing: removing it from the list, or deleting the whole list.
        host.current?.close(); host.current = nil
        let pid2 = model.create(name: "Stop test")
        model.add(urls: [pl.appendingPathComponent("clip 1.mp4"), pl.appendingPathComponent("clip 2.mp4")], to: pid2)
        let ids2 = model.selected?.items.map(\.id) ?? []
        model.play(ids2[0], in: pid2)
        await waitFor(10) { host.current?.player.isPlaying == true }
        check(host.current?.player.isPlaying == true && model.playingID == ids2[0], "a video from the playlist is playing")
        model.remove([ids2[1]], from: pid2)
        check(host.current?.player.isPlaying == true && model.playingID == ids2[0], "removing a video that is NOT playing leaves the playing one alone")
        model.remove([ids2[0]], from: pid2)
        check(host.current == nil && model.playingID == nil && model.playingPlaylistID == nil, "removing the playing video from the list stops and closes it")
        model.add(urls: [pl.appendingPathComponent("clip 1.mp4")], to: pid2)
        let again = model.selected?.items.first?.id
        model.play(again!, in: pid2)
        await waitFor(10) { host.current?.player.isPlaying == true }
        check(host.current?.player.isPlaying == true, "playing again from the same playlist")
        model.delete(pid2)
        check(host.current == nil && model.playingID == nil, "deleting the playlist stops and closes the playing video")
        check(fm.fileExists(atPath: pl.appendingPathComponent("clip 1.mp4").path), "the video file itself is still there")

        // The same in a real window: the picture goes back to the start screen; a video with unsaved edits is kept open but stopped.
        let wc = MainWindowController(playlists: model); app.adopt(wc); model.host = wc
        let pid3 = model.create(name: "Window test")
        model.add(urls: [pl.appendingPathComponent("clip 1.mp4"), pl.appendingPathComponent("clip 2.mp4")], to: pid3)
        let ids3 = model.selected?.items.map(\.id) ?? []
        model.play(ids3[0], in: pid3)
        await waitFor(10) { wc.session?.player.isPlaying == true }
        check(wc.session?.player.isPlaying == true, "real window: the playlist video plays")
        model.host = host      // another window was clicked meanwhile: the stop must still reach the window that plays
        model.remove([ids3[0]], from: pid3)
        check(wc.session == nil && model.playingID == nil, "real window: removing the playing video closes it (start screen again)")
        model.host = wc
        model.play(ids3[1], in: pid3)
        await waitFor(10) { wc.session?.player.isPlaying == true }
        check(wc.session?.role == .viewer && wc.session?.isDirty == false, "real window: watching has nothing to save")
        model.host = host
        model.delete(pid3)
        check(wc.session == nil, "real window: deleting the playlist closes the video that was playing")
        wc.window?.orderOut(nil)
        model.host = host

        // Two playlists, folders and "follow": a folder goes where it was chosen for, nothing leaks from one list into the other,
        // and a video taken out of a followed folder stays out.
        let pa = model.create(name: "List A"), pb = model.create(name: "List B")
        model.selectedID = pa
        check(env.prefs.lastPlaylistID == pa, "the playlist on show is remembered for the next run")
        func list(_ id: UUID) -> Playlist { model.playlists.first { $0.id == id }! }
        model.beginAddFolder(pl)                                   // chosen while A is on show
        await waitFor(10) { model.folderPreview?.scanning == false }
        model.selectedID = pb                                      // the person looks at B before confirming
        model.folderPreview?.follow = true
        model.confirmFolderPreview()
        check(list(pa).count == 3 && list(pb).count == 0 && list(pa).folderSources.count == 1 && list(pb).folderSources.isEmpty,
              "a folder goes into the playlist it was chosen for, not the one on show later (A \(list(pa).count), B \(list(pb).count))")
        let removedItem = list(pa).items[0]
        model.remove([removedItem.id], from: pa)
        model.refreshFolders(pa); try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(list(pa).count == 2 && !list(pa).items.contains { $0.path == removedItem.path }, "a video taken out of a followed folder does not come back at the next refresh")
        if let sid = list(pa).folderSources.first?.id {
            model.removeFolder(sid, from: pa, removeVideos: true)
            check(list(pa).items.isEmpty && list(pa).folderSources.isEmpty && list(pa).excludedPaths.isEmpty, "removing a folder takes its videos and its memory out of the list")
        } else { check(false, "the folder is a source of A") }
        check(list(pb).count == 0 && list(pb).folderSources.isEmpty, "the other playlist was never touched")
        check(fm.fileExists(atPath: pl.appendingPathComponent("clip 1.mp4").path), "and the video files are all still there")
        model.delete(pa); model.delete(pb)

        // "Refresh" takes out the videos whose files are gone from the disk, and only those.
        let rdir = work.appendingPathComponent("refresh-list"); try? fm.createDirectory(at: rdir, withIntermediateDirectories: true)
        for n in ["r1", "r2", "r3", "r4"] { try? fm.copyItem(at: pl.appendingPathComponent("clip 1.mp4"), to: rdir.appendingPathComponent("\(n).mp4")) }
        let prid = model.create(name: "Refresh test")
        model.add(urls: ["r1", "r2", "r3", "r4"].map { rdir.appendingPathComponent("\($0).mp4") }, to: prid)
        let unplugged = URL(fileURLWithPath: "/Volumes/NoSuchDrive-\(UUID().uuidString.prefix(6))/clip.mp4")
        model.add(urls: [unplugged], to: prid)
        func rlist() -> Playlist { model.playlists.first { $0.id == prid }! }
        check(rlist().count == 5, "a list with four real videos and one on a drive that is not connected")
        model.pruneDeleted(prid); try? await Task.sleep(nanoseconds: 800_000_000)
        check(rlist().count == 5, "nothing is removed while every file is there (the unplugged drive's video is not judged)")
        try? fm.removeItem(at: rdir.appendingPathComponent("r2.mp4"))
        model.pruneDeleted(prid); try? await Task.sleep(nanoseconds: 800_000_000)
        check(rlist().count == 4 && !rlist().items.contains { $0.title == "r2" }, "a deleted file is taken out of the list (\(rlist().count) left)")
        check(rlist().items.contains { $0.path == unplugged.path }, "the video on the drive that is not connected stays")
        try? fm.moveItem(at: rdir.appendingPathComponent("r3.mp4"), to: rdir.appendingPathComponent("r3 renamed.mp4"))
        model.pruneDeleted(prid); try? await Task.sleep(nanoseconds: 800_000_000)
        check(rlist().items.contains { $0.title == "r3" && $0.path.hasSuffix("r3 renamed.mp4") } && rlist().count == 4, "a renamed file is found again, not removed")
        try? fm.removeItem(at: rdir)
        model.pruneDeleted(prid); try? await Task.sleep(nanoseconds: 800_000_000)
        check(rlist().count == 1 && rlist().items[0].path == unplugged.path, "when the whole folder is deleted its videos go, the unplugged drive's still stays (\(rlist().count) left)")
        check(model.status?.contains("1") == true, "the person is told what happened")
        model.delete(prid)

        // Order: kept when videos are added, handing the list over to the person when they drag, and still there after the app is closed.
        let odir = work.appendingPathComponent("order-list"); try? fm.createDirectory(at: odir, withIntermediateDirectories: true)
        func ofile(_ n: String) -> URL { odir.appendingPathComponent("\(n).mp4") }
        for n in ["b 2", "a 10", "a 2", "a 5", "a 7"] { try? fm.copyItem(at: pl.appendingPathComponent("clip 1.mp4"), to: ofile(n)) }
        let por = model.create(name: "Order test")
        model.add(urls: [ofile("b 2"), ofile("a 10"), ofile("a 2")], to: por)
        func oitems() -> [String] { model.playlists.first { $0.id == por }!.items.map(\.title) }
        model.setOrder(por, PlaylistOrder(key: .naturalName))
        check(oitems() == ["a 2", "a 10", "b 2"], "sorted by name, numbers in order: \(oitems())")
        model.setOrder(por, PlaylistOrder(key: .naturalName, descending: true))
        check(oitems() == ["b 2", "a 10", "a 2"], "and the other way round: \(oitems())")
        model.add(urls: [ofile("a 5")], to: por)
        check(oitems() == ["b 2", "a 10", "a 5", "a 2"], "a video added later finds its place in the order: \(oitems())")
        try? await Task.sleep(nanoseconds: 900_000_000)        // the list is saved a moment after a change
        let reloaded = env.playlistStore.loadAll().playlists.first { $0.id == por }
        check(reloaded?.order == PlaylistOrder(key: .naturalName, descending: true) && reloaded?.items.map(\.title) == oitems(), "the order and the list are saved, so they are the same when the app is opened again")
        model.move(IndexSet(integer: 0), to: 4, in: por)
        check(model.playlists.first { $0.id == por }?.order == .manual && oitems() == ["a 10", "a 5", "a 2", "b 2"], "dragging a video makes the order manual, and it stays where it was put: \(oitems())")
        model.add(urls: [ofile("a 7")], to: por)
        check(oitems().last == "a 7", "in a manual order a new video goes to the end: \(oitems())")
        // By the date a file was created (given known dates), and by size; items carry the facts they were added with.
        let years = ["a 7": 2019, "a 10": 2020, "a 2": 2021, "a 5": 2022, "b 2": 2023]
        for (n, y) in years { try? fm.setAttributes([.creationDate: DateComponents(calendar: .current, year: y, month: 6, day: 1).date!], ofItemAtPath: ofile(n).path) }
        let pcr = model.create(name: "Created test")
        model.add(urls: ["b 2", "a 5", "a 10", "a 7", "a 2"].map(ofile), to: pcr)
        func citems() -> [String] { model.playlists.first { $0.id == pcr }!.items.map(\.title) }
        let facts = model.playlists.first { $0.id == pcr }!.items
        check(facts.count == 5 && facts.allSatisfy { ($0.fileSize ?? 0) > 0 && $0.created != nil }, "a video added to a playlist carries its size and creation date")
        model.applyOrder(pcr, PlaylistOrder(key: .created))
        await waitFor(5) { citems() == ["a 7", "a 10", "a 2", "a 5", "b 2"] }
        check(citems() == ["a 7", "a 10", "a 2", "a 5", "b 2"], "sorted by date created, oldest first: \(citems())")
        model.applyOrder(pcr, PlaylistOrder(key: .created, descending: true))
        await waitFor(5) { citems().first == "b 2" }
        check(citems() == ["b 2", "a 5", "a 2", "a 10", "a 7"], "and newest first: \(citems())")
        model.applyOrder(pcr, PlaylistOrder(key: .size, descending: true))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(model.playlists.first { $0.id == pcr }?.order == PlaylistOrder(key: .size, descending: true), "sorted by file size, largest first")
        model.delete(pcr)
        model.delete(por)

        // What shows when the pointer rests on a video in a playlist.
        let infoItem = PlaylistItem(path: pl.appendingPathComponent("clip 1.mp4").path)
        let store = ItemInfoStore.shared
        let quickTip = store.tip(for: infoItem)
        check(quickTip.contains("clip 1.mp4") && quickTip.contains(L("File size")) && quickTip.contains(L("Modified")) && !quickTip.contains("320×180"), "before the video has been read, the tip already has the name, size and dates")
        store.ensure(infoItem)
        await waitFor(10) { store.tip(for: infoItem).contains("320×180") }
        let tip = store.tip(for: infoItem)
        check(tip.contains("clip 1.mp4") && tip.contains(pl.path), "the tip names the file and its folder")
        check(tip.contains("320×180") && tip.contains("H.264"), "and the picture: size and codec (\(tip.replacingOccurrences(of: "\n", with: " | ")))")
        check(tip.contains(L("File size")) && tip.contains(L("Created")) && tip.contains(L("Modified")) && tip.contains(L("Length")), "and the size, the dates and the length")
        let gone = PlaylistItem(path: pl.appendingPathComponent("not there.mp4").path)
        store.ensure(gone)
        await waitFor(10) { store.tip(for: gone).contains(L("This file is not at this place any more.")) }
        check(store.tip(for: gone).contains(L("This file is not at this place any more.")), "a file that has gone says so")

        // Renaming and trashing a video file from inside the app. The questions are skipped here; this is what happens after a yes.
        let fdir = work.appendingPathComponent("file-actions"); try? fm.createDirectory(at: fdir, withIntermediateDirectories: true)
        let fakeTrash = work.appendingPathComponent("fake-trash"); try? fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        func ffile(_ n: String) -> String { fdir.appendingPathComponent("\(n).mp4").path }
        for n in ["target", "keep", "casey", "gone"] { try? fm.copyItem(atPath: pl.appendingPathComponent("clip 1.mp4").path, toPath: ffile(n)) }
        let fp1 = model.create(name: "Files 1"), fp2 = model.create(name: "Files 2")
        for id in [fp1, fp2] { model.add(urls: ["target", "gone", "keep"].map { URL(fileURLWithPath: ffile($0)) }, to: id) }
        func fpaths(_ id: UUID) -> [String] { model.playlists.first { $0.id == id }!.items.map(\.path) }
        FileActions.trasher = { u in try FileManager.default.moveItem(at: u, to: fakeTrash.appendingPathComponent(u.lastPathComponent)) }
        defer { FileActions.trasher = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) } }

        let wcf = MainWindowController(playlists: model); app.adopt(wcf)
        if let sKeep = try? await EditorSession.open(url: URL(fileURLWithPath: ffile("keep"))) {
            wcf.setSession(sKeep, fromPlaylist: false)
            check(app.reasonBusy(ffile("keep")) == nil, "a video that is only open to watch is free to rename")
            wcf.closeVideo(confirm: { _ in true })
        }
        if let sT = try? await EditorSession.open(url: URL(fileURLWithPath: ffile("target"))) {
            wcf.setSession(sT, fromPlaylist: false); await sT.player.seek(to: MediaTime(seconds: 1)); sT.player.pause()
        }
        let renamed = try? app.performRename(ffile("target"), toTyped: "renamed")
        check(renamed == ffile("renamed") && fm.fileExists(atPath: ffile("renamed")) && !fm.fileExists(atPath: ffile("target")), "the file is renamed on the disk, keeping its extension")
        check([fp1, fp2].allSatisfy { fpaths($0).contains(ffile("renamed")) && !fpaths($0).contains(ffile("target")) && model.playlists.first { $0.id == fp1 }!.items.contains { $0.title == "renamed" } }, "every playlist that had it now has it under the new name")
        await waitFor(10) { wcf.session?.sourceURL?.lastPathComponent == "renamed.mp4" }
        check(wcf.session?.sourceURL?.lastPathComponent == "renamed.mp4" && abs((wcf.session?.player.currentTime.seconds ?? 0) - 1) < 0.5, "the window that showed it reopens it under the new name, at the same moment")
        do { try app.performRename(ffile("keep"), toTyped: "renamed"); check(false, "a taken name is refused") }
        catch { check((error as? RenameError) == .exists && fm.fileExists(atPath: ffile("keep")) && fm.fileExists(atPath: ffile("renamed")), "a name that is taken is refused and nothing is overwritten") }
        _ = try? app.performRename(ffile("casey"), toTyped: "Casey")
        check(((try? fm.contentsOfDirectory(atPath: fdir.path)) ?? []).contains("Casey.mp4"), "a change of capital letters only works too")

        try? app.performTrash(ffile("gone"))
        check(!fm.fileExists(atPath: ffile("gone")) && fm.fileExists(atPath: fakeTrash.appendingPathComponent("gone.mp4").path), "a trashed file leaves its folder and lands in the Trash")
        check([fp1, fp2].allSatisfy { !fpaths($0).contains(ffile("gone")) && fpaths($0).contains(ffile("keep")) }, "it is taken out of every playlist, the others stay")
        if wcf.session != nil { try? app.performTrash(ffile("renamed")); check(wcf.session == nil, "a window that showed the trashed video goes back to the start screen") }
        wcf.window?.orderOut(nil)
        FileActions.trasher = { u in struct Refused: Error {}; throw Refused() }
        let before = fpaths(fp1)
        do { try app.performTrash(ffile("keep")); check(false, "a refused move is an error") }
        catch { check(fm.fileExists(atPath: ffile("keep")) && fpaths(fp1) == before, "if the Trash refuses, nothing changes: the file and the playlists stay") }
        model.delete(fp1); model.delete(fp2)
        await batchFlow(work: work, source: pl.appendingPathComponent("clip 1.mp4"), app: app)
        await newPlaylistNameFlow(app: app)

        // Closing the video that is open, without opening another one.
        let cw = MainWindowController(playlists: model); app.adopt(cw)
        check(cw.closeVideo() == false, "Close Video with nothing open does nothing")
        if let item = app.allMenuItems.first(where: { $0.action == #selector(AppDelegate.closeVideo(_:)) }) {
            check(item.title == L("Close Video") && item.keyEquivalent == "w" && item.keyEquivalentModifierMask.contains([.command, .shift]) && item.target != nil, "File ▸ Close Video exists with ⇧⌘W")
            check(app.allMenuItems.filter { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == [.command] }.count == 1, "⌘W still only closes the window")
        } else { check(false, "File ▸ Close Video exists") }
        if let s1 = try? await EditorSession.open(url: pl.appendingPathComponent("clip 1.mp4")) {
            cw.setSession(s1, fromPlaylist: false)
            check(cw.contentController.header != nil && cw.route == .playlist, "an open video shows the bar with the Close button, on the Playlists side")
            check(cw.closeVideo() == true && cw.session == nil && s1.player.isPlaying == false, "Close Video closes the video and stops it")
            check(cw.contentController.header == nil && cw.route == .playlist, "the playlists screen is shown again, without the bar")
        } else { check(false, "open a video to close") }
        let closeProj = pl.appendingPathComponent("close test.macplayer").path
        try? fm.removeItem(atPath: closeProj)
        if let s2 = try? await EditorSession.makeProjectFile(kind: .video, media: pl.appendingPathComponent("clip 2.mp4"), at: closeProj) {
            cw.setSession(s2, fromPlaylist: false)
            s2.addMarker()
            check(s2.isDirty, "made an edit before closing")
            check(cw.closeVideo(confirm: { _ in false }) == false && cw.session === s2, "a project that cannot be saved stays open when the person chooses to")
            check(cw.closeVideo() == true && cw.session == nil && cw.route == .projects, "closing a project writes it and goes back to the list of projects")
            check((try? env.projectStore.load(path: closeProj))?.markers.count == 1, "the edit is in the project file")
            try? fm.removeItem(atPath: closeProj)
        } else { check(false, "make a project to close") }
        let pid4 = model.create(name: "Close test")
        model.add(urls: [pl.appendingPathComponent("clip 1.mp4"), pl.appendingPathComponent("clip 2.mp4")], to: pid4)
        let ids4 = model.selected?.items.map(\.id) ?? []
        model.host = cw
        model.play(ids4[1], in: pid4)
        await waitFor(10) { cw.session?.player.isPlaying == true }
        check(cw.session?.player.isPlaying == true && model.playingID == ids4[1], "a playlist video is playing in that window")
        check(cw.closeVideo() == true && cw.session == nil, "Close Video closes a playlist video")
        check(model.playingID == nil && model.playingPlaylistID == nil, "and the playlist stops playing")
        check(model.playlists.first { $0.id == pid4 }?.currentItemID == ids4[1] && model.playlists.first { $0.id == pid4 }?.resumePosition != nil, "the playlist remembers where it stopped")
        model.host = host; cw.window?.orderOut(nil)
        model.delete(pid4)

        // The window's layout, which is what full screen is made of: the window can be as wide as a big screen, the picture always has a real
        // height and fills the middle, and it follows the side panels when they are opened or closed. (The system's own full-screen
        // animation needs an active app: `--fullscreen-check` covers that.)
        let fw = MainWindowController(playlists: model); app.adopt(fw)
        if let fs1 = try? await EditorSession.open(url: pl.appendingPathComponent("clip 1.mp4")) {
            fw.setSession(fs1, fromPlaylist: false)
            let cc = fw.contentController
            func settle() async { try? await Task.sleep(nanoseconds: 700_000_000); fw.window?.contentView?.layoutSubtreeIfNeeded(); cc.view.layoutSubtreeIfNeeded() }
            func picture() -> CGRect { cc.host?.frame ?? .zero }
            fw.window?.setContentSize(NSSize(width: 1280, height: 800)); await settle()
            check(picture().height > 400 && picture().width > 600, "normal window: the picture area has a real size (\(Int(picture().width))×\(Int(picture().height)))")
            // What the editing panel shows must never change the size of the window (it used to grow, and on a small screen lose its top).
            let sizeBefore = fw.window?.frame.size ?? .zero
            for t in InspectorTab.allCases { fs1.activeTool = t; await settle(); check(fw.window?.frame.size == sizeBefore, "opening the \(t.rawValue) tool leaves the window size alone (\(Int(fw.window?.frame.width ?? 0))×\(Int(fw.window?.frame.height ?? 0)))") }
            fw.window?.setContentSize(NSSize(width: 2000, height: 1100)); await settle()
            check((fw.window?.frame.width ?? 0) >= 1999, "the window can be as wide as a big screen; nothing caps its width (asked 2000, got \(Int(fw.window?.frame.width ?? 0)))")
            let p0 = picture()
            check(p0.height > 700 && p0.width > 1300 && abs(p0.width - cc.view.bounds.width) < 1, "wide window: the picture takes the middle (\(Int(p0.width))×\(Int(p0.height)) of \(Int(cc.view.bounds.width))×\(Int(cc.view.bounds.height)))")
            check(fw.panelsCollapsed.sidebar == false && fw.panelsCollapsed.inspector == true, "watching: the playlists show, the tools do not")
            fw.toggleSidebar(); await settle()
            check(picture().width > p0.width + 150 && picture().height > 700, "closing the playlist gives its room to the picture (\(Int(p0.width)) → \(Int(picture().width)))")
            fw.toggleSidebar(); await settle()
            check(abs(picture().width - p0.width) < 2 && (fw.window?.frame.width ?? 0) >= 1999, "opening it again brings the picture back, and the window keeps its width")
            fs1.close()
            // Editing: the tools show, the playlists do not.
            if let fe = await editor(pl.appendingPathComponent("clip 1.mp4")) {
                fw.setSession(fe, fromPlaylist: false); await settle()
                let e0 = picture()
                check(fw.panelsCollapsed.sidebar == true && fw.panelsCollapsed.inspector == false, "editing: the tools show, the playlists do not")
                fw.toggleInspector(); await settle()
                check(picture().width > e0.width + 250, "closing the tools gives the picture their room (\(Int(e0.width)) → \(Int(picture().width)))")
                fw.toggleInspector(); await settle()
                check(abs(picture().width - e0.width) < 2, "opening them again brings the picture back")
                fw.closeVideo()
            } else { check(false, "make a project for the layout checks") }
        } else { check(false, "open a video for the layout checks") }
        fw.window?.orderOut(nil)

        // The Recent list: search, the menu's "Clear" item, and clearing it all. The person's real list is put back afterwards.
        let docs = NSDocumentController.shared
        let savedRecents = docs.recentDocumentURLs
        docs.clearRecentDocuments(nil)
        for n in ["clip 10", "clip 2", "clip 1"] { docs.noteNewRecentDocumentURL(pl.appendingPathComponent("\(n).mp4")) }
        check(docs.recentDocumentURLs.count == 3, "three files in the Recent list (\(docs.recentDocumentURLs.count))")
        check(RecentFiles.search(docs.recentDocumentURLs, query: "clip 2").map(\.lastPathComponent) == ["clip 2.mp4"], "searching the Recent list finds the file")
        check(RecentFiles.search(docs.recentDocumentURLs, query: "").count == 3 && RecentFiles.search(docs.recentDocumentURLs, query: "zzz").isEmpty, "an empty search shows all, a search with no match shows none")
        if let sub = app.allMenuItems.first(where: { $0.title == L("Open Recent") })?.submenu {
            app.menuNeedsUpdate(sub)
            check(sub.items.last?.title == L("Clear Recent Files…") && sub.items.last?.action != nil && sub.items.last?.target != nil, "File ▸ Open Recent ends with a Clear item")
        } else { check(false, "found the Open Recent menu") }
        app.clearRecentList()
        check(docs.recentDocumentURLs.isEmpty, "Clear All empties the Recent list")
        check(fm.fileExists(atPath: pl.appendingPathComponent("clip 1.mp4").path), "clearing the Recent list keeps the video files")
        if let sub = app.allMenuItems.first(where: { $0.title == L("Open Recent") })?.submenu {
            app.menuNeedsUpdate(sub)
            check(sub.items.count == 1 && sub.items[0].title == L("No recent files"), "the empty Recent menu says so and has no Clear item")
        }
        for u in savedRecents.reversed() { docs.noteNewRecentDocumentURL(u) }

        model.delete(pid)
        check(fm.fileExists(atPath: pl.appendingPathComponent("clip 1.mp4").path), "deleting the playlist keeps the videos")

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        try? fm.removeItem(at: work)
        exit(failures == 0 ? 0 : 1)
    }

    static func waitFor(_ timeout: Double = 6, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// A new, empty video project, three different videos added at once (sizes, codecs, frame rates, with and without sound), shown
    /// in a window and played: the playhead must move and the preview must not keep being rebuilt (it flickered and stood still).
    static func threeVideosFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G0: a new video project of three different videos plays")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        var urls: [URL] = []
        // Like the maintainer's: portrait phone videos of slightly different heights, of very different lengths; and a mix of kinds.
        let portrait = ProcessInfo.processInfo.environment["MACPLAYER_THREE_PORTRAIT"] != nil
        let kinds: [(Int, Int, Int, SyntheticMedia.Codec, Bool, Double)] = portrait
            ? [(1080, 1918, 30, .h264, true, 14.3), (1080, 1920, 30, .h264, true, 51.2), (1080, 1918, 30, .h264, true, 44.1)]
            : [(1280, 720, 30, .h264, true, 4), (640, 360, 25, .hevc, true, 4), (720, 1280, 60, .h264, false, 4)]
        for (i, (w, h, fps, codec, audio, secs)) in kinds.enumerated() {
            var spec = SyntheticMedia.Spec(); spec.width = w; spec.height = h; spec.seconds = secs; spec.codec = codec; spec.withAudio = audio
            spec.frameRate = FrameRate(numerator: Int32(fps), denominator: 1)
            let u = work.appendingPathComponent("three-\(i).mp4"); try? fm.removeItem(at: u)
            try? await SyntheticMedia.generate(to: u, spec: spec)
            urls.append(u)
        }
        let path = work.appendingPathComponent("three.macplayer").path; try? fm.removeItem(atPath: path)
        guard let s = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "make an empty video project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false)
        wc.showWindow(nil)
        await s.addVideos(urls)
        let total = kinds.reduce(0) { $0 + $1.5 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let span = wc.contentController.timeline?.visibleSpan ?? (start: -1, length: -1)
        check(span.start == 0 && abs(span.length - s.duration.seconds) < 0.05, "the timeline strip shows the whole project once the videos are in (\(String(format: "%.1f", span.length)) of \(String(format: "%.1f", s.duration.seconds)) s); it used to keep the width of the empty project")
        check(s.project.timeline.count == 3 && abs(s.duration.seconds - total) < 0.2, "three clips, \(total) s (\(s.project.timeline.count) clips, \(String(format: "%.2f", s.duration.seconds)) s)")
        await waitFor(20) { s.player.duration.seconds > total - 1 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let loadsBefore = s.previewLoads
        s.player.play()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let t0 = s.player.currentTime.seconds
        let layoutsBefore = PlayerHostView.layouts
        var worst = 0.0
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            let a = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(nanoseconds: 10_000_000)
            worst = max(worst, ProcessInfo.processInfo.systemUptime - a - 0.010)
        }
        let t1 = s.player.currentTime.seconds
        let layouts = PlayerHostView.layouts - layoutsBefore
        let after = wc.contentController.timeline?.visibleSpan ?? (start: -1, length: -1)
        check(after.start == 0, "playing does not scroll a strip that shows everything (start \(String(format: "%.2f", after.start)) s)")
        print("   playhead \(String(format: "%.2f", t0)) → \(String(format: "%.2f", t1)), playing \(s.player.isPlaying), preview built \(s.previewLoads - loadsBefore) times, picture laid out \(layouts) times, main loop held up \(Int(worst * 1000)) ms at worst, state \(s.saveState)")
        check(layouts <= 2, "the picture is not laid out again and again while playing (\(layouts) times in 3 s)")
        check(worst < 0.25, "the interface keeps up while playing (held up \(Int(worst * 1000)) ms at worst)")
        check(t1 - t0 > 2.4, "the playhead moves while playing (\(String(format: "%.2f", t1 - t0)) s in 3 s)")
        check(s.previewLoads - loadsBefore == 0, "the preview is not built again while playing (\(s.previewLoads - loadsBefore) times)")
        s.player.pause()
        wc.closeVideo(); wc.window?.orderOut(nil)
    }

    /// Going back and forth between the colour filters and the transitions, clicking one of each, in a video project shown in a window:
    /// the interface must keep answering (it froze: every tile picture was drawn on the main thread, again at every visit of a tool).
    static func toolSwitchFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G1: switching between filters and transitions keeps the interface answering")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        var urls = (ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_MEDIA"] ?? "").split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        if urls.isEmpty, ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_PROJECT"] == nil {
            for i in 0..<3 {
                // Keyframes far apart, as in many phone and app exports: reading one exact frame means decoding many.
                var spec = SyntheticMedia.Spec(); spec.width = 640; spec.height = 1136; spec.seconds = 5; spec.keyframeInterval = 150
                let u = work.appendingPathComponent("switch-\(i).mp4"); try? fm.removeItem(at: u)
                try? await SyntheticMedia.generate(to: u, spec: spec); urls.append(u)
            }
        }
        let path = work.appendingPathComponent("switch.macplayer").path; try? fm.removeItem(atPath: path)
        let s: EditorSession
        if let existing = ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_PROJECT"] {
            // A copy of a real project (its media is only read).
            try? fm.copyItem(atPath: existing, toPath: path)
            guard let opened = try? await EditorSession.openProject(path: path) else { check(false, "open the project"); return }
            s = opened
        } else {
            guard let made = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "make a project"); return }
            s = made
        }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        if ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_PROJECT"] == nil { await s.addVideos(urls) }
        await waitFor(20) { s.player.duration.seconds > 1 }
        s.selectedClipIDs = [s.project.timeline[1].id]
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Watches the main loop while the person clicks around.
        final class Watch { var worst = 0.0; var busy = 0.0; var on = true; var refreshes = 0 }
        let watch = Watch()
        let watcher = Task { @MainActor in
            while watch.on {
                let a = ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(nanoseconds: 5_000_000)
                let late = ProcessInfo.processInfo.systemUptime - a - 0.005
                watch.worst = max(watch.worst, late); watch.busy += max(0, late)
            }
        }
        // Playing with the library's filters and the Effects settings open: how often the panels are asked to redraw, and how busy the
        // main thread is. Every frame used to redraw every panel (30 times a second).
        let refreshSub = s.objectWillChange.sink { _ in watch.refreshes += 1 }
        s.activeTool = .effects
        try? await Task.sleep(nanoseconds: 600_000_000)
        let idle0 = watch.busy
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let busyIdle = watch.busy - idle0
        let busy0 = watch.busy, ref0 = watch.refreshes
        let draws0 = wc.contentController.timeline?.draws ?? 0
        s.player.play()
        if let extra = ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_PLAYSECS"].flatMap(Double.init) { print("   PLAYING NOW"); try? await Task.sleep(nanoseconds: UInt64(extra * 1e9)) }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        s.player.pause()
        let busyPlaying = watch.busy - busy0, refreshesPlaying = watch.refreshes - ref0
        let stripDraws = (wc.contentController.timeline?.draws ?? 0) - draws0
        check(stripDraws <= 25, "while playing, the timeline moves its playhead without drawing the whole strip each frame (\(stripDraws) draws in 3 s)")
        refreshSub.cancel()
        // Paused in the middle of a clip, far from a keyframe: how soon does a new filter reach the picture?
        await s.player.seek(to: MediaTime(seconds: min(s.duration.seconds * 0.6, s.duration.seconds - 1)))
        try? await Task.sleep(nanoseconds: 800_000_000)
        var delays: [Double] = []
        for f in [FilterPreset.mono, .warm, .noir, .vivid, .cool, .film] {
            // The very first effect on a plain video switches the compositor on: that one rebuilds the preview, on purpose. Only the
            // choices made with the compositor on must reach the picture at once.
            let live = s.previewHasCompositor
            let before = CompositorStats.framesDrawn
            let t0 = ProcessInfo.processInfo.systemUptime
            s.editEffects("Filter") { $0.filter = f; $0.filterAmount = 1 }
            await waitFor(5) { CompositorStats.framesDrawn > before }
            if live { delays.append(CompositorStats.framesDrawn > before ? CompositorStats.lastRequestUptime - t0 : 5) }
            else { await waitFor(5) { s.previewHasCompositor } }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        print("   paused: a new filter reached the picture after " + delays.map { String(format: "%.0f ms", $0 * 1000) }.joined(separator: ", "))
        check(delays.count >= 5 && delays.allSatisfy { $0 < 0.3 }, "paused, a filter chosen is drawn on the picture at once (it was not drawn at all until the playhead moved)")
        // The same for a transition, with the playhead on the cut (where the transition shows).
        if s.project.timeline.count > 1, let cut = TimelineEditor.starts(s.project.timeline)[s.project.timeline[1].id] {
            s.select(.clip(s.project.timeline[1].id))
            if s.project.activeLook.transitionIn == nil { s.chooseTransition(.dissolve, label: "Transition"); await waitFor(5) { s.previewHasCompositor && s.player.duration.seconds > 1 }; try? await Task.sleep(nanoseconds: 600_000_000) }
            await s.player.seek(to: cut); try? await Task.sleep(nanoseconds: 600_000_000)
            var tdelays: [Double] = []
            for k in [TransitionKind.wipeLeft, .spin, .pixelate, .circleOpen] {
                let before = CompositorStats.framesDrawn, t0 = ProcessInfo.processInfo.systemUptime
                s.chooseTransition(k, label: "Transition")
                await waitFor(5) { CompositorStats.framesDrawn > before }
                tdelays.append(CompositorStats.framesDrawn > before ? CompositorStats.lastRequestUptime - t0 : 5)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            print("   paused on the cut: a new transition reached the picture after " + tdelays.map { String(format: "%.0f ms", $0 * 1000) }.joined(separator: ", "))
            check(tdelays.allSatisfy { $0 < 0.3 }, "paused, a transition chosen is drawn on the picture at once")
        }
        print("   playing 3 s with filters and effects open: panels asked to redraw \(refreshesPlaying) times, timeline drawn \(stripDraws) times, main thread late \(Int(busyPlaying * 1000)) ms (paused, the same 3 s: \(Int(busyIdle * 1000)) ms)")
        check(refreshesPlaying <= 20, "while playing, the panels are not redrawn at every frame (\(refreshesPlaying) times in 3 s)")
        // Playing with the Colour tool open: its histogram must not read the video again and again (it read a frame every quarter of
        // a second, exactly, from the first video, and fought the player for the decoder).
        s.activeTool = .color
        try? await Task.sleep(nanoseconds: 800_000_000)
        let readsBeforePlay = ToolFrameCache.shared.reads
        s.player.play()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let readsWhilePlaying = ToolFrameCache.shared.reads - readsBeforePlay
        check(readsWhilePlaying == 0, "playing with the Colour tool open reads no frames for it (\(readsWhilePlaying) read in 2 s)")
        if ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_PLAYING"] == nil { s.player.pause() }
        let readsBeforeSwitching = ToolFrameCache.shared.reads
        let filters: [FilterPreset] = [.vivid, .mono, .warm, .noir, .cinematic, .vintage]
        let kinds: [TransitionKind] = [.dissolve, .slideLeft, .zoomIn, .wipeRight, .spin, .pixelate]
        // With MACPLAYER_SWITCH_CLICKS the choices are clicked on the tiles, through the window, as a person does.
        let clicks = ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_CLICKS"] != nil
        if clicks { SidebarProbe.enabled = true; wc.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        defer { SidebarProbe.enabled = false }
        try? await Task.sleep(nanoseconds: 500_000_000)          // a rebuild still finishing from opening and playing is not counted
        let loadsBefore = s.previewLoads
        let t0 = Date()
        for round in 0..<6 {
            s.activeTool = .effects
            try? await Task.sleep(nanoseconds: 250_000_000)
            if clicks, let win = wc.window { await clickLabel(EffectsPane.name(filters[round]), in: win) }
            else { s.editEffects("Filter") { $0.filter = filters[round]; $0.filterAmount = 1 } }
            try? await Task.sleep(nanoseconds: 250_000_000)
            s.activeTool = .transitions
            try? await Task.sleep(nanoseconds: 250_000_000)
            if clicks, let win = wc.window { await clickLabel(TransitionsPane.name(kinds[round]), in: win) }
            else { s.chooseTransition(kinds[round], label: "Transition") }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if ProcessInfo.processInfo.environment["MACPLAYER_SWITCH_DEBUG"] != nil { print("   round \(round): rebuilds so far \(s.previewLoads - loadsBefore), compositor=\(s.previewHasCompositor)") }
            if clicks { print("   round \(round): key=\(wc.window?.isKeyWindow == true) active=\(NSApp.isActive) filter=\(s.project.timeline[1].look.effects.filter) transition=\(String(describing: s.project.timeline[1].look.transitionIn?.kind))") }
            s.activeTool = .color
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        s.player.pause()
        let spent = Date().timeIntervalSince(t0)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        watch.on = false; _ = await watcher.value
        let loads = s.previewLoads - loadsBefore
        let switchReads = ToolFrameCache.shared.reads - readsBeforeSwitching
        check(switchReads <= 4, "going back and forth between tools reuses the pictures already read (\(switchReads) frames read for 18 switches)")
        let builds = s.previewBuildTimes.suffix(loads).map { String(format: "%.2f", $0) }.joined(separator: " ")
        print("   preview rebuilds (s): \(builds); edits that asked for one: \(s.rebuildReasons.suffix(6))")
        print("   18 tool switches and 12 choices in \(String(format: "%.1f", spent)) s; main loop held up \(Int(watch.worst * 1000)) ms at worst; preview built \(loads) times")
        // Only switching the compositor on (the first filter, the first transition) builds the preview; choosing between them does not.
        check(loads <= 2, "choosing between filters and between transitions does not rebuild the preview (\(loads) rebuilds for 12 choices)")
        check(watch.worst < 0.25, "switching tools and choosing filters and transitions never holds the interface up long (worst \(Int(watch.worst * 1000)) ms)")
        check(s.project.timeline[1].look.transitionIn?.kind == .pixelate && s.project.timeline[1].look.effects.filter == .vintage, "the last choices are kept")
        wc.closeVideo(); wc.window?.orderOut(nil)
    }

    static func timelineFlow(env: AppEnvironment, work: URL, demo: URL, demoBytes: Data) async {
        print("== G: timeline of several videos")
        let fm = FileManager.default
        let second = work.appendingPathComponent("second.mp4")
        var spec = SyntheticMedia.Spec(); spec.width = 320; spec.height = 180; spec.seconds = 2; spec.withAudio = false
        try? await SyntheticMedia.generate(to: second, spec: spec)
        guard let s = await editor(demo) else { check(false, "open for timeline"); return }
        await waitFor { s.player.duration.seconds > 19 }
        try? await Task.sleep(nanoseconds: 800_000_000) // let the preview finish loading before seeking
        check(s.isProject && s.project.timeline.count == 1 && abs(s.duration.seconds - 20) < 0.1, "a video project with one clip of 20 s")
        await s.player.seek(to: MediaTime.frameStart(index: 150, frameRate: s.frameRate))
        check(abs(s.player.currentTime.seconds - 5) < 0.05, "playhead is at 5 s on the timeline (\(String(format: "%.2f", s.player.currentTime.seconds)))")
        s.splitAtPlayhead()
        await waitFor { s.project.timeline.count == 2 }
        let t = s.project.timeline
        check(t.count == 2 && t[0].sourceEnd == t[1].sourceStart && abs(t[0].sourceEnd.seconds - 5) < 0.05, "split at 5 s into two clips that meet exactly")
        await s.addVideos([second])
        check(s.project.timeline.count == 3 && s.project.sources.count == 2, "second video added as its own source (clips \(s.project.timeline.count), sources \(s.project.sources.count), notice: \(s.notice?.text ?? "none"))")
        // Several videos at once, with a clip selected: they land after it, in the order given (they once came out reversed).
        do {
            let extra = ["x1.mp4", "x2.mp4", "x3.mp4"].map { work.appendingPathComponent($0) }
            for u in extra { try? fm.copyItem(at: second, to: u) }
            let selected = s.project.timeline[0].id
            s.selectedClipIDs = [selected]
            await s.addVideos(extra)
            let names = s.project.timeline.map(\.name)
            check(names.count == 6 && Array(names[1...3]) == ["x1", "x2", "x3"] && s.project.timeline[0].id == selected, "several videos added at once keep their order and land after the selected clip (\(names))")
            s.undo(); s.undo(); s.undo()
            check(s.project.timeline.count == 3, "and each can be undone (\(s.project.timeline.count) clips left)")
        }
        guard s.project.timeline.count == 3 else { return }
        let b = s.project.timeline[2]
        s.moveClip(b.id, toIndex: 1)
        check(s.project.timeline.map(\.sourceID) == [t[0].sourceID, b.sourceID, t[0].sourceID], "reordered: A, B, A")
        check(abs(s.duration.seconds - 22) < 0.1, "timeline is \(String(format: "%.1f", s.duration.seconds)) s (5 + 2 + 15)")
        s.selectedClipIDs = [b.id]
        await waitFor(2) { s.project.activeClipID == b.id }
        s.edit("flip") { $0.activeLook.flipHorizontal = true }
        check(s.project.timeline[1].look.flipHorizontal && !s.project.timeline[0].look.flipHorizontal && !s.project.look.flipHorizontal, "the look applies to the selected clip only")
        s.undo()
        check(!s.project.timeline[1].look.flipHorizontal && s.project.timeline.count == 3, "undo takes back just that edit")
        s.redo()
        check(s.project.timeline[1].look.flipHorizontal, "redo brings it back")

        let outDir = work.appendingPathComponent("joined"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let fast = ExportRequest(options: ExportOptions(mode: .fast), folder: outDir.path, baseName: "joined")
        check((try? s.planExport(fast)) == nil, "fast cut is refused for a joined timeline")
        let req = ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "joined")
        if let (jobs, _) = try? s.planExport(req) {
            env.exports.enqueue(jobs); await waitForQueue(env, timeout: 120)
            let out = jobs[0].outputPath
            // Clip B is mirrored, so its barcode cannot be read: it shows up as frames without a number.
            let all = (try? await FrameScanner.scanVideo(url: URL(fileURLWithPath: out))) ?? []
            let idx = all.compactMap(\.index)
            let unread = all.count - idx.count
            let missing = Set(0..<600).subtracting(idx).sorted()
            check(all.count == 660, "joined file has 660 frames (A 150 + B 60 + A 450): \(all.count)")
            check(unread == 60 && missing.isEmpty && idx == Array(0..<600), "A is exactly frames 0–599 in order and B (mirrored) fills the 60 in between (unreadable \(unread), missing \(missing.prefix(6)))")
            check((try? Data(contentsOf: demo)) == demoBytes, "the original videos are untouched")
        } else { check(false, "plan joined export") }

        check(s.saveNow(), "the project is saved into its file")
        let proj = s.projectPath ?? ""
        if let re = try? await EditorSession.openProject(path: proj) {
            check(re.project.sources.count == 2 && re.project.timeline == s.project.timeline, "reopened with both sources and the same clips")
            await waitFor { re.player.duration.seconds > 21 }
            check(abs(re.player.duration.seconds - 22) < 0.2, "preview is built for the whole timeline (\(String(format: "%.1f", re.player.duration.seconds)) s)")
            re.close()
        } else { check(false, "reopen multi-source project") }

        // Missing media: reported, blocks the export, relink repairs it.
        // "Missing" means gone: a plain move would be followed through the file's bookmark (a feature), so copy and delete.
        let hidden = work.appendingPathComponent("second-elsewhere.mp4")
        try? fm.copyItem(at: second, to: hidden)
        try? fm.removeItem(at: second)
        if let re = try? await EditorSession.openProject(path: proj) {
            check(re.missingSourceIDs.count == 1, "a missing video is detected on open")
            check((try? re.planExport(req)) == nil, "export is blocked while media is missing")
            if let id = re.missingSourceIDs.first { await re.relinkSource(id, to: hidden) }
            check(re.missingSourceIDs.isEmpty && (try? re.planExport(ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "after-relink"))) != nil, "relinking repairs it")
            re.close()
        }
        s.close()
    }

    static func soundsFlow(env: AppEnvironment, work: URL, demo: URL, demoBytes: Data) async {
        print("== I: music, voice-over files and noise reduction")
        let fm = FileManager.default
        // A 5 s sound with a steady hiss and a tone in the middle.
        let music = work.appendingPathComponent("music.wav")
        do {
            let rate = 44100.0, n = Int(5 * rate)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: music, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            var seed: UInt64 = 3
            for i in 0..<n {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let hiss = (Float((seed >> 33) % 2001) / 1000 - 1) * 0.03
                let t = Double(i) / rate
                buf.floatChannelData![0][i] = hiss + (t > 1.5 && t < 3.5 ? Float(0.3 * sin(2 * .pi * 330 * t)) : 0)
            }
            try file.write(from: buf)
        } catch { check(false, "make a test sound: \(error)"); return }
        guard let s = await editor(demo) else { check(false, "open for sounds"); return }
        check(s.canHaveSounds, "a video project can have sounds laid under it")
        await s.player.seek(to: MediaTime(seconds: 2))
        await s.addSounds(urls: [music], kind: .music)
        check(s.sounds.count == 1 && abs(s.sounds[0].start.seconds - 2) < 0.1 && abs(s.sounds[0].duration.seconds - 5) < 0.1, "music added at the playhead with the file's length")
        check(s.selectedSoundID == s.sounds.first?.id, "the new sound is selected")
        guard let id = s.sounds.first?.id else { return }
        s.updateSound(id, "gain") { $0.gainDB = -6; $0.ducking = true }
        s.undo()
        check(s.sounds.first?.ducking == false && s.sounds.first?.gainDB != -6, "undo takes back the last sound edit")
        s.redo()

        let outDir = work.appendingPathComponent("sounds"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let req = ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "with-music")
        if let (jobs, _) = try? s.planExport(req) {
            check(jobs[0].recipe.soundClips.count == 1, "the export job carries the music")
            env.exports.enqueue(jobs); await waitForQueue(env, timeout: 120)
            let out = jobs[0].outputPath
            check((try? await MediaProbe.probe(url: URL(fileURLWithPath: out)))?.hasAudio == true, "the exported video has sound")
            check((try? Data(contentsOf: demo)) == demoBytes, "the original is untouched")
        } else { check(false, "plan export with music") }
        if let fastPlan = try? s.planExport(ExportRequest(options: ExportOptions(mode: .fast), folder: outDir.path, baseName: "fast")) { _ = fastPlan; check(false, "a fast cut cannot carry music") }
        else { check(true, "a fast cut cannot carry music") }

        // Noise reduction of the video's own sound: the cleaned copy is made first, then the setting is applied.
        s.setDenoise(0.6, for: .main)
        await waitFor(60) { s.project.activeAudio.denoise != nil }
        check(s.project.activeAudio.denoise == 0.6, "noise reduction is switched on once the cleaned copy exists (on the selected clip)")
        if let u = s.sourceURL { check(NoiseReducer.cached(for: u, strength: 0.6) != nil, "the cleaned copy is kept") }
        s.setDenoise(nil, for: .main)
        check(s.project.audio.denoise == nil, "and can be switched off")

        // A sound whose file is gone blocks the export and is named.
        try? fm.removeItem(at: music)
        check(s.isMissing(s.sounds[0]), "a missing sound file is noticed")
        check((try? s.planExport(req)) == nil, "export is blocked while a sound file is missing")
        s.deleteSound(id)
        check(s.sounds.isEmpty && (try? s.planExport(req)) != nil, "removing that sound unblocks it")

        s.close()
    }

    static func photosFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== L: photos: open, edit, save, replace, playlist, slideshow")
        let fm = FileManager.default
        let dir = work.appendingPathComponent("photos"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, w: Int, h: Int, type: UTType = .jpeg, orientation: Int? = nil) -> URL {
            let url = dir.appendingPathComponent(name)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, (orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]) as CFDictionary)
            CGImageDestinationFinalize(dest)
            return url
        }
        let a = make("a.jpg", w: 800, h: 400), b = make("b.png", w: 600, h: 300, type: .png), c = make("c.jpg", w: 400, h: 800, orientation: 6)
        let before = (try? Data(contentsOf: a)) ?? Data()

        // Opening: it is a photo, the picture comes up, and only the tools that fit a photo are on offer.
        guard let s = await editor(a) else { check(false, "open a photo"); return }
        await waitFor(10) { s.photoImage != nil }
        check(s.isPhoto && s.info?.primaryVideo?.width == 800 && s.info?.primaryVideo?.height == 400, "a photo project opens with its photo's size")
        check(s.photoImage != nil && s.photoImage?.width == 800, "the picture is drawn (\(s.photoImage?.width ?? 0) px wide)")
        check(s.activeTool == .picture && InspectorTab.tabs(for: .photo) == [.picture, .color, .mask, .effects, .layers, .text, .export], "the Picture tool opens, and a photo has no timeline, sound or subtitle tools")
        check(s.photoDraft.options.format == .jpeg, "it is saved in its own format unless told otherwise")
        s.photoCropAdjusting = false          // the crop frame has its own checks (flow N): here the picture shows every edit as it will be saved

        // Editing: a crop changes the picture on screen at once; undo takes it back.
        s.edit("crop") { $0.look.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1) }
        await waitFor(5) { s.photoImage?.width == 400 }
        check(s.photoImage?.width == 400 && s.photoOutputSize?.width == 400, "a crop shows at once (\(s.photoImage?.width ?? 0) px) and the saved size follows")
        s.undo()
        await waitFor(5) { s.photoImage?.width == 800 }
        check(s.photoImage?.width == 800, "undo brings the whole picture back")
        s.edit("crop") { $0.look.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1) }
        s.editEffects("filter") { $0.filter = .mono }
        s.edit("text") { $0.overlays.append(TextOverlay(text: "Hi", start: .zero, end: MediaTime(seconds: 100_000), sizeFraction: 0.2)) }
        await waitFor(5) { s.photoImage?.width == 400 }

        // Saving as a new photo: next to nothing is overwritten and the original stays as it was.
        let out = dir.appendingPathComponent("out"); try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        s.photoDraft.folder = out.path; s.photoDraft.name = "edited"; s.photoDraft.options.format = .png
        s.savePhoto()
        await waitFor(15) { s.photoDraft.lastSaved != nil && !s.photoDraft.saving }
        let saved = out.appendingPathComponent("edited.png")
        check(fm.fileExists(atPath: saved.path) && (try? PhotoLoader.info(url: saved))?.primaryVideo?.width == 400, "the edited photo is saved as a new file with the cropped size")
        s.photoDraft.lastSaved = nil
        s.savePhoto()
        await waitFor(15) { s.photoDraft.lastSaved != nil && !s.photoDraft.saving }
        check(fm.fileExists(atPath: out.appendingPathComponent("edited 2.png").path), "saving again does not overwrite: a number is added")
        check((try? Data(contentsOf: a)) == before, "the original is untouched")
        check(((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).allSatisfy { !$0.contains(".macplayer-") }, "no temporary files are left")

        // A logo over the photo: drawn on the screen and in the saved file; the photo stays the only photo.
        let logo = make("logo.png", w: 100, h: 100, type: .png)
        s.addLogo(logo)
        check(s.project.overlayClips.count == 1 && s.project.sources.count == 1, "a logo is added over the photo, which stays the only photo")
        s.photoDraft.name = "with logo"; s.photoDraft.lastSaved = nil
        s.savePhoto()
        await waitFor(15) { s.photoDraft.lastSaved != nil && !s.photoDraft.saving }
        check(fm.fileExists(atPath: out.appendingPathComponent("with logo.png").path), "the photo with its logo is saved as a new file")
        // A second photo cannot join: a photo project holds one photo.
        check(ProjectRules.canAdd(paths: [b.path], to: s.project) == .photoAlreadyChosen && ProjectRules.canAdd(paths: [b.path, c.path], to: s.project) == .onePhotoOnly,
              "a photo project takes no second photo")
        EditorSession.confirmReplacePhoto = { _ in true }
        let square = make("square.png", w: 300, h: 300, type: .png)
        await s.replacePhoto(square)
        await waitFor(10) { s.info?.primaryVideo?.width == 300 }
        check(s.project.sources.count == 1 && s.project.sources[0].path == square.path && s.project.look.crop == .full && s.project.look.effects.filter == .mono, "changing the photo keeps the edit, starts the crop again (other shape)")
        s.undo()
        check(s.project.sources.first?.path == a.path, "and can be undone")
        check((try? Data(contentsOf: a)) == before, "the original is still untouched")
        s.close()

        // A photo turned by the camera opens upright; a file that is not a picture is refused.
        if let t = try? await EditorSession.open(url: c) { check(t.info?.primaryVideo?.width == 800 && t.info?.primaryVideo?.height == 400, "a photo the camera held on its side opens upright (\(t.info?.primaryVideo?.width ?? 0)×\(t.info?.primaryVideo?.height ?? 0))"); t.close() }
        let junk = dir.appendingPathComponent("junk.jpg"); try? Data("nope".utf8).write(to: junk)
        check((try? await EditorSession.open(url: junk)) == nil, "a file that is not a picture is refused")

        // A playlist of photos: kinds, information, and a slideshow that moves on by itself.
        let model = PlaylistModel()
        let pid = model.create(name: "Photos")
        let b2 = make("b2.png", w: 300, h: 300, type: .png)
        model.add(urls: [b, b2], to: pid)
        let items = model.playlists.first { $0.id == pid }?.items ?? []
        check(items.count == 2 && items.allSatisfy(\.isImage), "photos go into a playlist (\(items.count) added)")
        let tip = ItemInfoStore.shared
        tip.ensure(items[0])
        await waitFor(10) { tip.tip(for: items[0]).contains("600×300") }
        check(tip.tip(for: items[0]).contains("600×300") && !tip.tip(for: items[0]).contains(L("Sound")), "a photo's information has its size and no sound line")

        let cw = MainWindowController(playlists: model); app.adopt(cw)
        env.prefs.photoSlideSeconds = 1
        model.host = cw
        model.play(items[0].id, in: pid)
        await waitFor(10) { cw.session?.isPhoto == true && cw.session?.photoImage != nil }
        check(cw.session?.isPhoto == true && cw.contentController.photoHost != nil && cw.contentController.host == nil, "a photo in the window has its own viewer, not the player")
        let beforeFrame = cw.window?.frame.size
        check(model.slideshowOn == false, "the slideshow does not start by itself")
        model.toggleSlideshow()
        await waitFor(6) { cw.session?.sourceURL?.lastPathComponent == "b2.png" }
        check(cw.session?.sourceURL?.lastPathComponent == "b2.png", "the slideshow moves on to the next photo after the time set")
        cw.session?.edit("crop") { $0.look.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1) }
        check(cw.session?.project.look.crop == .full, "a photo being watched cannot be edited")
        check(cw.window?.frame.size == beforeFrame, "the window keeps its size through all this")
        env.prefs.photoSlideSeconds = 5
        model.stop(); cw.window?.orderOut(nil)
        model.delete(pid)

        // The move from the app's old name: data is copied over once, nothing is overwritten, the old data stays.
        let parent = work.appendingPathComponent("appsupport")
        let old = parent.appendingPathComponent("MacVideo"), new = parent.appendingPathComponent("MacPlayer")
        try? fm.createDirectory(at: old.appendingPathComponent("Playlists"), withIntermediateDirectories: true)
        try? Data("positions".utf8).write(to: old.appendingPathComponent("positions.json"))
        try? Data("a playlist".utf8).write(to: old.appendingPathComponent("Playlists/a.json"))
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        try? Data("already here".utf8).write(to: new.appendingPathComponent("positions.json"))
        let tag = UUID().uuidString.prefix(6)
        let oldID = "local.macvideo.selftest.\(tag)", newID = "local.macplayer.selftest.\(tag)"
        UserDefaults(suiteName: oldID)!.set(9.0, forKey: "skipSeconds")
        UserDefaults(suiteName: oldID)!.set("/Volumes/x", forKey: "lastExportFolder")
        UserDefaults(suiteName: oldID)!.set("100 100 1280 800 0 0 2560 1440", forKey: "NSWindow Frame MacVideoMainWindow")
        let fresh = UserDefaults(suiteName: newID)!
        fresh.set("/mine", forKey: "lastExportFolder")
        let r1 = LegacyMigration.run(newSupport: new, defaults: fresh, oldBundleID: oldID)
        check(r1.files == 1 && fm.fileExists(atPath: new.appendingPathComponent("Playlists/a.json").path), "the old playlists are copied to the new folder (\(r1.files) item)")
        check((try? String(contentsOf: new.appendingPathComponent("positions.json"), encoding: .utf8)) == "already here", "what the new folder already had is not overwritten")
        check(fm.fileExists(atPath: old.appendingPathComponent("positions.json").path) && fm.fileExists(atPath: old.appendingPathComponent("Playlists/a.json").path), "the old folder is left as it was")
        check(fresh.double(forKey: "skipSeconds") == 9 && fresh.string(forKey: "lastExportFolder") == "/mine", "the old settings come over, without replacing a setting already made (\(r1.settings) copied)")
        check(fresh.string(forKey: "NSWindow Frame MacPlayerMainWindow") == "100 100 1280 800 0 0 2560 1440", "the saved window size and place carry over under the new name")
        let r2 = LegacyMigration.run(newSupport: new, defaults: fresh, oldBundleID: oldID)
        check(r2.files == 0 && r2.settings == 0, "it is done only once")
        fresh.removePersistentDomain(forName: newID); UserDefaults.standard.removePersistentDomain(forName: oldID)
        check(ProjectFile.isProject(URL(fileURLWithPath: "/a/old.macvideo")) && ProjectFile.isProject(URL(fileURLWithPath: "/a/new.MACPLAYER")) && !ProjectFile.isProject(URL(fileURLWithPath: "/a/x.mp4")), "projects of both names are recognised")
    }

    static func photosMoreFlow(env: AppEnvironment, work: URL) async {
        print("== N: photos: crop frame, projects, recovery, animation")
        let fm = FileManager.default
        let dir = work.appendingPathComponent("photos2"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func cg(_ w: Int, _ h: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
            return ctx.makeImage()!
        }
        let a = dir.appendingPathComponent("a.png")
        let d = CGImageDestinationCreateWithURL(a as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg(800, 400), nil); CGImageDestinationFinalize(d)

        guard let s = await editor(a) else { check(false, "open a photo"); return }
        await waitFor(10) { s.photoImage != nil }
        // Since 0.11 the frame is shown only when asked for ("Adjust on the picture", or a shape), so text and logos can be dragged on the photo.
        check(!s.photoCropEditing && s.activeTool == .picture, "the Picture tool opens without the crop frame in the way")
        s.photoCropAdjusting = true
        // While it is on, the frame is shown on the whole picture; leaving the tool shows the cut.
        check(s.photoCropEditing && s.activeTool == .picture, "ticking “Adjust on the picture” shows the crop frame")
        s.setPhotoCropFrame(CropRect(x: 0.5, y: 0, width: 0.5, height: 1), coalesce: nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(s.photoImage?.width == 800, "with the frame showing, the picture is the whole one (\(s.photoImage?.width ?? 0) px)")
        s.activeTool = .effects
        await waitFor(5) { s.photoImage?.width == 400 }
        check(!s.photoCropEditing && s.photoImage?.width == 400, "leaving the tool shows the cut (\(s.photoImage?.width ?? 0) px)")
        s.activeTool = .picture
        await waitFor(5) { s.photoImage?.width == 800 }
        check(s.photoCropEditing && s.photoImage?.width == 800, "and coming back shows the whole picture with the frame")
        s.photoCropAdjusting = false
        await waitFor(5) { s.photoImage?.width == 400 }
        check(!s.photoCropEditing && s.photoImage?.width == 400, "the frame can be switched off to see the cut on the Picture tool too")
        s.photoCropAdjusting = true
        await waitFor(5) { s.photoImage?.width == 800 }

        // A shape for the frame: square in pixels, the largest that fits, around where the frame was.
        s.setPhotoCropShape(1)
        let f = s.photoCropFrame
        check(abs(f.width * 800 / (f.height * 400) - 1) < 1e-6 && abs(f.height - 1) < 1e-6, "a square frame: \(String(format: "%.2f", f.width)) wide, \(String(format: "%.2f", f.height)) high of the picture")
        check(s.photoCropRatio == 1, "the frame keeps that shape while it is dragged")
        s.setPhotoCropShape(nil)
        check(s.photoCropRatio == nil, "Free lets go of the shape")

        // The frame is drawn on the picture as it is shown: turned a quarter, the same frame cuts the same part.
        s.edit("reset") { $0.look.crop = .full; $0.look.rotation = 0 }
        s.edit("turn") { $0.look.rotation = 90 }
        await waitFor(5) { s.photoImage?.width == 400 }
        s.setPhotoCropFrame(CropRect(x: 0, y: 0, width: 1, height: 0.5), coalesce: nil)     // the top half of the turned picture: its red half
        check(s.photoOutputSize == CGSize(width: 400, height: 400), "the frame on the turned picture gives \(Int(s.photoOutputSize?.width ?? 0))×\(Int(s.photoOutputSize?.height ?? 0))")
        s.photoCropAdjusting = false
        await waitFor(5) { s.photoImage?.width == 400 && s.photoImage?.height == 400 }
        if let img = s.photoImage { let px = CIImage(cgImage: img); var c = [UInt8](repeating: 0, count: 4)
            CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(px, toBitmap: &c, rowBytes: 4, bounds: CGRect(x: 200, y: 200, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            check(c[0] > 240 && c[2] < 20, "and what is cut is the red half, as the frame showed (\(c))") }
        s.photoCropAdjusting = true

        // A project of a photo: saved, opened again, and recovered after a crash.
        s.edit("text") { $0.overlays.append(TextOverlay(text: "Hi", start: .zero, end: MediaTime(seconds: 100_000), sizeFraction: 0.2)) }
        check(s.saveNow(), "a photo project is saved into its file")
        let proj = s.projectPath ?? ""
        check(!s.isDirty, "and nothing is left unsaved")
        if let re = try? await EditorSession.openProject(path: proj) {
            await waitFor(10) { re.photoImage != nil }
            check(re.isPhoto && re.project.look == s.project.look && re.project.overlays == s.project.overlays && re.photoImage != nil && !re.isDirty, "and opens again with the same edit")
            re.close()
        } else { check(false, "the photo project opens again") }
        s.edit("more") { $0.look.effects.filter = .mono }
        var p = s.project; p.playhead = .zero
        try? env.projectStore.autosave(p, savedPath: proj)
        let found = env.projectStore.recoverable().first { $0.projectID == p.id }
        check(found != nil, "an autosave of a photo is offered for recovery")
        if let found, let rp = try? env.projectStore.loadAutosave(found) {
            s.close()
            let r = await EditorSession.restore(project: rp, savedPath: found.savedPath ?? proj)
            await waitFor(10) { r.photoImage != nil }
            check(r.isPhoto && r.isDirty && r.project.look.effects.filter == .mono && r.photoImage != nil, "the recovered photo has the last edit, to be written into its file")
            check(r.saveNow() && (try? env.projectStore.load(path: proj))?.look.effects.filter == .mono, "and it is written into the project file")
            r.close()
        }
        env.projectStore.clearAutosave(projectID: p.id)
        s.close()

        // An animation: its frames play, and the edit goes on every frame when it is saved as a GIF.
        let g = dir.appendingPathComponent("anim.gif")
        let gd = CGImageDestinationCreateWithURL(g as CFURL, UTType.gif.identifier as CFString, 6, nil)!
        CGImageDestinationSetProperties(gd, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<6 {
            let ctx = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0, green: CGFloat(i) / 5, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            CGImageDestinationAddImage(gd, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(gd)
        guard let an = await editor(g) else { check(false, "open an animated GIF"); return }
        await waitFor(10) { an.photoFrames.count == 6 }
        check(an.photoAnimation?.frameCount == 6 && an.photoFrames.count == 6 && an.photoPlaying, "an animated GIF opens with its 6 frames, playing")
        check(an.photoDraft.options.format == .gif, "and is saved as a GIF unless told otherwise")
        an.photoCropAdjusting = false
        an.edit("crop") { $0.look.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1) }
        await waitFor(10) { an.photoFrames.count == 6 && an.photoFrames.first?.width == 60 }
        check(an.photoFrames.count == 6 && an.photoFrames.first?.width == 60, "an edit is drawn on every frame (\(an.photoFrames.first?.width ?? 0) px wide)")
        an.photoDraft.folder = dir.path; an.photoDraft.name = "anim-edited"
        an.savePhoto()
        await waitFor(30) { an.photoDraft.lastSaved != nil && !an.photoDraft.saving }
        let outGif = dir.appendingPathComponent("anim-edited.gif")
        check(PhotoLoader.animation(url: outGif)?.frameCount == 6 && (try? PhotoLoader.info(url: outGif))?.primaryVideo?.width == 60, "the saved GIF is still an animation of 6 frames, cut")
        an.close()
    }

    static func layersFlow(env: AppEnvironment, work: URL, demo: URL, demoBytes: Data) async {
        print("== H: layers over the timeline")
        let fm = FileManager.default
        let cam = work.appendingPathComponent("cam.mp4")
        var spec = SyntheticMedia.Spec(); spec.width = 320; spec.height = 180; spec.seconds = 3; spec.codec = .hevc
        try? await SyntheticMedia.generate(to: cam, spec: spec)
        let logo = work.appendingPathComponent("logo.png")
        if let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            if let img = ctx.makeImage() { try? ImageWriter.write(img, to: logo, format: .png) }
        }
        guard let s = await editor(demo) else { check(false, "open for layers"); return }
        if let id = s.project.timeline.first?.id {
            s.edit("clip", refreshPreview: false) { TimelineEditor.trim(&$0.timeline, clipID: id, end: MediaTime(seconds: 6), sourceDuration: s.info?.duration ?? .zero) }
        }
        await waitFor { s.player.duration.seconds > 5 }
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(s.isProject && abs(s.duration.seconds - 6) < 0.1, "project of 6 s")

        await s.player.seek(to: MediaTime(seconds: 2))
        await s.addOverlayVideos([cam])
        check(s.project.overlayClips.count == 1 && s.project.overlayClips[0].lane == 0 && abs(s.project.overlayClips[0].start.seconds - 2) < 0.05, "video layer added at the playhead on the first free line")
        check(s.selectedOverlayID == s.project.overlayClips.first?.id && s.activeTool == .layers, "the new layer is selected and its tool opens")
        await s.player.seek(to: MediaTime(seconds: 1))
        await s.addOverlayPicture(logo)
        let pic = s.project.overlayClips.last
        check(s.project.overlayClips.count == 2 && pic?.lane == 1, "a picture added where the first line is busy goes to line 2 (L\(((pic?.lane) ?? -1) + 1))")
        guard let picID = pic?.id, let camID = s.project.overlayClips.first?.id else { return }
        s.moveOverlay(picID, toStart: MediaTime(seconds: 1), lane: 0, coalesce: false)
        check(s.project.overlayClips.first { $0.id == picID }?.lane == 1, "moving onto a busy line is refused")
        s.applyOverlayPreset(picID, .bottomLeft)
        let t0 = s.project.overlayClips.first { $0.id == picID }?.transform
        check((t0?.centerX ?? 1) < 0.3 && (t0?.centerY ?? 0) > 0.7, "preset puts the picture bottom-left")
        s.updateOverlay(camID, "border") { $0.transform.borderWidth = 0.02 }

        // Dragging on the picture: real mouse events into the manipulator view (in a hidden window).
        await dragOnPicture(s, picID: picID, camID: camID)

        // Keyframes: animate the picture's position, undo one step.
        await s.player.seek(to: MediaTime(seconds: 1))
        let at1 = s.player.currentTime.seconds
        s.addKeyframe(picID)
        await s.player.seek(to: MediaTime(seconds: 4))
        let at4 = s.player.currentTime.seconds
        await s.player.seek(to: MediaTime(seconds: 4))
        s.setOverlayValue(picID, "x") { $0.centerX = 0.8 }
        let kfs = s.project.overlayClips.first { $0.id == picID }?.keyframes ?? []
        let pc = s.project.overlayClips.first { $0.id == picID }
        check(kfs.count >= 2, "keyframes at 1 s and 4 s (\(kfs.count); playhead was \(at1) and \(at4); clip start \(pc?.start.seconds ?? -1), length \(pc?.duration.seconds ?? -1); keyframe times \(kfs.map { $0.time.seconds }))")
        s.undo()
        check((s.project.overlayClips.first { $0.id == picID }?.keyframes.count ?? 0) == kfs.count - 1, "undo removes just the last keyframe")
        s.redo()

        let outDir = work.appendingPathComponent("layered"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let req = ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "layered")
        if let (jobs, _) = try? s.planExport(req) {
            check(jobs[0].recipe.layers.count == 2, "the export job carries both layers")
            env.exports.enqueue(jobs); await waitForQueue(env, timeout: 120)
            let out = jobs[0].outputPath
            let idx = await frames(out)
            check(idx == Array(0..<180), "main picture keeps every frame (0…179) under the layers: \(idx.count) frames, missing \(Array(Set(0..<180).subtracting(idx).sorted().prefix(8)))")
            check((try? await MediaProbe.probe(url: URL(fileURLWithPath: out)))?.hasAudio == true, "sound is there (main + layer)")
            check((try? Data(contentsOf: demo)) == demoBytes, "the original is untouched")
        } else { check(false, "plan layered export") }

        check(s.saveNow(), "the project is saved into its file")
        let proj = s.projectPath ?? ""
        if let text = try? String(contentsOfFile: proj, encoding: .utf8) { check(text.contains("\"schemaVersion\" : 3") && text.contains("\"kind\" : \"video\""), "saved in format 3, as a video project") }
        if let re = try? await EditorSession.openProject(path: proj) {
            check(re.project.overlayClips == s.project.overlayClips, "reopened with both layers and their keyframes")
            re.close()
        } else { check(false, "reopen project with layers") }

        try? fm.removeItem(at: logo)
        check((try? s.planExport(req)) == nil, "export is blocked when a layer's picture file is gone")
        s.deleteOverlay(picID)
        check(s.project.overlayClips.count == 1 && (try? s.planExport(req)) != nil, "removing that layer unblocks it")
        s.close()
    }

    /// A click on the tool tile with that name, as the hardware sends it (pressed and released, queued together), and a hover before it.
    @discardableResult
    static func clickLabel(_ label: String, in win: NSWindow) async -> Bool {
        guard let f = SidebarProbe.tileFrames[label], let host = win.contentView else { print("   (no tile named \(label))"); return false }
        // SwiftUI measures from the top of the window's content; the window measures from the bottom unless the view is flipped.
        let p = host.convert(NSPoint(x: f.midX, y: host.isFlipped ? f.midY : host.bounds.height - f.midY), to: nil)
        for (type, n) in [(NSEvent.EventType.mouseMoved, 0), (.leftMouseDown, 1), (.leftMouseUp, 2)] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        return true
    }

    static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ win: NSWindow, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    static func dragOnPicture(_ s: EditorSession, picID: UUID, camID: UUID) async {
        let W: CGFloat = 800, H: CGFloat = 450
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.borderless], backing: .buffered, defer: false)
        let man = OverlayManipulatorView()
        win.contentView = man
        man.frame = NSRect(x: 0, y: 0, width: W, height: H)
        man.attach(s)
        man.videoRect = { CGRect(x: 0, y: 0, width: W, height: H) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)                   // let the preview rebuilds from the edits above finish
        await s.player.seek(to: MediaTime(seconds: 3))                     // both layers are on screen at 3 s
        s.selectedOverlayID = picID
        func clip(_ id: UUID) -> OverlayClip? { s.project.overlayClips.first { $0.id == id } }
        func centre(_ c: OverlayClip) -> CGPoint {   // the layer's centre in view coordinates (y up)
            let st = OverlayEditor.editableState(c, at: s.player.currentTime)
            return CGPoint(x: st.centerX * W, y: H - st.centerY * H)
        }
        guard let before = clip(picID) else { return }
        let st0 = OverlayEditor.editableState(before, at: s.player.currentTime)

        // Move: press on the picture, drag 100 px right and 50 px up (⌥ held so snapping does not interfere).
        let from = centre(before)
        man.mouseDown(with: mouse(.leftMouseDown, from, win))
        for i in 1...5 { man.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: from.x + 20 * CGFloat(i), y: from.y + 10 * CGFloat(i)), win, .option)) }
        man.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: from.x + 100, y: from.y + 50), win, .option))
        let st1 = OverlayEditor.editableState(clip(picID)!, at: s.player.currentTime)
        check(abs(st1.centerX - (st0.centerX + 100 / Double(W))) < 0.002 && abs(st1.centerY - (st0.centerY - 50 / Double(H))) < 0.002,
              "dragging the body moves the layer by the mouse distance (x \(String(format: "%.3f", st0.centerX)) → \(String(format: "%.3f", st1.centerX)))")
        s.undo()
        let st2 = OverlayEditor.editableState(clip(picID)!, at: s.player.currentTime)
        check(abs(st2.centerX - st0.centerX) < 1e-6 && abs(st2.centerY - st0.centerY) < 1e-6, "one undo step takes the whole drag back")
        s.redo()

        // Resize: drag the bottom-right handle outwards; the top-left corner must not move.
        let c1 = clip(picID)!
        let sa = OverlayEditor.editableState(c1, at: s.player.currentTime)
        let oa = Double(W / H), la = s.layerAspect(c1)
        let r0 = OverlayDrag.rect(sa, outputAspect: oa, layerAspect: la)
        let handle = CGPoint(x: CGFloat(r0.x1) * W, y: H - CGFloat(r0.y1) * H)
        man.mouseDown(with: mouse(.leftMouseDown, handle, win))
        man.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: handle.x + 40, y: handle.y - 22), win))
        man.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: handle.x + 40, y: handle.y - 22), win))
        let sb = OverlayEditor.editableState(clip(picID)!, at: s.player.currentTime)
        let r1 = OverlayDrag.rect(sb, outputAspect: oa, layerAspect: la)
        check(sb.width > sa.width + 0.02 && abs(r1.x0 - r0.x0) < 1e-6 && abs(r1.y0 - r0.y0) < 1e-6, "dragging a corner resizes it and keeps the opposite corner (width \(String(format: "%.3f", sa.width)) → \(String(format: "%.3f", sb.width)))")

        // Clicking another layer on the picture selects it.
        let camCentre = centre(clip(camID)!)
        man.mouseDown(with: mouse(.leftMouseDown, camCentre, win)); man.mouseUp(with: mouse(.leftMouseUp, camCentre, win))
        let camClip = clip(camID)!
        let camState = camClip.state(at: s.player.currentTime)
        check(s.selectedOverlayID == camID, "clicking another layer selects it (playhead \(String(format: "%.2f", s.player.currentTime.seconds)), click \(camCentre), cam state \(String(describing: camState.map { ($0.centerX, $0.centerY, $0.width) })), selected is pic: \(s.selectedOverlayID == picID))")

        // The frame on screen is redrawn while paused: a live change shows without waiting for the rebuild.
        guard let item = s.player.player.currentItem else { return }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        func magentaAt(_ nx: Double, _ ny: Double) -> Bool {
            let t = s.player.player.currentTime()
            guard out.hasNewPixelBuffer(forItemTime: t) || true, let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return false }
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
            let o = min(h - 1, Int(ny * Double(h))) * stride + min(w - 1, Int(nx * Double(w))) * 4
            let p = base.assumingMemoryBound(to: UInt8.self)
            return p[o + 2] > 200 && p[o + 1] < 70 && p[o] > 200   // BGRA: magenta = high R and B, low G
        }
        s.selectedOverlayID = picID
        s.setOverlayValue(picID, "drag") { $0.centerX = 0.5; $0.centerY = 0.45; $0.width = 0.2 }   // the live path only
        var seen = false
        let until = Date().addingTimeInterval(0.15)
        while Date() < until && !seen { try? await Task.sleep(nanoseconds: 15_000_000); seen = magentaAt(0.5, 0.45) }
        check(seen, "a paused frame is redrawn within 150 ms of a drag (before the preview is rebuilt)")
        s.endCoalescing()
    }

    static func key(_ chars: String, code: UInt16, _ win: NSWindow, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static func interfaceFlow(env: AppEnvironment, work: URL, demo: URL, app: AppDelegate) async {
        print("== J: shortcuts, menus, window level, parallel exports, audio tracks")
        let fm = FileManager.default
        guard let s = await editor(demo) else { check(false, "open for interface checks"); return }
        await waitFor { s.player.duration.seconds > 19 }
        let wc = MainWindowController(playlists: app.playlists)     // never shown: events are sent straight to its window
        wc.setSession(s, fromPlaylist: false)
        app.adopt(wc)
        guard let win = wc.window else { return }
        env.prefs.skipSeconds = 5; env.prefs.bigSkipSeconds = 10
        s.player.pause(); await s.player.seek(to: .zero)

        // Keys
        win.sendEvent(key(" ", code: 49, win)); try? await Task.sleep(nanoseconds: 300_000_000)
        check(s.player.isPlaying, "Space starts playback")
        win.sendEvent(key(" ", code: 49, win)); try? await Task.sleep(nanoseconds: 200_000_000)
        check(!s.player.isPlaying, "Space pauses it")
        await s.player.seek(to: .zero)
        win.sendEvent(key("→", code: 124, win)); try? await Task.sleep(nanoseconds: 600_000_000)
        check(abs(s.player.currentTime.seconds - 5) < 0.1, "→ skips forward 5 s (\(String(format: "%.2f", s.player.currentTime.seconds)))")
        win.sendEvent(key("→", code: 124, win, .shift)); try? await Task.sleep(nanoseconds: 600_000_000)
        check(abs(s.player.currentTime.seconds - 15) < 0.1, "⇧→ skips the big step, 10 s (\(String(format: "%.2f", s.player.currentTime.seconds)))")
        win.sendEvent(key("←", code: 123, win)); try? await Task.sleep(nanoseconds: 600_000_000)
        check(abs(s.player.currentTime.seconds - 10) < 0.1, "← skips back 5 s")
        let t0 = s.player.currentTime.seconds
        win.sendEvent(key(".", code: 47, win)); try? await Task.sleep(nanoseconds: 700_000_000)
        check(abs(s.player.currentTime.seconds - (t0 + 1.0 / 30)) < 0.02, ". steps one frame forward")
        win.sendEvent(key(",", code: 43, win)); try? await Task.sleep(nanoseconds: 700_000_000)
        check(abs(s.player.currentTime.seconds - t0) < 0.02, ", steps one frame back")

        await s.player.seek(to: MediaTime(seconds: 4)); win.sendEvent(key("s", code: 1, win))
        await waitFor(3) { s.project.timeline.count == 2 }
        check(s.project.timeline.count == 2, "S splits the clip at the playhead")
        win.sendEvent(key("m", code: 46, win)); try? await Task.sleep(nanoseconds: 300_000_000)
        check(s.project.markers.count == 1, "M adds a marker")
        let sp = s.player.speed
        win.sendEvent(key("=", code: 24, win)); check(abs(s.player.speed - sp * 1.25) < 0.001, "= speeds up")
        win.sendEvent(key("-", code: 27, win)); check(abs(s.player.speed - sp) < 0.001, "- slows down")
        s.selectedOverlayID = nil
        s.selectedClipIDs = [s.project.timeline[1].id]
        win.sendEvent(key("\u{7F}", code: 51, win))
        check(s.project.timeline.count == 1, "Delete removes the selected clip")

        // The same keys while typing, or with ⌘, must do nothing (they belong to the text field and to the menu).
        let before = (s.project.timeline.count, s.project.markers.count, s.player.isPlaying)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        win.contentView?.addSubview(field)
        check(win.makeFirstResponder(field), "a text field can take the focus")
        for (c, code) in [("s", UInt16(1)), ("m", 46), (" ", 49)] { win.sendEvent(key(c, code: code, win)) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(s.project.timeline.count == before.0 && s.project.markers.count == before.1 && s.player.isPlaying == before.2, "typing s, m or Space in a text field does not trigger shortcuts")
        field.removeFromSuperview(); _ = win.makeFirstResponder(nil)
        win.sendEvent(key("m", code: 46, win, .command)); try? await Task.sleep(nanoseconds: 200_000_000)
        check(s.project.markers.count == before.1, "⌘M is left to the menu, not taken as the M shortcut")

        // Menu
        let items = app.allMenuItems
        let dead = items.filter { $0.action != nil && !$0.isSeparatorItem && ($0.target ?? NSApp.target(forAction: $0.action!, to: nil, from: $0)) == nil }.map(\.title)
        check(dead.isEmpty, "every menu item has something to act on (dead: \(dead))")
        var seen: [String: String] = [:], dup: [String] = []
        for i in items where !i.keyEquivalent.isEmpty { let k = "\(i.keyEquivalentModifierMask.rawValue)-\(i.keyEquivalent)"; if let o = seen[k] { dup.append("\(o) / \(i.title)") } else { seen[k] = i.title } }
        check(dup.isEmpty, "no two menu items share a shortcut (\(dup))")
        func enabled(_ sel: Selector) -> Bool? { items.first { $0.action == sel }.map { app.validateMenuItem($0) } }
        check(enabled(#selector(AppDelegate.saveDocument(_:))) == true, "Save Now is available with a project open")
        s.edit("test edit", refreshPreview: false) { $0.markers.append(Marker(time: MediaTime(seconds: 1), name: "x")) }
        check(enabled(#selector(AppDelegate.undo(_:))) == true && (items.first { $0.action == #selector(AppDelegate.undo(_:)) }?.title.contains("test edit") == true), "Undo is enabled and names the edit")
        s.undo()
        check(enabled(#selector(AppDelegate.undo(_:))) != nil, "menu validation after undo does not fail")
        let empty = MainWindowController(playlists: app.playlists); app.adopt(empty)
        check(app.activeSession != nil, "the window with a video is the one menu commands act on")
        wc.close()

        // Window level
        env.prefs.keepWindowOnTop = true; app.applyFloating()
        check(wc.window?.level == .floating, "“keep on top” raises the window level")
        env.prefs.keepWindowOnTop = false; app.applyFloating()
        check(wc.window?.level == .normal, "and turning it off lowers it again")

        // Parallel exports
        for limit in [1, 3] {
            env.prefs.maxConcurrentExports = limit
            let dir = work.appendingPathComponent("par\(limit)"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let ps = await editor(demo) else { continue }
            var jobs: [ExportJob] = []
            for i in 0..<6 {
                ps.edit("range", refreshPreview: false) { $0.timeline[0].sourceStart = MediaTime(seconds: Double(i) * 3); $0.timeline[0].sourceEnd = MediaTime(seconds: Double(i) * 3 + 2.5) }
                if let (j, _) = try? ps.planExport(ExportRequest(options: ExportOptions(mode: .exact), folder: dir.path, baseName: "p\(i + 1)")) { jobs += j }
            }
            guard jobs.count == 6 else { check(false, "plan parallel"); continue }
            env.exports.enqueue(jobs)
            var peak = 0
            let end = Date().addingTimeInterval(120)
            while env.exports.queue.hasWork && Date() < end { peak = max(peak, env.exports.queue.running.count); try? await Task.sleep(nanoseconds: 15_000_000) }
            let done = env.exports.queue.jobs.filter { j in jobs.contains { $0.id == j.id } }.allSatisfy { if case .succeeded = $0.state { return true }; return false }
            check(done, "all six exports finished (limit \(limit))")
            check(peak <= limit && (limit == 1 ? peak == 1 : peak >= 2), "at most \(limit) ran at once; peak seen \(peak)")
            ps.close()
        }
        env.prefs.maxConcurrentExports = 1

        // The interface keeps answering while an export runs (design section 16): how long the main loop was ever held up.
        if let ps = await editor(demo) {
            let dir = work.appendingPathComponent("stall"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var jobs: [ExportJob] = []
            for i in 0..<4 {
                ps.edit("clips", refreshPreview: false) { p in
                    p.timeline[0].look.color.brightness = 0.1          // the picture-processing path, the heaviest one
                    p.timeline[0].sourceStart = MediaTime(seconds: Double(i) * 4); p.timeline[0].sourceEnd = MediaTime(seconds: Double(i) * 4 + 3.5)
                }
                if let (j, _) = try? ps.planExport(ExportRequest(options: ExportOptions(mode: .exact), folder: dir.path, baseName: "s\(i + 1)")) { jobs += j }
            }
            if !jobs.isEmpty {
                env.exports.enqueue(jobs)
                var worst = 0.0, ticks = 0
                let end = Date().addingTimeInterval(120)
                while env.exports.queue.hasWork && Date() < end {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    worst = max(worst, ProcessInfo.processInfo.systemUptime - t0 - 0.010); ticks += 1
                }
                check(ticks > 20, "the export ran long enough to measure (\(ticks) ticks)")
                check(worst < 0.25, "the interface was never held up more than 250 ms during an export (worst \(String(format: "%.0f", worst * 1000)) ms)")
            }
            ps.close()
        }

        // Choosing an audio track
        var spec = SyntheticMedia.Spec(); spec.container = .mov; spec.width = 320; spec.height = 180; spec.seconds = 2; spec.secondAudioTrack = true; spec.alternateAudioTracks = true
        let two = work.appendingPathComponent("two-audio.mov")
        try? await SyntheticMedia.generate(to: two, spec: spec)
        if let ts = try? await EditorSession.open(url: two) {
            check(ts.player.audioOptions.count == 2, "the player offers both audio tracks (\(ts.player.audioOptions.count))")
            if ts.player.audioOptions.count == 2, let item = ts.player.player.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                let current = item.currentMediaSelection.selectedMediaOption(in: group)
                let other = ts.player.audioOptions.first { $0 != current } ?? ts.player.audioOptions[1]
                await ts.player.selectAudio(other)
                check(item.currentMediaSelection.selectedMediaOption(in: group) == other, "choosing the other track switches the playing sound")
            }
            ts.close()
        }
        s.close()
    }

    /// Presentation times of every frame a file shows (decoded, so edit lists are respected).
    static func decodedTimes(_ u: URL) async -> [Double] {
        let a = AVURLAsset(url: u)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: a) else { return [] }
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        o.alwaysCopiesSampleData = false
        r.add(o); r.startReading()
        var out: [Double] = []
        while let sb = o.copyNextSampleBuffer() { let p = CMSampleBufferGetPresentationTimeStamp(sb); if p.isNumeric { out.append(p.seconds) } }
        return out
    }

    static func realFlow(env: AppEnvironment, work: URL, real: URL, app: AppDelegate) async {
        print("== K: real videos in the real app")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        for name in ["sdr-1080-avc.mp4", "hdr10-4k-hevc.mp4", "dv-4k-p81.mp4"] where fm.fileExists(atPath: real.appendingPathComponent(name).path) {
            print("-- \(name)")
            let dir = work.appendingPathComponent("real-\(name)"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name); try? fm.copyItem(at: real.appendingPathComponent(name), to: url)
            let original = (try? Data(contentsOf: url)) ?? Data()
            guard let s = try? await EditorSession.open(url: url) else { check(false, "open \(name)"); continue }
            check(s.duration.seconds > 29 && s.duration.seconds < 31 && abs(s.frameRate.framesPerSecond - 60) < 0.01, "opened: \(Int(s.duration.seconds)) s at \(s.frameRate.framesPerSecond) fps")

            s.player.play(); try? await Task.sleep(nanoseconds: 800_000_000)
            let t0 = s.player.currentTime.seconds
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let rate = (s.player.currentTime.seconds - t0) / 2.0
            check(rate > 0.9 && rate < 1.1, "plays at normal speed (\(String(format: "%.2f", rate)))")
            s.player.pause()

            // A frame near 10 s, by the file's own frame times; then one forward and one back by the same table.
            guard let a = try? await FrameLocator.frame(url: url, at: MediaTime(seconds: 10)), let b = try? await FrameLocator.step(url: url, from: a.time, by: 240) else { check(false, "frame table"); continue }
            await s.player.seek(to: a.time)
            check(abs(s.player.currentTime.seconds - a.time.seconds) < 0.0005, "exact seek lands on the frame time (\(s.player.currentTime.seconds) vs \(a.time.seconds))")
            let next = try? await FrameLocator.step(url: url, from: a.time, by: 1)
            s.player.step(frames: 1); try? await Task.sleep(nanoseconds: 900_000_000)
            check(next != nil && abs(s.player.currentTime.seconds - next!.seconds) < 0.0005, "one frame forward")
            s.player.step(frames: -1); try? await Task.sleep(nanoseconds: 900_000_000)
            check(abs(s.player.currentTime.seconds - a.time.seconds) < 0.0005, "one frame back")

            s.close()
            // A project of 240 frames from it, exported as a new file
            let projPath = dir.appendingPathComponent("real.macplayer").path
            if let p = try? await EditorSession.makeProjectFile(kind: .video, media: url, at: projPath), let id = p.project.timeline.first?.id {
                p.edit("Trim", refreshPreview: false) { TimelineEditor.trim(&$0.timeline, clipID: id, start: a.time, end: b, sourceDuration: p.info?.duration ?? .zero) }
                let outDir = dir.appendingPathComponent("out"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
                if let (jobs, _) = try? p.planExport(ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "Real")) {
                    env.exports.enqueue(jobs); await waitForQueue(env, timeout: 120)
                    let ok: Bool = { if case .succeeded = env.exports.queue.jobs.first(where: { $0.id == jobs[0].id })?.state { return true }; return false }()
                    let t = await decodedTimes(URL(fileURLWithPath: jobs[0].outputPath))
                    check(ok && t.count == 240 && abs(t.first ?? 9) < 0.02, "exported a new file: \(t.count) frames from \(String(format: "%.3f", t.first ?? -1)) s")
                } else { check(false, "plan export") }
                check(p.saveNow(), "project saved")
                p.close()
                if let re = try? await EditorSession.openProject(path: projPath) {
                    check(re.isProject && re.project.timeline.count == 1 && re.duration.seconds > 3.9 && re.duration.seconds < 4.1, "project reopened (\(re.project.timeline.count) clip, \(String(format: "%.2f", re.duration.seconds)) s)")
                    re.close()
                } else { check(false, "reopen project") }
            } else { check(false, "make a project") }
            check((try? Data(contentsOf: url)) == original, "source untouched, byte for byte")
            try? fm.removeItem(at: dir)      // free the disk: these are big
        }

        // Full screen, with a real video playing
        if let url = ["sdr-1080-avc.mp4", "hdr10-4k-hevc.mp4"].map({ real.appendingPathComponent($0) }).first(where: { fm.fileExists(atPath: $0.path) }), let s = try? await EditorSession.open(url: url) {
            print("-- full screen")
            let wc = MainWindowController(playlists: app.playlists); wc.setSession(s, fromPlaylist: false); app.adopt(wc)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()       // a window only goes full screen when its app is the active one
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            wc.showWindow(nil); wc.window?.makeKeyAndOrderFront(nil)
            await waitFor(ProcessInfo.processInfo.environment["MACPLAYER_WAIT_ACTIVE"] != nil ? 60 : 4) { NSApp.isActive }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard NSApp.isActive else {
                // macOS does not let a background process take focus, and a window only goes full screen in the active app.
                print("SKIP  full screen: the app is not the active one (needs a person to click it). Not verified.")
                wc.window?.orderOut(nil); s.close()      // hide, never close: closing the last window quits the app
                return
            }
            s.player.play()
            wc.window?.toggleFullScreen(nil)
            await waitFor(8) { wc.window?.styleMask.contains(.fullScreen) == true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            check(wc.window?.styleMask.contains(.fullScreen) == true, "the window went full screen (visible=\(wc.window?.isVisible ?? false), appActive=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), behavior=\(wc.window?.collectionBehavior.rawValue ?? 0), screen=\(wc.window?.screen?.frame.size ?? .zero))")
            let f0 = s.player.currentTime.seconds; try? await Task.sleep(nanoseconds: 1_500_000_000)
            check(s.player.currentTime.seconds - f0 > 1.2, "the video keeps playing in full screen (\(String(format: "%.2f", s.player.currentTime.seconds - f0)) s in 1.5 s)")
            if let w = wc.window, let v = w.contentView { check(v.bounds.width > 1000 && v.frame.size == w.frame.size || v.bounds.width > 1000, "content fills the screen (\(Int(v.bounds.width))×\(Int(v.bounds.height)))") }
            wc.window?.toggleFullScreen(nil)
            await waitFor(8) { wc.window?.styleMask.contains(.fullScreen) == false }
            try? await Task.sleep(nanoseconds: 800_000_000)
            check(wc.window?.styleMask.contains(.fullScreen) == false, "and came back out of full screen")
            s.player.pause()
            wc.window?.orderOut(nil); s.close()      // hide, never close: closing the last window quits the app
        }
    }

    /// `MacPlayer --sandbox <dir> --fullscreen-check <video>` (start it with `open`, so the app is the active one): plays a video, goes full
    /// screen, plays, comes back, and prints where everything is at each step (a script takes pictures of the window at the "PHASE" lines).
    static func fullScreenCheck(app: AppDelegate) async {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.activate(ignoringOtherApps: true)
        await waitFor(15) { app.activeSession != nil }
        guard let wc = app.active, let win = wc.window, let s = wc.session else { print("PHASE failed: no video opened"); exit(1) }
        await waitFor(10) { NSApp.isActive }
        func findLayer(_ l: CALayer?) -> AVPlayerLayer? { guard let l else { return nil }; if let p = l as? AVPlayerLayer { return p }; for c in l.sublayers ?? [] { if let p = findLayer(c) { return p } }; return nil }
        func report(_ label: String) {
            let ph = wc.contentController.host
            let pl = findLayer(ph?.playerView.layer)
            print("PHASE \(label) id=\(win.windowNumber) win=\(win.frame) full=\(win.styleMask.contains(.fullScreen)) screen=\(win.screen?.frame.size ?? .zero)")
            print("  host=\(ph?.frame ?? .zero) bounds=\(ph?.bounds ?? .zero) playerView=\(ph?.playerView.frame ?? .zero) videoBounds=\(ph?.playerView.videoBounds ?? .zero)")
            print("  layer=\(pl.map { "bounds=\($0.bounds) ready=\($0.isReadyForDisplay) hidden=\($0.isHidden)" } ?? "none") playing=\(s.player.isPlaying) t=\(String(format: "%.2f", s.player.currentTime.seconds)) panels=\(wc.panelsCollapsed)")
        }
        s.player.play(); try? await Task.sleep(nanoseconds: 1_500_000_000)
        report("windowed"); try? await Task.sleep(nanoseconds: 3_000_000_000)
        win.toggleFullScreen(nil)
        await waitFor(10) { win.styleMask.contains(.fullScreen) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        s.player.play()
        report("full"); try? await Task.sleep(nanoseconds: 4_000_000_000)
        win.toggleFullScreen(nil)
        await waitFor(10) { !win.styleMask.contains(.fullScreen) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        report("exited"); try? await Task.sleep(nanoseconds: 5_000_000_000)
        print("PHASE done"); exit(0)
    }

    /// `MacPlayer --sandbox <dir> --switch-check <folder>` (start it with `open`): plays the videos of a folder one after another while the editing
    /// tools are changed, and prints the window's size each time, so a window that grows or loses a part of its content shows up.
    static func switchCheck(app: AppDelegate) async {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.activate(ignoringOtherApps: true)
        await waitFor(20) { app.activeSession != nil }
        guard let wc = app.active, let win = wc.window else { print("PHASE failed: nothing opened"); exit(1) }
        let tabs: [InspectorTab] = [.effects, .picture, .audio, .text, .effects, .clips, .effects, .export]
        func report(_ label: String) {
            let ph = wc.contentController.host
            let top = ph.map { $0.convert($0.bounds, to: nil).maxY } ?? 0
            print("STEP \(label) win=\(win.frame) content=\(win.contentLayoutRect.size) minSize=\(win.minSize) host=\(ph?.frame ?? .zero) hostTopInWindow=\(top) screen=\(win.screen?.visibleFrame.size ?? .zero) full=\(win.styleMask.contains(.fullScreen))")
        }
        report("start")
        for i in 0..<14 {
            if let s = wc.session { s.activeTool = tabs[i % tabs.count] }
            try? await Task.sleep(nanoseconds: 700_000_000)
            report("tab \(i) \(wc.session?.activeTool.rawValue ?? "-")")
            app.playlists.advance(auto: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            report("video \(i) \(wc.session?.sourceURL?.lastPathComponent ?? "-")")
        }
        // A small window (the smallest allowed) with each tool open: nothing may push the window past its size.
        win.setContentSize(NSSize(width: 900, height: 560))
        for t in [InspectorTab.effects, .picture, .audio, .text, .subtitles, .export, .layers, .timing] {
            wc.session?.activeTool = t
            try? await Task.sleep(nanoseconds: 600_000_000)
            report("small \(t.rawValue)")
        }
        win.setContentSize(NSSize(width: 1280, height: 800))
        win.toggleFullScreen(nil)
        await waitFor(10) { win.styleMask.contains(.fullScreen) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        report("fullscreen")
        for i in 0..<4 {
            app.playlists.advance(auto: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            report("full video \(i)")
        }
        win.toggleFullScreen(nil)
        await waitFor(10) { !win.styleMask.contains(.fullScreen) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        report("exited")
        print("PHASE done"); exit(0)
    }

    /// `MacPlayer --sandbox <dir> --effects-check <video>` (start it with `open`): switches between the colour filters on a real video and prints,
    /// for each change, how long the main thread was held up and how long the picture took to come back.
    static func effectsCheck(app: AppDelegate) async {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.activate(ignoringOtherApps: true)
        await waitFor(20) { app.activeSession != nil }
        guard let s = app.activeSession else { print("PHASE failed: nothing opened"); exit(1) }
        s.activeTool = .effects
        s.player.play(); try? await Task.sleep(nanoseconds: 2_000_000_000)
        final class Gap { var last = ProcessInfo.processInfo.systemUptime; var worst = 0.0 }
        let gap = Gap()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            gap.worst = max(gap.worst, now - gap.last); gap.last = now
        }
        for round in 0..<2 {
            for p in FilterPreset.allCases {
                gap.worst = 0
                let t0 = ProcessInfo.processInfo.systemUptime
                s.editEffects("filter") { $0.filter = p; $0.filterAmount = 1 }
                // The preview is rebuilt shortly after; wait until it is back and showing a picture.
                try? await Task.sleep(nanoseconds: 400_000_000)
                var waited = 0
                while s.player.duration == .zero && waited < 100 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
                let ready = ProcessInfo.processInfo.systemUptime - t0
                let before = s.player.currentTime.seconds
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let speed = (s.player.currentTime.seconds - before) / 1.5
                print(String(format: "FILTER r%d %@ ready=%.2fs worst main-thread stall=%.0f ms playing=%@ playback speed after=%.2fx", round, "\(p)", ready, gap.worst * 1000, s.player.isPlaying ? "yes" : "no", speed))
            }
        }
        timer.invalidate()
        print("PHASE done"); exit(0)
    }

    static func finish() { print("\(failures) FAILED"); exit(1) }
}

@MainActor
final class SelfTestHost: PlaylistHost {
    var current: EditorSession?
    var messages: [String] = []
    var hostHasUnsavedEdits: Bool { false }
    func playPlaylistItem(url: URL, startAt: MediaTime?) async -> Bool {
        guard let s = try? await EditorSession.open(url: url) else { return false }
        current?.close()
        current = s
        s.player.onEnded = { MainActor.assumeIsolated { AppEnvironment.shared.playlistsForSelfTest?.advance(auto: true) } }
        s.player.play()
        return true
    }
    func showPlaylistMessage(_ text: String, isError: Bool) { messages.append(text) }
    func stopPlaylistPlayback(path: String?) {
        guard let s = current else { return }
        if let p = path, s.sourceURL?.standardizedFileURL.path != URL(fileURLWithPath: p).standardizedFileURL.path { return }
        s.close(); current = nil
    }
}
