import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import MacPlayerCore
import MacPlayerMedia

/// Flow G2: the video editor's panels and drag-and-drop, in a real window. Files go into the library, then are dropped on the
/// timeline's tracks (through the timeline's own drop code, with a pasteboard as Finder or the library would fill it); filters,
/// transitions and text styles are dropped on clips, cuts and times; what is selected is edited, duplicated and deleted.
extension SelfTest {
    static func workspaceFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G2: the editor's library, properties and drag-and-drop on the timeline")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        var videos: [URL] = []
        for i in 0..<2 {
            var spec = SyntheticMedia.Spec(); spec.width = 640; spec.height = 360; spec.seconds = 4; spec.withAudio = i == 0
            let u = work.appendingPathComponent("ws-\(i).mp4"); try? fm.removeItem(at: u)
            try? await SyntheticMedia.generate(to: u, spec: spec); videos.append(u)
        }
        let photo = work.appendingPathComponent("ws-logo.png")
        writePNG(to: photo)
        let music = work.appendingPathComponent("ws-music.wav")
        writeTone(to: music, seconds: 3)
        let notes = work.appendingPathComponent("notes.txt"); try? "x".write(to: notes, atomically: true, encoding: .utf8)
        let originals = Dictionary(uniqueKeysWithValues: (videos + [photo, music]).map { ($0, (try? Data(contentsOf: $0)) ?? Data()) })

        let path = work.appendingPathComponent("workspace.macplayer").path; try? fm.removeItem(atPath: path)
        guard let s = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "make a video project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        try? await Task.sleep(nanoseconds: 600_000_000)

        // The layout: library, picture, properties; timeline across the whole width.
        guard let ws = wc.contentController.workspace, let tl = wc.contentController.timeline else { check(false, "the video editor has its panels"); return }
        check(!ws.libraryItem.isCollapsed && !ws.propertiesItem.isCollapsed, "the library and the properties are open")
        let win = wc.window!.contentView!.bounds.width
        check(abs(tl.frame.width - win) < 2, "the timeline spans the whole window (\(Int(tl.frame.width)) of \(Int(win)))")
        check(wc.panelsCollapsed.sidebar && !wc.panelsCollapsed.inspector, "no playlist panel; the properties count as the tools panel")

        // Library: files are brought in once, other files are left out, nothing is copied.
        let added = s.importToLibrary(videos + [photo, music, notes])
        check(added == 4 && s.project.mediaBin.count == 4, "four files go into the library, the text file is left out (\(added))")
        check(s.importToLibrary(videos) == 0, "the same files are not added twice")
        check(s.project.mediaBin.map(\.kind) == [.video, .video, .photo, .audio], "each is recognised (\(s.project.mediaBin.map(\.kind.rawValue)))")

        // Drops on an empty timeline: a photo has no video to go over yet.
        let d1 = tl.testDrop(urls: [videos[0]], item: nil, at: tl.testPoint(track: "main", time: 0))
        check(d1 == .insert(0), "a video dropped on the empty timeline goes in first (\(String(describing: d1)))")
        await waitFor(10) { s.project.timeline.count == 1 && s.duration.seconds > 3 }
        tl.fitAll(); try? await Task.sleep(nanoseconds: 200_000_000)
        // The second video, dropped on the first half of the first clip, goes before it.
        let d2 = tl.testDrop(urls: [videos[1]], item: nil, at: tl.testPoint(track: "main", time: 0.5))
        check(d2 == .insert(0), "a video dropped on the start of a clip goes before it (\(String(describing: d2)))")
        await waitFor(10) { s.project.timeline.count == 2 && s.duration.seconds > 7 }
        let order = s.project.timeline.map { s.project.source($0.sourceID).map { PathUtil.fileName(of: $0.path) } ?? "?" }
        check(order == ["ws-1.mp4", "ws-0.mp4"], "the timeline has the dropped order (\(order))")
        tl.fitAll(); try? await Task.sleep(nanoseconds: 200_000_000)

        // A photo dropped on layer 2 at 1 s; a sound on the sound track at 2 s.
        let d3 = tl.testDrop(urls: [photo], item: nil, at: tl.testPoint(track: "lane1", time: 1))
        await waitFor(6) { s.project.overlayClips.count == 1 }
        let layer = s.project.overlayClips.first
        check(d3.map { if case .lane(1, _) = $0 { return true }; return false } == true && layer?.lane == 1 && abs((layer?.start.seconds ?? 0) - 1) < 0.15,
              "a photo dropped on layer 2 at 1 s becomes a layer there (lane \(layer?.lane ?? -1), \(String(format: "%.2f", layer?.start.seconds ?? -1)) s)")
        _ = tl.testDrop(urls: [music], item: nil, at: tl.testPoint(track: "audio", time: 2))
        await waitFor(6) { s.project.soundClips.count == 1 }
        check(abs((s.project.soundClips.first?.start.seconds ?? -1) - 2) < 0.15, "a sound dropped at 2 s starts at 2 s (\(String(format: "%.2f", s.project.soundClips.first?.start.seconds ?? -1)))")

        // A filter dropped on the second clip; a transition on the cut; a text style at 3 s.
        let second = s.project.timeline[1].id
        let d4 = tl.testDrop(urls: [], item: .filter(.noir), at: tl.testPoint(track: "main", time: 6))
        check(d4 == .clip(second) && s.project.timeline[1].look.effects.filter == .noir && s.project.timeline[0].look.effects.filter == .none, "a filter dropped on clip 2 is put on clip 2 only")
        let d5 = tl.testDrop(urls: [], item: .transition(.dissolve), at: tl.testPoint(track: "main", time: 3.6))
        check(d5 == .cut(second) && s.project.timeline[1].look.transitionIn?.kind == .dissolve, "a transition dropped near the cut goes into the clip after it")
        check(tl.testDrop(urls: [], item: .transition(.spin), at: tl.testPoint(track: "main", time: 0.1)) == .cut(second), "a transition always lands on a cut (the first clip has none)")
        let d6 = tl.testDrop(urls: [], item: .text(.neon), at: tl.testPoint(track: "text", time: 3))
        let text = s.project.overlays.first
        check(d6 == .text(3) || abs((text?.start.seconds ?? 0) - 3) < 0.15, "a text style dropped at 3 s adds a text there (\(String(format: "%.2f", text?.start.seconds ?? -1)))")
        check(s.selection == text.map { .text($0.id) } && s.activeTool == .text, "the new text is selected and its settings are open")

        // Selection decides what the properties show; Delete removes only the selected thing.
        s.select(.clip(second))
        check(InspectorTab.propertyTabs(for: s.selection).contains(s.activeTool) && s.selectedOverlayID == nil && s.selectedTextID == nil, "selecting a clip shows clip settings and nothing else stays selected")
        if let t = text { s.select(.text(t.id)); s.duplicateSelection() }
        check(s.project.overlays.count == 2, "a text can be duplicated")
        s.deleteSelection()
        check(s.project.overlays.count == 1, "Delete removes the selected text only")
        if let l = layer { s.select(.layer(l.id)); s.deleteSelection() }
        check(s.project.overlayClips.isEmpty && s.project.timeline.count == 2 && s.project.soundClips.count == 1, "deleting the layer leaves the clips and the sound")
        s.undo()
        check(s.project.overlayClips.count == 1, "undo brings the layer back")

        // Moving a text and a sound in time.
        if let t = s.project.overlays.first { s.moveText(t.id, toStart: MediaTime(seconds: 1)); s.endCoalescing() }
        check(abs((s.project.overlays.first?.start.seconds ?? 0) - 1) < 0.01, "a text can be moved in time")
        if let c = s.project.soundClips.first { s.moveSound(c.id, toStart: MediaTime(seconds: 0.5)); s.endCoalescing() }
        check(abs((s.project.soundClips.first?.start.seconds ?? 0) - 0.5) < 0.01, "a sound can be moved in time")
        if let c = s.project.soundClips.first {
            s.trimSound(c.id, leftEdge: false, to: MediaTime(seconds: 2)); s.endCoalescing()
            let a = s.project.soundClips.first
            check(abs((a?.duration.seconds ?? 0) - 1.5) < 0.01, "a sound's end can be dragged (1.5 s long: \(String(format: "%.2f", a?.duration.seconds ?? -1)))")
            s.trimSound(c.id, leftEdge: false, to: MediaTime(seconds: 30)); s.endCoalescing()
            check(abs((s.project.soundClips.first?.duration.seconds ?? 0) - 3) < 0.05, "but not past the end of its file")
            s.trimSound(c.id, leftEdge: true, to: MediaTime(seconds: 1.5)); s.endCoalescing()
            let b = s.project.soundClips.first
            check(abs((b?.start.seconds ?? 0) - 1.5) < 0.01 && abs((b?.sourceStart.seconds ?? 0) - 1) < 0.01 && abs((b?.end.seconds ?? 0) - 3.5) < 0.05,
                  "dragging its start keeps its end and skips the start of the file")
        }

        // Library state: what is used is marked, and taking an unused file out of the library leaves the file alone.
        check(s.project.uses(path: videos[0].path) && s.project.uses(path: photo.path), "the library knows which files are used")
        // A photo dropped on the main track becomes a clip of its own (a short video MacPlayer makes in its own folder).
        let before = s.duration.seconds
        let d7 = tl.testDrop(urls: [photo], item: nil, at: tl.testPoint(track: "main", time: before - 0.1))
        await waitFor(15) { s.project.timeline.count == 3 && s.duration.seconds > before + 4 }
        let still = s.project.timeline.last
        let stillSource = still.flatMap { s.project.source($0.sourceID) }
        check(d7 == .insert(2) && stillSource?.stillOf.map { PathUtil.same($0, photo.path) } == true && abs((still?.duration.seconds ?? 0) - 5) < 0.05,
              "a photo dropped at the end of the main track becomes a 5 s clip (\(String(describing: d7)), \(String(format: "%.2f", still?.duration.seconds ?? -1)) s)")
        check(stillSource.map { $0.path.hasPrefix(env.support.path) } == true, "its video is kept in MacPlayer's own folder, not next to the photo")
        check(abs(s.duration.seconds - (before + 5)) < 0.2, "the preview grows by the photo's 5 s (\(String(format: "%.2f", before)) → \(String(format: "%.2f", s.duration.seconds)))")
        if let c = still {
            let start = TimelineEditor.starts(s.project.timeline)[c.id]?.seconds ?? 0
            s.trimClip(c.id, leftEdge: false, toTimelineTime: MediaTime(seconds: start + 9)); s.endCoalescing()
            check(abs((s.project.timeline.last?.duration.seconds ?? 0) - 9) < 0.05, "a photo clip can be dragged longer (9 s)")
        }
        check(s.project.uses(path: photo.path) && !s.project.libraryItems.contains { $0.path.hasSuffix(".mov") }, "the library shows the photo, not its little video")
        // Exported: the photo is in the video, at the video's own frame rate.
        let outDir = work.appendingPathComponent("ws-out"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let res = await runExport(s, env: env, ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "with-photo"))
        if let out = res.path, let info = try? await MediaProbe.probe(url: URL(fileURLWithPath: out)) {
            // The videos keep their pace; since 0.16.4 the photo's part, which never changes, is written at least once a second, not 30 times.
            let photoStart = s.project.timeline.last.flatMap { TimelineEditor.starts(s.project.timeline)[$0.id] }?.seconds ?? 0
            let asset = AVURLAsset(url: URL(fileURLWithPath: out))
            var times: [Double] = []
            if let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) {
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(o); reader.startReading()
                while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) } }
            }
            times.sort()
            func gaps(_ t: [Double]) -> [Double] { zip(t.dropFirst(), t).map { $0 - $1 } }
            let videoGap = gaps(times.filter { $0 < photoStart - 0.05 }).max() ?? 1, photoGap = gaps(times.filter { $0 >= photoStart }).max() ?? 0
            check(abs(info.duration.seconds - s.duration.seconds) < 0.3 && videoGap < 0.05 && photoGap <= 1.01,
                  "the export has the photo clip; the videos keep their pace (\(String(format: "%.2f", info.duration.seconds)) s, largest gap \(String(format: "%.3f", videoGap)) s in the videos, \(String(format: "%.2f", photoGap)) s on the photo)")
            if let img = try? await FrameGrabber.image(url: URL(fileURLWithPath: out), at: MediaTime(seconds: s.duration.seconds - 2), accuracy: .exact, maxSize: CGSize(width: 64, height: 64)) {
                let px = pixel(img)
                check(px.r > 180 && px.g > 70 && px.g < 140 && px.b < 60, "the photo's own colour is in the exported video (\(px))")
            } else { check(false, "read a frame of the photo clip") }
        } else { check(false, "export with a photo clip (\(res.message))") }
        // The little video gone (another Mac, a cleaned folder): opening the project makes it again from the photo.
        _ = s.saveNow()
        if let p = stillSource?.path { try? fm.removeItem(atPath: p) }
        if let re = try? await EditorSession.openProject(path: path) {
            await waitFor(10) { re.duration.seconds > before + 4 }
            check(re.missingSourceIDs.isEmpty && abs(re.duration.seconds - s.duration.seconds) < 0.2, "reopened without its little video: it is made again from the photo")
            re.close()
        } else { check(false, "reopen with a photo clip") }

        // Playing must not make the library's tiles again (they flickered): also for files used but never brought into the library.
        s.edit("Forget library") { $0.mediaBin = [] }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let shown0 = MediaTile.appeared
        await s.player.seek(to: .zero); s.player.play()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        s.player.pause()
        check(s.project.libraryItems.count >= 3 && MediaTile.appeared == shown0, "playing does not make the library's tiles again (\(MediaTile.appeared - shown0) made again in 2.5 s)")
        s.undo()

        // Export is one button at the top right: it opens the export window; the right panel has no Export tab any more.
        wc.contentController.showExport()
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(wc.contentController.exportSheet != nil && wc.window?.attachedSheet != nil, "the Export button opens the export window")
        check(!InspectorTab.propertyTabs(for: .none).contains(.export), "the right panel has no second Export")
        wc.contentController.closeExport(); try? await Task.sleep(nanoseconds: 300_000_000)
        check(wc.window?.attachedSheet == nil, "Cancel closes it")
        // A frame for social networks: 9:16 with blurred bars is what is exported.
        s.edit("Frame shape") { $0.setFrame(.portrait9x16, fill: .blurredBars) }
        let tallDir = work.appendingPathComponent("ws-tall"); try? fm.createDirectory(at: tallDir, withIntermediateDirectories: true)
        var tallReq = ExportRequest(options: ExportOptions(mode: .exact), folder: tallDir.path, baseName: "tall")
        ExportPreset.hd720.apply(to: &tallReq.options)
        let tall = await runExport(s, env: env, tallReq)
        if let out = tall.path, let v = (try? await MediaProbe.probe(url: URL(fileURLWithPath: out)))?.primaryVideo {
            // The test video is 640 × 360: tall, it is 360 × 640 (never enlarged to 720 wide).
            check(v.width == 360 && v.height == 640, "a 9:16 frame exports a tall video, its short side as the video's (\(v.width) × \(v.height))")
        } else { check(false, "export a 9:16 video (\(tall.message))") }
        s.undo()
        wc.toggleInspector(); try? await Task.sleep(nanoseconds: 400_000_000)
        check(ws.propertiesItem.isCollapsed, "the properties panel can be closed")
        wc.toggleInspector(); try? await Task.sleep(nanoseconds: 400_000_000)
        check(!ws.propertiesItem.isCollapsed, "and opened again")

        // Saved, and read back.
        check(s.saveNow(), "the project is saved")
        if let re = try? await EditorSession.openProject(path: path) {
            check(re.project.mediaBin.count == 4 && re.project.overlays.count == 1 && re.project.soundClips.count == 1 && re.project.timeline.count == 3, "reopened with its library, clips, text and sound")
            re.close()
        } else { check(false, "reopen the project") }
        // The way a real drag carries things: the very item providers the library's tiles hand to the system, poured into a pasteboard as
        // the system does, then dropped. (A drag with the real mouse could not be made here: see the handover report.)
        let filterBoard = await pasteboard(from: [DragPayload.filter(.mono).provider])
        let d8 = tl.testDrop(pasteboard: filterBoard, at: tl.testPoint(track: "main", time: 0.5))
        check(d8 == .clip(s.project.timeline[0].id) && s.project.timeline[0].look.effects.filter == .mono, "a filter tile's own drag data, dropped on clip 1, puts the filter on it")
        let fileBoard = await pasteboard(from: [DragPayload.fileProvider(music.path)])
        let soundsBefore = s.project.soundClips.count
        let d9 = tl.testDrop(pasteboard: fileBoard, at: tl.testPoint(track: "audio", time: 6))
        await waitFor(6) { s.project.soundClips.count == soundsBefore + 1 }
        check(d9 == .audio(6) || s.project.soundClips.count == soundsBefore + 1, "a library tile's own drag data (a file URL), dropped on the sound line, adds the sound")
        let textBoard = await pasteboard(from: [DragPayload.text(.comic).provider])
        check(tl.testDrop(pasteboard: textBoard, at: tl.testPoint(track: "text", time: 2)) == .text(2), "a text style's own drag data lands on the text line")
        filterBoard.releaseGlobally(); fileBoard.releaseGlobally(); textBoard.releaseGlobally()

        let untouched = originals.allSatisfy { (try? Data(contentsOf: $0.key)) == $0.value }
        check(untouched, "the files used are untouched, byte for byte")
        wc.closeVideo(); wc.window?.orderOut(nil)
        env.prefs.toolsPanelHidden = false
    }

    static func writePNG(to url: URL) {
        let w = 200, h = 120
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }

    static func writeTone(to url: URL, seconds: Double) {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)) else { return }
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.3) }
        try? file.write(from: buf)
    }

    /// The colour in the middle of a picture (0–255).
    static func pixel(_ img: CGImage) -> (r: Int, g: Int, b: Int) { pixel(img, fx: 0.5, fy: 0.5) }

    /// A pasteboard filled from item providers the way a drag fills it: every type each provider offers, as data.
    static func pasteboard(from providers: [NSItemProvider]) async -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("MacPlayer.selftest.drag.\(UUID().uuidString)"))
        pb.clearContents()
        var items: [NSPasteboardItem] = []
        for p in providers {
            let item = NSPasteboardItem()
            for t in p.registeredTypeIdentifiers {
                let data: Data? = await withCheckedContinuation { c in _ = p.loadDataRepresentation(forTypeIdentifier: t) { d, _ in c.resume(returning: d) } }
                if let data { item.setData(data, forType: NSPasteboard.PasteboardType(t)) }
            }
            items.append(item)
        }
        pb.writeObjects(items)
        return pb
    }

    /// Flow G3: a photo project in the same kind of window: library (pictures, text, filters) | photo | properties, no timeline.
    static func photoWorkspaceFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G3: a photo project with the library and the properties")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let photo = work.appendingPathComponent("pw-photo.png"); writePNG(to: photo)
        let logo = work.appendingPathComponent("pw-logo.png"); writePNG(to: logo)
        let extra = work.appendingPathComponent("pw-extra.png"); writePNG(to: extra)
        let video = work.appendingPathComponent("pw-video.mp4")
        var spec = SyntheticMedia.Spec(); spec.width = 320; spec.height = 180; spec.seconds = 1; spec.withAudio = false
        try? await SyntheticMedia.generate(to: video, spec: spec)
        let originals = Dictionary(uniqueKeysWithValues: [photo, logo, extra, video].map { ($0, (try? Data(contentsOf: $0)) ?? Data()) })
        let path = work.appendingPathComponent("photo-ws.macplayer").path; try? fm.removeItem(atPath: path)
        guard let s = try? await EditorSession.makeProjectFile(kind: .photo, media: nil, at: path) else { check(false, "make a photo project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let ws = wc.contentController.workspace, let host = wc.contentController.photoHost else { check(false, "the photo editor has its panels"); return }
        check(ws.timeline == nil && !ws.libraryItem.isCollapsed && !ws.propertiesItem.isCollapsed && wc.panelsCollapsed.sidebar, "library and properties around the photo, no timeline")

        await s.place([photo])
        await waitFor(6) { s.photoImage != nil }
        check(s.project.sources.count == 1 && s.photoImage != nil, "the first picture becomes the project's photo")
        await s.place([logo])
        check(s.project.overlayClips.count == 1, "a second picture goes on as a logo")
        check(s.importToLibrary([video, extra]) == 1 && s.project.libraryItems.allSatisfy { $0.kind == .photo }, "a photo project's library takes pictures only")

        // Drops on the photo itself, the way a drag hands them over.
        func drop(_ item: DragPayload) async -> Bool {
            let pb = await pasteboard(from: [item.provider]); defer { pb.releaseGlobally() }
            return host.performDragOperation(TestDraggingInfo(pb: pb, loc: host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil), dest: host.window))
        }
        _ = await drop(.filter(.vintage))
        check(s.project.look.effects.filter == .vintage, "a filter dropped on the photo is put on it")
        _ = await drop(.text(.neon))
        check(s.project.overlays.count == 1 && s.selectedTextID == s.project.overlays.first?.id && s.activeTool == .text, "a text style dropped on the photo adds a text, selected, its settings open")
        _ = await drop(.sticker("🔥"))
        check(s.project.overlays.count == 2, "a sticker dropped on the photo is added")
        _ = await drop(.transition(.dissolve))
        check(s.project.overlays.count == 2 && s.project.look.transitionIn == nil, "a transition has nothing to go on in a photo, and says so")

        wc.contentController.showExport(); try? await Task.sleep(nanoseconds: 300_000_000)
        check(wc.contentController.exportSheet != nil && !InspectorTab.tabs(for: .photo).filter({ $0 != .export }).isEmpty, "Export opens the photo's save window")
        wc.contentController.closeExport(); try? await Task.sleep(nanoseconds: 300_000_000)
        wc.toggleInspector(); try? await Task.sleep(nanoseconds: 300_000_000)
        check(ws.propertiesItem.isCollapsed, "the properties can be closed")
        wc.toggleInspector(); try? await Task.sleep(nanoseconds: 300_000_000)

        check(s.saveNow(), "the photo project is saved")
        if let re = try? await EditorSession.openProject(path: path) {
            check(re.project.overlays.count == 2 && re.project.overlayClips.count == 1 && re.project.look.effects.filter == .vintage && re.project.mediaBin.count >= 2,
                  "reopened with its text, logo, filter and library")
            re.close()
        } else { check(false, "reopen the photo project") }
        check(originals.allSatisfy { (try? Data(contentsOf: $0.key)) == $0.value }, "the pictures used are untouched, byte for byte")
        wc.closeVideo(); wc.window?.orderOut(nil)
        env.prefs.toolsPanelHidden = false
    }
}
