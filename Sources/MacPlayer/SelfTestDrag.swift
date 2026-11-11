import AppKit
import MacPlayerCore
import MacPlayerMedia

/// Flow G7: how smooth a drag on the picture is. Mouse events go to the frames on the picture as a person's would, one per display frame;
/// measured: the main thread's time per event, the work it sets off afterwards, and whether the frame drawn is where the mouse is.
extension SelfTest {
    static func dragSmoothnessFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G7: dragging on the picture is smooth and the frame keeps up")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let black = work.appendingPathComponent("dr-black.png"); writeSolidPNG(to: black, r: 0, g: 0, b: 0, w: 1280, h: 720)
        let logo = work.appendingPathComponent("dr-logo.png"); writeSolidPNG(to: logo, r: 0.1, g: 0.4, b: 1, w: 200, h: 200)
        let path = work.appendingPathComponent("drag.macplayer").path; try? fm.removeItem(atPath: path)
        let real = ProcessInfo.processInfo.environment["MACPLAYER_DRAG_PROJECT"].flatMap { $0.isEmpty ? nil : $0 }
        if let real { try? fm.copyItem(atPath: real, toPath: path) }
        guard let s = real != nil ? try? await EditorSession.openProject(path: path) : try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "a project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        if real == nil { await s.place([black]) }
        await waitFor(15) { s.duration.seconds > 2 && s.previewHasCompositor || s.duration.seconds > 2 }
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 600_000_000)
        // A few things on the picture, as in a real edit.
        for (i, t) in [TextTemplate.classic, .neon, .headline, .subtitleBox].enumerated() { s.addText(t, at: MediaTime(seconds: 0.5), position: CGPoint(x: 0.2 + 0.2 * Double(i), y: 0.2)) }
        for k in [ShapeKind.star, .heart, .speechBubble] { s.addShape(k, at: MediaTime(seconds: 0.5), position: CGPoint(x: 0.3, y: 0.7)) }
        await s.addOverlayPicture(logo, at: MediaTime(seconds: 0.5), center: CGPoint(x: 0.8, y: 0.7))
        s.select(.none)
        _ = s.saveNow()                       // the autosave of the setup is done before the drag (its "saved" would count as a redraw)
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let host = wc.contentController.host, let win = wc.window else { check(false, "the picture area"); return }
        let ev = host.elements
        let added = s.project.overlays.suffix(7)
        guard added.count == 7 else { check(false, "the texts were added"); return }
        let target = added[added.endIndex - 1]      // the top one (a wide text may lie over another)
        guard let f0 = ev.testFrame(of: target.id) else { check(false, "the text has a frame"); return }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let e = mouse(type, ev.convert(p, to: nil), win, [.option])
            switch type { case .leftMouseDown: ev.mouseDown(with: e); case .leftMouseDragged: ev.mouseDragged(with: e); default: ev.mouseUp(with: e) }
        }
        // 90 moves, one per 1/60 s, the time each takes on the main thread, and how far the drawn frame is from the mouse after it.
        var times: [Double] = [], misses: [CGFloat] = [], liftMisses: [CGFloat] = []
        var liftF0: CGRect?
        let lifts0 = s.liftRefreshes

        let refreshes0 = PlayerHostView.layouts
        _ = refreshes0
        let watchStart = ProcessInfo.processInfo.systemUptime
        send(.leftMouseDown, CGPoint(x: f0.midX, y: f0.midY))
        // Counted from the first move: the press itself selects the text (a redraw, once).
        try? await Task.sleep(nanoseconds: 100_000_000)
        var panelRedraws = 0
        let sub = s.objectWillChange.sink { _ in panelRedraws += 1 }
        let stripDraws0 = wc.contentController.timeline?.draws ?? 0
        let frames0 = s.frameRefreshes, drawn0 = CompositorStats.framesDrawn
        var drawTimes: [Double] = []; var lastDrawn = CompositorStats.framesDrawn
        // 30% of the picture's width in all (a portrait picture is narrow; further would reach its edge, where things stop).
        let picW = host.displayedPicture().width, step = picW * 0.3 / 90
        print(String(format: "   the picture is %.0f × %.0f pt on screen", picW, host.displayedPicture().height))
        for i in 1...90 {
            let p = CGPoint(x: f0.midX + CGFloat(i) * step, y: f0.midY + CGFloat(i % 30) * 1.2)
            let t0 = ProcessInfo.processInfo.systemUptime
            send(.leftMouseDragged, p)
            times.append(ProcessInfo.processInfo.systemUptime - t0)
            if let f = ev.testFrame(of: target.id) { misses.append(hypot(f.midX - p.x, f.midY - p.y)) }
            // The picture shown while dragging: it moves exactly as far as the mouse.
            if let lf = ev.testLiftFrame(of: target.id) {
                if liftF0 == nil { liftF0 = lf.offsetBy(dx: -(p.x - f0.midX), dy: -(p.y - f0.midY)) }
                if let a = liftF0 { liftMisses.append(hypot(lf.midX - a.midX - (p.x - f0.midX), lf.midY - a.midY - (p.y - f0.midY))) } else { liftMisses.append(99) }
            } else { liftMisses.append(99) }
            try? await Task.sleep(nanoseconds: 16_000_000)
            if CompositorStats.framesDrawn != lastDrawn { lastDrawn = CompositorStats.framesDrawn; drawTimes.append(CompositorStats.lastRequestUptime) }
        }
        let drawn = CompositorStats.framesDrawn - drawn0
        let gaps = zip(drawTimes.dropFirst(), drawTimes).map { $0 - $1 }.sorted()
        print(String(format: "   the compositor actually drew %d frames while moving; gap between them median %.0f ms, worst %.0f ms", drawn, (gaps.isEmpty ? 0 : gaps[gaps.count/2]) * 1000, (gaps.last ?? 0) * 1000))
        sub.cancel()
        let stripDraws = (wc.contentController.timeline?.draws ?? 0) - stripDraws0, frames = s.frameRefreshes - frames0
        print("   while dragging: panels asked to redraw \(panelRedraws) times, timeline drawn \(stripDraws) times, the player asked for \(frames) frames")
        check(panelRedraws == 0 && stripDraws <= 1, "dragging does not redraw the panels or the timeline at every move (\(panelRedraws), \(stripDraws))")
        check(s.liftRefreshes - lifts0 == 1 && frames == 0, "the dragged text is lifted off the preview once; the player draws no frame while it moves (\(s.liftRefreshes - lifts0) lift, \(frames) frames)")
        check(ev.testLifted == [target.id], "what is dragged is drawn over the picture (lifted \(ev.testLifted.count), the target among them: \(ev.testLifted.contains(target.id)); selected \(s.selectedTextID == target.id))")
        print(String(format: "   the dragged picture is off the mouse by %.2f pt at most", liftMisses.max() ?? -1))
        check((liftMisses.max() ?? 99) < 0.5, "the dragged picture moves exactly with the mouse at every move")
        let t1 = ProcessInfo.processInfo.systemUptime
        send(.leftMouseUp, CGPoint(x: f0.midX + step * 90, y: f0.midY))
        let upTime = ProcessInfo.processInfo.systemUptime - t1
        let wall = ProcessInfo.processInfo.systemUptime - watchStart
        times.sort()
        let median = times[times.count / 2], worst = times.last ?? 0
        print(String(format: "   90 moves: median %.1f ms, worst %.1f ms per move on the main thread; drop %.1f ms; %.2f s for 1.5 s of moving; frame off the mouse by %.1f pt at most",
                     median * 1000, worst * 1000, upTime * 1000, wall, misses.max() ?? -1))
        check(median < 0.004 && worst < 0.03, "a move costs the main thread little (median \(String(format: "%.1f", median * 1000)) ms, worst \(String(format: "%.1f", worst * 1000)) ms)")
        check((misses.max() ?? 99) < 1.5, "the frame drawn is where the mouse is at every move")
        // After the drop the picture stays until the preview has drawn the text in its new place, then goes.
        let dropAt = ProcessInfo.processInfo.systemUptime
        await waitFor(2) { ev.testLifted.isEmpty && CanvasLift.ids.isEmpty && ev.testLiftShowing == 0 }
        let gone = ProcessInfo.processInfo.systemUptime - dropAt
        print("   after the drop: lifted \(ev.testLifted.count), CanvasLift \(CanvasLift.ids.count), pictures still shown \(ev.testLiftShowing)")
        print(String(format: "   the drop: the preview has the text again and the dragged picture is gone %.0f ms later", gone * 1000))
        check(CanvasLift.ids.isEmpty && gone < 0.8, "after the drop the preview draws the text itself again (\(Int(gone * 1000)) ms)")
        let moved = s.project.overlays.first { $0.id == target.id }
        check(moved.map { abs($0.x - (target.x + 0.3)) < 0.01 } == true, "the drop leaves it where it was dragged")
        s.undo()
        check(s.project.overlays.first { $0.id == target.id }?.x == target.x, "the whole drag is one undo step")

        // The logo, dragged in its own view the same way.
        if let logoID = s.project.overlayClips.last?.id {
            s.select(.layer(logoID))
            try? await Task.sleep(nanoseconds: 300_000_000)
            let man = host.manipulator
            if let lf0 = man.frames().first(where: { $0.id == logoID })?.frame {
                func sendL(_ type: NSEvent.EventType, _ p: CGPoint) {
                    let e = mouse(type, man.convert(p, to: nil), win, [.option])
                    switch type { case .leftMouseDown: man.mouseDown(with: e); case .leftMouseDragged: man.mouseDragged(with: e); default: man.mouseUp(with: e) }
                }
                let a = CGPoint(x: lf0.midX, y: lf0.midY)
                let fr0 = s.frameRefreshes
                sendL(.leftMouseDown, a)
                var worst: CGFloat = 0; var start: CGRect?
                for i in 1...40 {
                    let p = CGPoint(x: a.x - CGFloat(i) * 3, y: a.y + CGFloat(i))
                    sendL(.leftMouseDragged, p)
                    if let f = man.testLiftFrame(of: logoID) {
                        if start == nil { start = f.offsetBy(dx: -(p.x - a.x), dy: -(p.y - a.y)) }
                        if let st = start { worst = max(worst, hypot(f.midX - st.midX - (p.x - a.x), f.midY - st.midY - (p.y - a.y))) }
                    } else { worst = 99 }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                let lfr = s.frameRefreshes - fr0
                sendL(.leftMouseUp, CGPoint(x: a.x - 120, y: a.y + 40))
                print(String(format: "   the logo: off the mouse by %.2f pt at most, %d player frames while moving", worst, lfr))
                check(worst < 0.5 && lfr == 0, "a logo dragged moves exactly with the mouse, without the player drawing frames (\(lfr))")
                await waitFor(2) { CanvasLift.ids.isEmpty && man.testLiftShowing == 0 }
                check(CanvasLift.ids.isEmpty, "after the drop the preview draws the logo again")
                s.undo()
            } else { check(false, "the logo has a frame") }
        }
        _ = s.saveNow()
        wc.closeVideo(); wc.window?.orderOut(nil)
    }
}
