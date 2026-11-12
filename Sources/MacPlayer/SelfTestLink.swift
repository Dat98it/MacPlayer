import AppKit
import MacPlayerCore
import MacPlayerMedia

/// Flow G8 (0.15): one file opened on its own plays in a window without playlists; videos, streams and photos open from web links.
/// The link part needs a test server (`MACPLAYER_LINK_BASE=http://127.0.0.1:<port>`, see docs) and is skipped without one.
extension SelfTest {
    static func soloAndLinkFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G8: one file in a window of its own; videos, streams and photos from links")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let demo = work.appendingPathComponent("demo.mp4")
        let photo = work.appendingPathComponent("solo-photo.png"); writeSolidPNG(to: photo, r: 0.9, g: 0.5, b: 0.1, w: 1200, h: 800)
        let shots = ProcessInfo.processInfo.environment["MACPLAYER_SHOTS"].map { URL(fileURLWithPath: $0) }

        func soloWindows() -> [MainWindowController] { app.controllers.filter { $0.route == .solo } }
        func shoot(_ w: MainWindowController?, _ name: String) {
            guard let shots, let v = w?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name + ".png"))
        }
        func newSolo(after before: [MainWindowController], _ timeout: Double = 12) async -> MainWindowController? {
            await waitFor(timeout) { soloWindows().contains { w in !before.contains { $0 === w } && w.session != nil } }
            return soloWindows().first { w in !before.contains { $0 === w } && w.session != nil }
        }

        // A playlists window is open; a video opened from Finder must not land in it.
        let lists = app.newWindow(); lists.go(to: .playlist)
        var before = soloWindows()
        app.open(urls: [demo])
        guard let w = await newSolo(after: before), let s = w.session else { check(false, "a file opened on its own gets a window"); return }
        await waitFor(6) { s.player.duration > .zero }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(w !== lists && lists.route == .playlist && lists.session == nil, "the playlists window is left as it was")
        check(w.route == .solo && w.panelsCollapsed.sidebar && w.panelsCollapsed.inspector, "the file plays without the playlists panel")
        check(w.contentController.headerKind == "solo", "its bar is the one for a file on its own (no playlist buttons)")
        check(w.window?.minSize == MainWindowController.soloMinimum, "the window may be small")
        check(w.window?.frameAutosaveName == "", "it does not take over the main window's remembered size")
        if let host = w.contentController.host {
            let a = host.bounds.width / max(1, host.bounds.height)
            let v = Double(s.info?.primaryVideo.map { Double($0.width) / Double($0.height) } ?? 16.0 / 9)
            check(abs(a - v) / v < 0.04, "the window takes the video's shape (\(String(format: "%.3f", a)) vs \(String(format: "%.3f", v)))")
        } else { check(false, "the picture area") }
        if let item = app.allMenuItems.first(where: { $0.action == #selector(AppDelegate.toggleSidebar(_:)) }) {
            check(!app.validateMenuItem(item) || app.active !== w, "View ▸ Show / Hide Playlists does nothing here")
        }
        // As from Finder: it starts playing by itself (0.16.1), without a click on Play.
        await waitFor(4) { s.player.currentTime.seconds > 0.4 }
        check(s.player.isPlaying && s.player.currentTime.seconds > 0.4, "it starts playing by itself (\(String(format: "%.2f", s.player.currentTime.seconds)) s)")
        s.player.pause()
        shoot(w, "solo-video")

        // A second file: a window of its own as well.
        before = soloWindows()
        app.open(urls: [photo])
        let pw = await newSolo(after: before)
        check(pw != nil && pw !== w && pw?.session?.isPhoto == true && pw?.route == .solo, "a photo opened on its own gets a window of its own too")
        if let pw { await waitFor(4) { pw.session?.photoImage != nil }; check(pw.contentController.headerKind == "solo", "the photo has the same bar"); shoot(pw, "solo-photo") }
        // Going Home from a small window of its own: the window grows to the start screen's minimum.
        if let pw, let ps = pw.session {
            pw.fitToPicture(ps, media: CGSize(width: 640, height: 360))
            pw.go(to: .home)
            let size = pw.window?.contentView?.bounds.size ?? .zero
            check(pw.route == .home && size.width >= 899 && size.height >= 559, "a small window going Home grows to the start screen's size (\(Int(size.width)) × \(Int(size.height)))")
        }
        // Closing the file closes its window, and nothing else.
        check(w.closeVideo() == true, "Close Video in a window of its own")
        await waitFor(2) { !app.controllers.contains { $0 === w } }
        check(!app.controllers.contains { $0 === w } && w.window?.isVisible != true, "the window goes with its file")
        check(app.controllers.contains { $0 === lists } && lists.route == .playlist, "the playlists window stays")
        pw?.window?.close(); lists.window?.close()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // The link is pasted right into the field (⌘V goes to the field, which has the keyboard when the window opens); there is
        // no separate Paste button. The person's clipboard is put back afterwards.
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
        pb.clearContents(); pb.setString("hello", forType: .string)        // not a link: the field opens empty
        LinkPanel.shared.show()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let m = LinkPanel.shared.model {
            check(m.text.isEmpty, "the Open Link window opens with an empty field when the clipboard holds no link")
            let editor = LinkPanel.shared.fieldEditor
            check(editor != nil, "the link field has the keyboard as soon as the window opens")
            // Edit ▸ Cut/Copy/Paste/Select All, Close and Minimize go to what has the keyboard. (Until 0.15.2 they went to the app
            // delegate, which cannot paste: ⌘V did nothing in any field, and a test that called the field's paste directly missed it.)
            for sel in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
                        #selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:))] {
                let item = app.allMenuItems.first { $0.action == sel }
                check(item != nil && item?.target == nil, "\(item?.title ?? NSStringFromSelector(sel)) goes to what has the keyboard")
            }
            pb.clearContents(); pb.setString("  \"https://example.com/clips/Đà Lạt.mp4\" \nsecond line\n", forType: .string)
            // ⌘V as the keyboard sends it: through the main menu, to the window that has the keyboard.
            NSApp.activate(ignoringOtherApps: true)
            LinkPanel.shared.panelWindow?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let paste = app.allMenuItems.first { $0.action == #selector(NSText.paste(_:)) }
            // A menu item without a target goes to the key window's first responder. A test run in the background may have no key
            // window; then the item is sent along that window's own responder chain, as AppKit would.
            let isKey = NSApp.keyWindow === LinkPanel.shared.panelWindow
            func sendMenu(_ item: NSMenuItem?) {
                guard let item, let a = item.action else { return }
                if isKey, let w = LinkPanel.shared.panelWindow, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                                     windowNumber: w.windowNumber, context: nil, characters: item.keyEquivalent, charactersIgnoringModifiers: item.keyEquivalent, isARepeat: false, keyCode: item.keyEquivalent == "v" ? 9 : 0) {
                    _ = NSApp.mainMenu?.performKeyEquivalent(with: e)
                } else if item.target == nil {
                    _ = LinkPanel.shared.panelWindow?.firstResponder?.tryToPerform(a, with: item)
                } else { NSApp.sendAction(a, to: item.target, from: item) }
            }
            if isKey {
                let receiver = paste.flatMap { NSApp.target(forAction: $0.action!, to: $0.target, from: $0) } as AnyObject?
                check(receiver === editor && editor != nil, "Edit ▸ Paste (⌘V) reaches the link field (\(receiver.map { String(describing: type(of: $0)) } ?? "nothing"))")
            } else { print("INFO  the app is in the background: ⌘V is sent along the window's responder chain instead of the key window's") }
            sendMenu(paste)
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(m.text == "\"https://example.com/clips/Đà Lạt.mp4\"", "⌘V through the menu pastes into the field, first line only, spaces trimmed (\(m.text))")
            check(m.canOpen && m.pasted == false, "the pasted link can be opened")
            // Pasting again over a selected link replaces it.
            sendMenu(app.allMenuItems.first { $0.action == #selector(NSText.selectAll(_:)) })
            pb.clearContents(); pb.setString("https://example.com/b.m3u8", forType: .string)
            sendMenu(paste)
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(m.text == "https://example.com/b.m3u8", "⌘A then ⌘V (through the menu) replaces the link (\(m.text))")
            if let shots, let v = LinkPanel.shared.panelWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                m.text = ""
                try? await Task.sleep(nanoseconds: 300_000_000)
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("open-link-empty.png"))
            }
        } else { check(false, "the Open Link window opens") }
        LinkPanel.shared.close()
        pb.clearContents()
        for item in saved { let i = NSPasteboardItem(); for (t, d) in item { i.setData(d, forType: t) }; pb.writeObjects([i]) }

        // MARK: Links
        guard let base = ProcessInfo.processInfo.environment["MACPLAYER_LINK_BASE"] else { print("SKIP  links: no MACPLAYER_LINK_BASE test server"); return }
        LinkFetcher.clearCache()
        env.prefs.recentLinks = []
        let positionsBefore = env.positions.count

        /// Opens a link through the Open Link window as a person would (types it, presses Open). Returns the window it plays in,
        /// or the message the window shows.
        func openLink(_ path: String, _ timeout: Double = 15) async -> (MainWindowController?, String?) {
            let link = path.hasPrefix("http") ? path : base + path
            let before = soloWindows()
            LinkPanel.shared.show(text: link)
            guard let m = LinkPanel.shared.model else { return (nil, "no panel") }
            m.text = link
            guard m.canOpen else { return (nil, "cannot open: \(m.verdict)") }
            m.open()
            await waitFor(timeout) { !m.opening && (m.error != nil || soloWindows().contains { w in !before.contains { $0 === w } }) }
            if let e = m.error { return (nil, e) }
            return (await newSolo(after: before, 2), nil)
        }

        // Sounds (0.16): an MP3 and an Opus by name, a FLAC the server only calls "some bytes" (known from its first bytes). They play
        // with their cover in the picture's place. Run only when the server has them (`song.mp3`, `voice.opus`, `hi.flac` in its folder).
        for (path, name) in [("/song.mp3", "an MP3 link"), ("/voice.opus", "an Opus link"), ("/soundnoext", "a sound link without a name")] {
            let (sw, serr) = await openLink(path)
            if serr?.contains("404") == true || serr?.lowercased().contains("not found") == true { print("SKIP  \(name): not on the test server"); continue }
            guard let sw, let ss = sw.session else { check(false, "\(name) opens (\(serr ?? "no window"))"); continue }
            await waitFor(10) { ss.player.isReady && ss.player.duration > .zero }
            ss.player.play(); await waitFor(5) { ss.player.currentTime.seconds > 0.5 }
            check(ss.isSoundOnly && sw.contentController.soundCover != nil && ss.player.currentTime.seconds > 0.5 && ss.player.failure == nil,
                  "\(name) plays with its cover (\(String(format: "%.2f", ss.player.currentTime.seconds)) s)")
            ss.player.pause()
            _ = sw.closeVideo()
        }

        // A video file.
        let (vw, verr) = await openLink("/clip.mp4")
        if let vw, let vs = vw.session {
            await waitFor(10) { vs.player.isReady && vs.player.duration > .zero }
            check(vs.remote?.kind == .video && vs.remote?.byteCount == 3_560_749, "a video link is a video, its size from the server")
            check(vs.player.isReady && abs(vs.player.duration.seconds - 20) < 0.5, "it connects and knows its length (\(String(format: "%.2f", vs.player.duration.seconds)) s)")
            await waitFor(4) { vs.info?.primaryVideo?.width == 640 }
            check(vs.info?.primaryVideo?.width == 640 && vs.info?.primaryVideo?.height == 360, "its picture size arrives as it plays")
            check(!LinkPanel.shared.isOpen, "the Open Link window closes")
            check(vw.window?.title == "clip" && vw.window?.subtitle == "127.0.0.1", "the window is named after the link (\(vw.window?.title ?? "") — \(vw.window?.subtitle ?? ""))")
            check(vs.localFileURL == nil, "a link is not a file of the person's")
            vs.refreshSourceState()
            check(vs.notice == nil, "no 'file is no longer at its location' warning for a link (\(vs.notice?.text ?? ""))")
            for sel in [#selector(AppDelegate.renameCurrentFile(_:)), #selector(AppDelegate.trashCurrentFile(_:)), #selector(AppDelegate.editCurrentFile(_:))] {
                if let item = app.allMenuItems.first(where: { $0.action == sel }) { vw.window?.makeKey(); check(!app.validateMenuItem(item) || app.active !== vw, "\(item.title) is off for a link") }
            }
            await waitFor(5) { vs.player.currentTime.seconds > 1 }
            check(vs.player.currentTime.seconds > 1, "it plays from the link (\(String(format: "%.2f", vs.player.currentTime.seconds)) s)")
            await vs.player.seek(to: MediaTime(seconds: 15))
            check(abs(vs.player.currentTime.seconds - 15) < 0.2, "it can be moved to any time (\(String(format: "%.2f", vs.player.currentTime.seconds)) s)")
            check(env.prefs.recentLinks.first == base + "/clip.mp4", "the link is in Recent Links")
            vs.rememberPosition()
            check(env.positions.count == positionsBefore, "no 'where I stopped' is kept for a link")
            let host = vw.contentController.host
            check(host.map { abs($0.bounds.width / max(1, $0.bounds.height) - 16.0 / 9) < 0.08 } == true, "the window takes the link's picture shape")
            shoot(vw, "link-video")
            // Download, then watch the downloaded file instead.
            let dest = work.appendingPathComponent("dl clip.mp4")
            if let r = vs.remote { vs.linkSave.start(r, to: dest) }
            await waitFor(20) { if case .saved = vs.linkSave.state { return true }; if case .failed = vs.linkSave.state { return true }; return false }
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
            check(vs.linkSave.state == .saved(dest) && size == 3_560_749, "Download saves the whole file (\(size) bytes)")
            check(!fm.fileExists(atPath: work.appendingPathComponent(".dl clip.mp4.download").path), "no half file is left")
            shoot(vw, "link-downloaded")
            LinkActions.openSaved(dest, replacing: vs)
            await waitFor(6) { vw.session !== vs && vw.session?.localFileURL?.path == dest.path }
            check(vw.session?.localFileURL?.path == dest.path && vw.route == .solo, "Open shows the downloaded file in the same window, now as a file")
            vw.window?.close()
        } else { check(false, "a video link opens (\(verr ?? "no window"))") }

        // A file with no extension: the server says it is a video. Another says only "some bytes".
        for (path, what) in [("/noext", "a link without extension (video/mp4)"), ("/octet", "a link the server calls application/octet-stream"), ("/headless.mp4", "a server that refuses HEAD")] {
            let (w2, e2) = await openLink(path)
            if let w2, let s2 = w2.session {
                await waitFor(10) { s2.player.isReady || s2.player.failure != nil }
                check(s2.player.isReady && s2.remote?.kind == .video, "\(what) plays")
                w2.window?.close()
            } else { check(false, "\(what) opens (\(e2 ?? "no window"))") }
        }

        // A slow server: it still opens and plays (the spinner shows while it waits). A server that drops the connection part way:
        // the app neither hangs nor crashes; the player either recovers or says why.
        let (sw, serr) = await openLink("/slow.mp4")
        if let sw, let ss = sw.session {
            await waitFor(15) { ss.player.currentTime.seconds > 0.5 || ss.player.failure != nil }
            check(ss.player.currentTime.seconds > 0.5 && ss.player.failure == nil, "a slow server still plays (\(String(format: "%.2f", ss.player.currentTime.seconds)) s)")
            sw.window?.close()
        } else { check(false, "a slow link opens (\(serr ?? "no window"))") }
        let stall = PlayerController.stallTimeout
        PlayerController.stallTimeout = 5
        // A server that hangs up after each 400 KB: the player gets the file bit by bit; it must keep going or say why, never hang.
        let (pw2, perr2) = await openLink("/drop.mp4")
        if let pw2, let ps2 = pw2.session {
            let t0 = ps2.player.currentTime.seconds
            await waitFor(15) { ps2.player.failure != nil || ps2.player.currentTime.seconds > t0 + 2 }
            check(ps2.player.failure != nil || ps2.player.currentTime.seconds > t0 + 2, "a server that keeps hanging up: it plays on or says why (\(ps2.player.failure ?? String(format: "%.2f s", ps2.player.currentTime.seconds)))")
            pw2.window?.close()
        } else { check(false, "the hanging-up link opens (\(perr2 ?? "no window"))") }
        let (dw, derr) = await openLink("/stall.mp4")
        if let dw, let ds = dw.session {
            // The server sends the first 300 KB and then nothing more: what arrived plays, then the spinner would turn for ever.
            await waitFor(25) { ds.player.failure != nil }
            print("INFO  a dropped connection: \(ds.player.failure ?? "no message"), stopped at \(String(format: "%.2f", ds.player.currentTime.seconds)) s")
            check(ds.player.failure == L("The link stopped sending data. The server may have closed the connection, or the network is too slow."),
                  "a connection that stops sending ends in a clear message (with Try Again), not an endless spinner")
            check(!ds.player.isPlaying || ds.player.failure == nil, "a stopped link is paused")
            if ds.player.failure != nil {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let h = dw.window?.contentView?.bounds.height ?? 0
                check(h < 700, "the message does not stretch the window (\(Int(h)) points high)")
                shoot(dw, "link-failed")
                await ds.retryRemote()
                check(ds.player.failure == nil, "Try Again starts over")
            }
            dw.window?.close()
        } else { check(false, "the dropping link opens (\(derr ?? "no window"))") }
        PlayerController.stallTimeout = stall

        // A stream (HLS, not live): plays, cannot be downloaded.
        let (hw, herr) = await openLink("/hls/index.m3u8")
        if let hw, let hs = hw.session {
            await waitFor(10) { hs.player.isReady }
            check(hs.remote?.kind == .stream && hs.remote?.canSave == false, "an .m3u8 link is a stream, which cannot be downloaded")
            check(hs.player.isReady && !hs.player.isLive && abs(hs.player.duration.seconds - 20) < 1, "a recorded stream knows its length (\(String(format: "%.1f", hs.player.duration.seconds)) s)")
            await waitFor(6) { hs.player.currentTime.seconds > 1 }
            check(hs.player.currentTime.seconds > 1, "the stream plays")
            check(hw.contentController.timelineHeightValue == 70, "a recorded stream keeps its timeline")
            shoot(hw, "link-stream")
            hw.window?.close()
        } else { check(false, "a stream link opens (\(herr ?? "no window"))") }

        // A live stream (made by the test script with ffmpeg, if it is running).
        if ProcessInfo.processInfo.environment["MACPLAYER_LINK_LIVE"] != nil {
            let (lw, lerr) = await openLink("/live/index.m3u8")
            if let lw, let ls = lw.session {
                await waitFor(12) { ls.player.isReady }
                check(ls.player.isLive, "a live stream is taken as live")
                ls.refreshSourceState()
                check(ls.notice == nil, "no warning about a missing file for a stream (\(ls.notice?.text ?? ""))")
                await waitFor(2) { lw.contentController.timelineHeightValue == 0 }
                check(lw.contentController.timelineHeightValue == 0, "a live stream has no timeline to move along")
                check(ls.mediaSummary.contains(L("Live stream")), "its bar says it is live")
                shoot(lw, "link-live")
                lw.window?.close()
            } else { check(false, "a live stream opens (\(lerr ?? "no window"))") }
        }

        // A photo (its name has accents and a space).
        let (fw, ferr) = await openLink("/s%C3%A2n%20b%C3%B3ng.jpg")
        if let fw, let fs = fw.session {
            await waitFor(4) { fs.photoImage != nil }
            check(fs.isPhoto && fs.remote?.kind == .photo && fs.photoImage != nil, "a photo link is shown as a photo")
            check(fw.window?.title == "sân bóng", "its name is read back with its accents (\(fw.window?.title ?? ""))")
            let cached = fs.sourceURL
            check(cached.map { $0.path.hasPrefix(LinkFetcher.cacheFolder.path) && fm.fileExists(atPath: $0.path) } == true, "the photo is kept in the app's cache while shown")
            check(fw.contentController.headerKind == "solo", "with the same bar")
            shoot(fw, "link-photo")
            fw.window?.close()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(cached.map { !fm.fileExists(atPath: $0.path) } == true, "and removed when the window closes")
        } else { check(false, "a photo link opens (\(ferr ?? "no window"))") }

        // What cannot be opened is said in the Open Link window, which stays open.
        for (path, expect, what) in [("/missing.mp4", "404", "a link to nothing (404)"), ("/forbidden.mp4", "403", "a forbidden link (403)"),
                                     ("/watch", L("web page"), "a link to a web page"), ("/fake.mp4", L("web page"), "a .mp4 link that is really a web page"),
                                     ("http://127.0.0.1:9/clip.mp4", "", "a server that is not there")] {
            let before = soloWindows().count
            let (w3, e3) = await openLink(path)
            check(w3 == nil && soloWindows().count == before && e3 != nil && (expect.isEmpty || e3!.contains(expect)), "\(what): no window, a clear message (\(e3 ?? "none"))")
            check(LinkPanel.shared.isOpen, "the Open Link window stays open to fix the link")
        }
        if let m = LinkPanel.shared.model {
            m.text = "https://www.youtube.com/watch?v=abc"
            check(!m.canOpen && m.verdict == .page(.youtube), "a YouTube page cannot be opened, and says why")
            m.text = "https://example.com/film.mkv"
            check(!m.canOpen, "an MKV link cannot be opened")
        }
        LinkPanel.shared.close()
        if let m = LinkPanel.shared.model { check(false, "the Open Link window closed (\(m.text))") }
        // Snapshot of the window itself, with a link typed in.
        LinkPanel.shared.show(text: base + "/clip.mp4")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let pw = LinkPanel.shared.panelWindow, let v = pw.contentView {
            let wanted = pw.contentViewController?.view.fittingSize.height ?? 0
            check(v.bounds.height + 1 >= wanted, "the Open Link window is tall enough for what it shows (\(Int(v.bounds.height)) of \(Int(wanted)))")
        }
        if let shots, let v = LinkPanel.shared.panelWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("open-link.png"))
        }
        if let m = LinkPanel.shared.model {
            m.text = "https://www.facebook.com/watch/?v=1"
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let shots, let v = LinkPanel.shared.panelWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("open-link-page.png"))
            }
        }
        LinkPanel.shared.close()
        env.prefs.recentLinks = []
    }
}
