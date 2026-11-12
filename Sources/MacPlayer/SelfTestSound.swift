import AVFoundation
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// Flow G9 (0.16): sounds (songs, recordings) play in a window of their own with their cover, go into playlists and start video projects;
/// animated pictures (GIF, animated PNG, WebP) play, make photo projects saved as animations, and move on a video project's timeline.
/// `MACPLAYER_SOUND_MEDIA=<dir>` adds real files made by ffmpeg (song.mp3 with tags and a cover, plain.m4a, hi.flac, long.mp3, anim.gif,
/// anim.png, anim.webp); without it, a WAV and a GIF are made here.
extension SelfTest {
    static func soundAndAnimationFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G9: sounds and animated pictures: play, playlists, projects")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let media = ProcessInfo.processInfo.environment["MACPLAYER_SOUND_MEDIA"].map { URL(fileURLWithPath: $0) }
        let shots = ProcessInfo.processInfo.environment["MACPLAYER_SHOTS"].map { URL(fileURLWithPath: $0) }
        func copy(_ name: String) -> URL? {
            guard let media, fm.fileExists(atPath: media.appendingPathComponent(name).path) else { return nil }
            let to = work.appendingPathComponent(name)
            try? fm.removeItem(at: to); try? fm.copyItem(at: media.appendingPathComponent(name), to: to)
            return to
        }
        func shoot(_ w: MainWindowController?, _ name: String) {
            guard let shots, let v = w?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
        }
        func soloWindows() -> [MainWindowController] { app.controllers.filter { $0.route == .solo } }
        func openSolo(_ url: URL) async -> MainWindowController? {
            let before = soloWindows()
            app.open(urls: [url])
            await waitFor(12) { soloWindows().contains { w in !before.contains { $0 === w } && w.session != nil } }
            return soloWindows().first { w in !before.contains { $0 === w } && w.session != nil }
        }
        func bytes(_ u: URL) -> Data { (try? Data(contentsOf: u)) ?? Data() }

        // Media: a WAV made here always; the real files when given.
        let wav = work.appendingPathComponent("Made Tone.wav")
        writeStereoTone(to: wav, seconds: 6)
        let song = copy("song.mp3"), plain = copy("plain.m4a"), flac = copy("hi.flac"), long = copy("long.mp3")
        let gif = copy("anim.gif") ?? { let u = work.appendingPathComponent("made.gif"); writeAnimation(to: u, frames: 6); return u }()
        let apng = copy("anim.png"), webp = copy("anim.webp")
        if media == nil { print("INFO  no MACPLAYER_SOUND_MEDIA: the MP3/M4A/FLAC/APNG/WebP checks are skipped") }
        let originals = ([wav, gif] + [song, plain, flac, long, apng, webp].compactMap { $0 }).map { ($0, bytes($0)) }

        // 1. A sound on its own: a window of its own with its cover where the picture would be.
        let first = song ?? wav
        if let w = await openSolo(first), let s = w.session {
            await waitFor(6) { s.player.duration > .zero }
            check(w.route == .solo && s.role == .viewer && s.isSoundOnly, "a sound opened on its own plays in a window of its own (\(first.lastPathComponent))")
            check(w.contentController.soundCover != nil && s.notice == nil, "its cover shows where the picture would be, without a message about missing picture")
            let size = w.contentController.host?.bounds.size ?? .zero
            check(abs(size.width / max(1, size.height) - 16.0 / 9) < 0.05, "the window has a modest wide shape (\(Int(size.width)) × \(Int(size.height)))")
            // Opened on its own (as from Finder), it starts playing by itself (0.16.1). The first sound of a run can take most of a second
            // to start: wait for it, up to 4 s.
            await waitFor(4) { s.player.currentTime.seconds > 0.5 }
            check(s.player.isPlaying && s.player.currentTime.seconds > 0.5, "the sound starts playing by itself (\(String(format: "%.2f", s.player.currentTime.seconds)) s)")
            s.player.pause()
            await waitFor(6) { !s.peaks.isEmpty }
            check(!s.peaks.isEmpty, "its waveform is drawn on the bar under it")
            if song != nil {
                let tags = await AudioCover.info(of: first)
                check(tags.title == "Bài hát thử nghiệm của MacPlayer" && tags.artist == "Nghệ sĩ Thử" && tags.album == "Album 0.16" && tags.artwork != nil,
                      "an MP3's title, artist, album and cover are read (\(tags.title) / \(tags.artist ?? "–"))")
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            shoot(w, "sound-solo")
            _ = w.closeVideo()
        } else { check(false, "a sound opened on its own gets a window") }
        let opus = copy("voice.opus"), vorbis = copy("vorbis.ogg")
        for (u, name) in [(plain, "an AAC .m4a"), (flac, "a 96 kHz FLAC"), (Optional(wav), "a WAV"), (opus, "an Ogg Opus .opus"), (vorbis, "an Ogg Vorbis .ogg")] {
            guard let u, let w = await openSolo(u), let s = w.session else { if u != nil { check(false, "\(name) opens") }; continue }
            await waitFor(6) { s.player.duration > .zero }
            s.player.play(); try? await Task.sleep(nanoseconds: 800_000_000)
            check(s.isSoundOnly && s.player.currentTime.seconds > 0.3 && s.player.failure == nil, "\(name) plays on its own (\(String(format: "%.2f", s.player.currentTime.seconds)) s)")
            s.player.pause()
            if u == plain { shoot(w, "sound-solo-card") }
            _ = w.closeVideo()
        }

        // WMA: macOS cannot read it; it is refused with a reason (the window that would show it is not made).
        if let wma = copy("old.wma") {
            do { _ = try await EditorSession.open(url: wma); check(false, "a WMA file is refused") }
            catch { check(true, "a WMA file is refused with a reason (\((error as? CustomStringConvertible)?.description ?? error.localizedDescription))") }
            check(MediaFiles.kind(of: wma.path) == nil, "WMA files are not taken into playlists")
        }
        // An Ogg sound makes a project too.
        if let opus, let e = await editor(opus, kind: .video) {
            check(e.project.timeline.count == 1 && e.project.source(e.project.timeline[0].sourceID)?.soundOf != nil, "an Opus sound makes a video project")
            e.close()
        }

        check(EditButtonIcon.all.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }, "the Edit button's icons exist on this Mac")

        // 2. Playlists take sounds next to videos and photos.
        let pid = app.playlists.create(name: "Mixed")
        _ = app.playlists.add(urls: [work.appendingPathComponent("demo.mp4"), wav, gif], to: pid)
        let items = app.playlists.playlists.first { $0.id == pid }?.items ?? []
        check(items.count == 3 && items.filter(\.isAudio).count == 1 && items.filter(\.isImage).count == 1, "a playlist takes a sound next to a video and a picture (\(items.count))")
        check(PlaylistSidebar.summary(Playlist(name: "S", items: [PlaylistItem(path: wav.path)])) .hasPrefix(LF("%d sounds", 1)), "a list of sounds says so")

        // 3. A video project made from a sound: one clip, played from a video MacPlayer makes (cover + the sound).
        if let e = await editor(first, kind: .video) {
            let clip = e.project.timeline.first
            let src = clip.flatMap { e.project.source($0.sourceID) }
            check(e.project.timeline.count == 1 && src?.soundOf.map { PathUtil.same($0, first.path) } == true, "a sound makes a video project with the sound as its one clip")
            let length = (clip?.sourceEnd ?? .zero) - (clip?.sourceStart ?? .zero)
            let fileLength = (try? await MediaProbe.probe(url: first))?.duration.seconds ?? 0
            check(abs(length.seconds - fileLength) < 0.1, "the clip is the whole sound (\(String(format: "%.2f", length.seconds)) of \(String(format: "%.2f", fileLength)) s)")
            check(src.map { StillClip.isMade(URL(fileURLWithPath: $0.path)) } == true && src?.mediaPath == first.path, "its video is made in MacPlayer's own folder; the sound is what is shown")
            check(e.infos[src?.id ?? UUID()]?.hasVideo == true && e.infos[src?.id ?? UUID()]?.hasAudio == true, "the made video has a picture and the sound")
            if first.pathExtension.lowercased() == "mp3" {
                check(e.infos[src?.id ?? UUID()]?.audio.first?.codec.lowercased().contains("mp3") == true, "an MP3's sound is copied as it is, not encoded again (\(e.infos[src?.id ?? UUID()]?.audio.first?.codec ?? "–"))")
            }
            check(e.project.mediaBin.contains { PathUtil.same($0.path, first.path) && $0.kind == .audio }, "the sound is in the project's library")
            await waitFor(6) { !(e.peaksBySource[src?.id ?? UUID()] ?? []).isEmpty }
            check(!(e.peaksBySource[src?.id ?? UUID()] ?? []).isEmpty, "the timeline shows the sound's waveform")
            // Shown in a window, with its transport bar and timecode (a cover of 0.2 pictures a second divided the timecode by zero).
            let ew = app.newWindow(show: false)
            ew.setSession(e, fromPlaylist: false)
            ew.window?.orderFront(nil)
            e.player.play(); try? await Task.sleep(nanoseconds: 1_000_000_000)
            check(ew.route == .editor && e.player.currentTime.seconds > 0.4 && e.player.failure == nil, "the project plays in its window (\(String(format: "%.2f", e.player.currentTime.seconds)) s)")
            // The song's title and artist are texts of the project (0.16.2), not words drawn into the cover: they can be typed over.
            let texts = e.project.overlays.filter { !$0.isShape }
            if song != nil {
                check(texts.map(\.text) == ["Bài hát thử nghiệm của MacPlayer", "Nghệ sĩ Thử · Album 0.16"], "the title and artist are texts of the project (\(texts.map(\.text)))")
            } else {
                check(texts.count == 1 && texts.first?.text == first.deletingPathExtension().lastPathComponent, "a song without tags gets its file name as a text")
            }
            check(texts.allSatisfy { $0.start == .zero && abs($0.end.seconds - length.seconds) < 0.05 }, "they last as long as the song")
            ew.window?.makeKeyAndOrderFront(nil)
            e.player.pause(); await e.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 400_000_000)
            if let ev = ew.contentController.host?.elements, let title = texts.first {
                ev.beginTyping(title.id)
                if let field = ev.testTypingField, let tv = field.currentEditor() as? NSTextView {
                    tv.selectAll(nil); tv.insertText("Tên bài mới", replacementRange: tv.selectedRange())
                    _ = ev.control(field, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                    check(e.project.overlays.first { $0.id == title.id }?.text == "Tên bài mới", "the title is typed over right on the picture")
                    e.undo()
                    check(e.project.overlays.first { $0.id == title.id }?.text == title.text, "and one undo puts it back")
                } else {
                    print("INFO  typing on the picture needs the window to have the keyboard (a background run has none); checked through the edit instead")
                    e.edit("Edit text") { p in if let i = p.overlays.firstIndex(where: { $0.id == title.id }) { p.overlays[i].text = "Tên bài mới" } }
                    check(e.project.overlays.first { $0.id == title.id }?.text == "Tên bài mới", "the title can be changed")
                    e.undo()
                }
            }
            shoot(ew, "sound-project-window")
            e.player.pause()
            // Cut in two and faded: the tools of a video clip work on it.
            if let c = clip {
                e.selectedClipIDs = [c.id]
                let at = min(2.37, length.seconds / 2)
                await e.player.seek(to: MediaTime(seconds: at, timescale: 600))
                e.splitAtPlayhead()
                await waitFor(4) { e.project.timeline.count == 2 }
                let cut = e.project.timeline.first.map { ($0.sourceEnd - $0.sourceStart).seconds } ?? 0
                check(e.project.timeline.count == 2 && abs(cut - at) < 0.02, "the sound clip is cut in two right at the playhead (\(String(format: "%.3f", cut)) s, not on a whole second)")
            }
            // Saved as sound only (.m4a), from the made video: the sound comes back.
            if let src, let url = e.sourceURLs[src.id] {
                let out = work.appendingPathComponent("sound-only-\(UUID().uuidString.prefix(4)).m4a")
                do {
                    try await AudioExporter.export(source: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 2)), audio: AudioSettings(), to: out)
                    let info = try await MediaProbe.probe(url: out)
                    check(info.hasAudio && !info.hasVideo && abs(info.duration.seconds - 2) < 0.1, "a part of it is saved as sound only (.m4a, \(String(format: "%.2f", info.duration.seconds)) s)")
                } catch { check(false, "sound-only save: \(error)") }
            }
            // The whole timeline's sound, as in the Export window's "Sound Only (.m4a)".
            e.exportTimelineSound(folder: work.path, name: "whole-sound")
            await waitFor(20) { e.lastSoundExport != nil }
            if let out = e.lastSoundExport, let info = try? await MediaProbe.probe(url: out) {
                let total = e.project.timelineDuration.seconds
                check(info.hasAudio && !info.hasVideo && abs(info.duration.seconds - total) < 0.15, "the whole timeline's sound is saved as an .m4a (\(String(format: "%.2f", info.duration.seconds)) of \(String(format: "%.2f", total)) s)")
            } else { check(false, "the whole timeline's sound is saved as an .m4a") }
            // The made video is gone (another Mac, a cleaned folder): it is made again from the sound when the project opens.
            if let path = e.projectPath, let src {
                _ = e.saveNow()
                try? fm.removeItem(atPath: src.path)
                if let again = try? await EditorSession.openProject(path: path) {
                    check(again.sourceURLs[src.id].map { fm.fileExists(atPath: $0.path) } == true && again.missingSourceIDs.isEmpty, "a missing made video is made again from the sound")
                    again.close()
                } else { check(false, "the project opens again") }
            }
            _ = ew.closeVideo(); ew.window?.close()
            e.close()
        } else { check(false, "a video project can be made from a sound") }

        // An empty video project: the first sound dropped on it starts the timeline; the next goes under the picture as music.
        let dir = env.support.appendingPathComponent("SelfTestProjects", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let empty = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: dir.appendingPathComponent("empty-\(UUID().uuidString.prefix(4)).macplayer").path) {
            await empty.place([wav])
            check(empty.project.timeline.count == 1 && empty.project.source(empty.project.timeline[0].sourceID)?.soundOf != nil, "a sound dropped on an empty video project starts its timeline")
            await empty.place([wav])
            check(empty.project.timeline.count == 1 && empty.project.soundClips.count == 1, "a sound dropped on a project that has clips goes under them as music")
            empty.close()
        }

        // A long sound (3 min): its video is made quickly enough.
        if let long {
            let t0 = Date()
            let made = try? await AudioCover.make(from: long)
            let took = Date().timeIntervalSince(t0)
            let d = made.flatMap { try? AVURLAsset(url: $0).duration.seconds } ?? 0
            check(made != nil && abs(d - 180) < 0.2 && took < 30, "a 3-minute MP3 becomes a clip in \(String(format: "%.1f", took)) s")
        }

        // 4. Animated pictures play on their own, frame after frame.
        for (u, name) in [(Optional(gif), "a GIF"), (apng, "an animated PNG"), (webp, "an animated WebP")] {
            guard let u else { continue }
            guard let w = await openSolo(u), let s = w.session else { check(false, "\(name) opens"); continue }
            await waitFor(6) { s.photoFrames.count > 1 }
            check(s.isPhoto && (s.photoAnimation?.frameCount ?? 0) > 1 && s.photoFrames.count == s.photoAnimation?.frameCount && s.photoPlaying,
                  "\(name) plays its \(s.photoAnimation?.frameCount ?? 0) frames on its own")
            if u == gif { try? await Task.sleep(nanoseconds: 400_000_000); shoot(w, "anim-solo") }
            _ = w.closeVideo()
        }

        // 5. A photo project of an animation saves it as one: an animated PNG stays a PNG, a GIF stays a GIF.
        if let apng, let p = await editor(apng, kind: .photo) {
            await waitFor(6) { p.photoFrames.count > 1 }
            check(p.photoDraft.options.format == .png, "a photo project of an animated PNG saves an animated PNG by default")
            p.close()
        }
        if let p = await editor(gif, kind: .photo) {
            await waitFor(6) { p.photoFrames.count > 1 }
            check(p.photoDraft.options.format == .gif, "a photo project of a GIF saves a GIF by default")
            p.close()
        }

        // 6. A video project of an animation: the animation moves on the timeline.
        if let v = await editor(gif, kind: .video), let c = v.project.timeline.first, let src = v.project.source(c.sourceID), let url = v.sourceURLs[src.id] {
            let a = PhotoLoader.animation(url: gif)
            check(src.stillOf.map { PathUtil.same($0, gif.path) } == true, "an animation makes a video project with it as its clip")
            let len = (c.sourceEnd - c.sourceStart).seconds
            check(abs(len - StillClip.defaultLength(for: gif)) < 0.05 && len >= (a?.duration ?? 0) - 0.05, "its clip is the whole animation at least (\(String(format: "%.2f", len)) s)")
            let f1 = try? await FrameGrabber.image(url: url, at: MediaTime(seconds: 0.05, timescale: 600), accuracy: .exact)
            let f2 = try? await FrameGrabber.image(url: url, at: MediaTime(seconds: (a?.duration ?? 1) / 2, timescale: 600), accuracy: .exact)
            check(f1 != nil && f2 != nil && !sameImage(f1!, f2!), "the picture changes along the clip (it moves)")
            // The same animation as a layer over it: a moving, see-through video layer.
            await v.addOverlayPicture(gif, at: .zero, lane: 0)
            let layer = v.project.overlayClips.last
            let lsrc = layer?.sourceID.flatMap { v.project.source($0) }
            check(layer?.isVideo == true && lsrc?.path.hasSuffix(".alpha.mov") == true && lsrc?.stillOf.map { PathUtil.same($0, gif.path) } == true,
                  "an animation dropped on a layer line becomes a moving layer")
            check((layer?.duration.seconds ?? 0) >= min(5, v.project.timelineDuration.seconds) - 0.05, "it lasts 5 seconds or to the end of the video (\(String(format: "%.2f", layer?.duration.seconds ?? 0)) s)")
            let still = work.appendingPathComponent("logo.png"); writeSolidPNG(to: still, r: 1, g: 1, b: 1, w: 64, h: 64)
            await v.addOverlayPicture(still, at: .zero, lane: 1)
            if case .image? = v.project.overlayClips.last?.kind { check(true, "a still picture stays a picture layer") } else { check(false, "a still picture stays a picture layer") }
            v.close()
        } else { check(false, "a video project can be made from an animation") }

        // Real songs (copies), when given: `MACPLAYER_REAL_SOUNDS=<dir>`. Each plays on its own and makes a project that plays near its end.
        if let dir = ProcessInfo.processInfo.environment["MACPLAYER_REAL_SOUNDS"] {
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { AudioFiles.isCandidate($0) }.sorted().map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
            for u in files {
                let before = bytes(u)
                let length = (try? await MediaProbe.probe(url: u))?.duration.seconds ?? 0
                if let w = await openSolo(u), let s = w.session {
                    await waitFor(8) { s.player.duration > .zero }
                    await s.player.seek(to: MediaTime(seconds: length * 0.9, timescale: 600))
                    s.player.play(); try? await Task.sleep(nanoseconds: 800_000_000)
                    let at = s.player.currentTime.seconds
                    check(s.isSoundOnly && at > length * 0.9 + 0.3 && s.player.failure == nil, "real song plays on its own near its end (\(String(format: "%.1f", at)) of \(String(format: "%.0f", length)) s): \(u.lastPathComponent.prefix(40))")
                    s.player.pause()
                    if u == files.first { try? await Task.sleep(nanoseconds: 500_000_000); shoot(w, "real-solo") }
                    _ = w.closeVideo()
                }
                let t0 = Date()
                if let e = await editor(u, kind: .video), let c = e.project.timeline.first {
                    let took = Date().timeIntervalSince(t0)
                    check(abs((c.sourceEnd - c.sourceStart).seconds - length) < 0.2 && took < 30, "real song makes a project in \(String(format: "%.1f", took)) s, clip as long as the song")
                    await e.player.seek(to: MediaTime(seconds: max(0, length - 3), timescale: 600))
                    e.player.play(); try? await Task.sleep(nanoseconds: 800_000_000)
                    check(e.player.currentTime.seconds > length - 2.9 && e.player.failure == nil, "its project plays near the end (\(String(format: "%.1f", e.player.currentTime.seconds)) s)")
                    e.player.pause(); e.close()
                } else { check(false, "real song makes a project: \(u.lastPathComponent)") }
                check(bytes(u) == before, "the real song is unchanged")
            }
        }

        // The files were only read.
        check(originals.allSatisfy { bytes($0.0) == $0.1 }, "every sound and picture used is unchanged")
    }

    /// A 440 Hz tone, stereo, as a WAV.
    static func writeStereoTone(to url: URL, seconds: Double) {
        let rate = 44_100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16],
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)) else { return }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let v = Float(0.4 * sin(2 * .pi * 440 * Double(i) / rate))
            buffer.floatChannelData![0][i] = v; buffer.floatChannelData![1][i] = v
        }
        try? file.write(from: buffer)
    }

    /// A GIF of `frames` frames of different colours, a tenth of a second each.
    static func writeAnimation(to url: URL, frames: Int) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            guard let ctx = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let h = Double(i) / Double(frames)
            ctx.setFillColor(CGColor(red: h, green: 1 - h, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            if let img = ctx.makeImage() { CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
        }
        CGImageDestinationFinalize(dest)
    }

    /// Whether two frames look the same (a few samples).
    static func sameImage(_ a: CGImage, _ b: CGImage) -> Bool {
        func px(_ i: CGImage) -> [UInt8] {
            guard let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            guard let d = ctx.data else { return [] }
            return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self), count: 16 * 16 * 4))
        }
        let x = px(a), y = px(b)
        guard x.count == y.count, !x.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / x.count < 3
    }
}
