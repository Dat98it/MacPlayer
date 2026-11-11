import AppKit
import MacPlayerCore
import MacPlayerMedia

/// Flow G4: text, stickers, shapes and pictures put and moved right on the picture, in a video project and in a photo project.
/// Drops go through the picture's own drop code; drags send mouse events to the element frames themselves.
extension SelfTest {
    static func canvasFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G4: putting and moving text, stickers, shapes and pictures on the picture")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let black = work.appendingPathComponent("cv-black.png"); writeSolidPNG(to: black, r: 0, g: 0, b: 0, w: 640, h: 360)
        let logo = work.appendingPathComponent("cv-logo.png"); writeSolidPNG(to: logo, r: 0.1, g: 0.4, b: 1, w: 120, h: 120)

        // A video project whose clip is a black photo, so what is put on it shows plainly.
        let path = work.appendingPathComponent("canvas.macplayer").path; try? fm.removeItem(atPath: path)
        guard let s = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "make a video project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        await s.place([black])
        await waitFor(10) { s.duration.seconds > 4 && s.previewHasCompositor }
        await s.player.seek(to: MediaTime(seconds: 1))
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let host = wc.contentController.host else { check(false, "the picture area"); return }
        host.layoutSubtreeIfNeeded()
        let pic = host.displayedPicture()
        // A message is showing under the picture (the photo went into the library): the picture keeps its room all the same.
        check(pic.height > 150, "a message under the picture never squeezes the picture (\(Int(pic.height)) points high)")
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: pic.minX + fx * pic.width, y: pic.maxY - fy * pic.height) }
        func drop(_ item: DragPayload?, files: [URL] = [], on view: NSView, at p: CGPoint) async -> Bool {
            let pb = item != nil ? await pasteboard(from: [item!.provider]) : await pasteboard(from: files.map { DragPayload.fileProvider($0.path) })
            defer { pb.releaseGlobally() }
            return view.performDragOperation(TestDraggingInfo(pb: pb, loc: view.convert(p, to: nil), dest: view.window))
        }

        // Dropped where the mouse lets go.
        _ = await drop(.text(.classic), on: host, at: at(0.25, 0.3))
        let text = s.project.overlays.last
        check(text.map { abs($0.x - 0.25) < 0.01 && abs($0.y - 0.3) < 0.01 } == true && s.selection == text.map { .text($0.id) },
              "a text style dropped on the picture lands where it was dropped, selected (\(String(format: "%.2f, %.2f", text?.x ?? -1, text?.y ?? -1)))")
        _ = await drop(.shape(.rectangle), on: host, at: at(0.25, 0.7))
        let shape = s.project.overlays.last
        check(shape?.shape?.kind == .rectangle && shape.map { abs($0.x - 0.25) < 0.01 && abs($0.y - 0.7) < 0.01 } == true, "a shape dropped on the picture lands there")
        _ = await drop(.sticker("⭐️"), on: host, at: at(0.5, 0.5))
        check(s.project.overlays.count == 3 && s.project.overlays.last.map { abs($0.x - 0.5) < 0.01 } == true, "a sticker dropped on the picture lands there")
        _ = await drop(nil, files: [logo], on: host, at: at(0.8, 0.2))
        await waitFor(6) { s.project.overlayClips.count == 1 }
        let layer = s.project.overlayClips.first
        check(layer.map { abs($0.transform.centerX - 0.8) < 0.01 && abs($0.transform.centerY - 0.2) < 0.01 } == true,
              "a picture dropped on the picture becomes a layer centred there (\(String(format: "%.2f, %.2f", layer?.transform.centerX ?? -1, layer?.transform.centerY ?? -1)))")

        // A square from the library is square on this wide picture (it used to come out a wide rectangle).
        s.addShape(.rectangle, position: CGPoint(x: 0.5, y: 0.25))
        let squareID = s.project.overlays.last!.id
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        if let fq = host.elements.testFrame(of: squareID) {
            check(abs(fq.width - fq.height) < 2, "a square shape is square on the picture (\(Int(fq.width)) × \(Int(fq.height)) points)")
        } else { check(false, "the square has a frame") }
        s.edit("Remove square") { $0.overlays.removeAll { $0.id == squareID } }

        // The frames sit on the elements.
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        let ev = host.elements
        guard let sh = shape, let f0 = ev.testFrame(of: sh.id) else { check(false, "the shape has a frame on the picture"); return }
        let expect = at(0.25, 0.7)
        check(abs(f0.midX - expect.x) < 3 && abs(f0.midY - expect.y) < 3 && abs(f0.width - 0.18 * pic.width) < 3,
              "the shape's frame is drawn on it (\(Int(f0.midX)),\(Int(f0.midY)) vs \(Int(expect.x)),\(Int(expect.y)))")
        // An empty part of the picture takes the mouse (a selection frame, or a click that selects nothing); outside the picture it passes through.
        check(ev.hitTest(host.convert(at(0.9, 0.9), to: ev.superview)) === ev && ev.hitTest(host.convert(CGPoint(x: pic.midX, y: pic.minY - 8), to: ev.superview)) == nil,
              "an empty part of the picture is for selecting; outside the picture the mouse passes through")

        // Drag the shape across: it follows, at once in the preview, and the drag is one undo step.
        guard let win = wc.window else { return }
        func send(_ view: NSView, _ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
            let e = mouse(type, view.convert(p, to: nil), win, mods)
            switch type { case .leftMouseDown: view.mouseDown(with: e); case .leftMouseDragged: view.mouseDragged(with: e); default: view.mouseUp(with: e) }
        }
        let undoBefore = s.history.canUndo ? s.undoTitle : ""
        send(ev, .leftMouseDown, CGPoint(x: f0.midX, y: f0.midY))
        for i in 1...10 { send(ev, .leftMouseDragged, CGPoint(x: f0.midX + CGFloat(i) * 0.05 * pic.width, y: f0.midY), .option) }
        send(ev, .leftMouseUp, CGPoint(x: f0.midX + 0.5 * pic.width, y: f0.midY))
        let movedShape = s.project.overlays.first { $0.id == sh.id }
        check(abs((movedShape?.x ?? 0) - 0.75) < 0.01 && abs((movedShape?.y ?? 0) - 0.7) < 0.01, "dragging the shape moves it (to \(String(format: "%.2f", movedShape?.x ?? -1)))")
        check(ElementLive.placement(for: sh.id).map { abs($0.x - 0.75) < 0.01 } == true, "the preview follows the drag at once, without being built again")
        s.undo()
        check(abs((s.project.overlays.first { $0.id == sh.id }?.x ?? 0) - 0.25) < 0.01, "one undo puts it back where it was (\(undoBefore.isEmpty ? "" : "one step"))")
        s.redo()

        // A corner: bigger.
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        if let f1 = ev.testFrame(of: sh.id) {
            let corner = CGPoint(x: f1.maxX, y: f1.maxY), c = CGPoint(x: f1.midX, y: f1.midY)
            send(ev, .leftMouseDown, corner)
            send(ev, .leftMouseDragged, CGPoint(x: c.x + (corner.x - c.x) * 2, y: c.y + (corner.y - c.y) * 2))
            send(ev, .leftMouseUp, CGPoint(x: c.x + (corner.x - c.x) * 2, y: c.y + (corner.y - c.y) * 2))
            let k = s.project.overlays.first { $0.id == sh.id }?.scale ?? 1
            check(abs(k - 2) < 0.1, "dragging a corner makes it bigger (×\(String(format: "%.2f", k)))")
        } else { check(false, "the moved shape has a frame") }

        // The middle of the picture holds the text when it comes close.
        if let t = text, let ft = ev.testFrame(of: t.id) {
            send(ev, .leftMouseDown, CGPoint(x: ft.midX, y: ft.midY))
            let target = at(0.497, 0.502)
            send(ev, .leftMouseDragged, CGPoint(x: target.x + (ft.midX - at(0.25, 0.3).x), y: target.y + (ft.midY - at(0.25, 0.3).y)))
            send(ev, .leftMouseUp, CGPoint(x: target.x, y: target.y))
            let o = s.project.overlays.first { $0.id == t.id }
            check(o.map { $0.x == 0.5 && $0.y == 0.5 } == true, "near the middle, the text clings to it (\(String(format: "%.3f, %.3f", o?.x ?? -1, o?.y ?? -1)))")
        }

        // The export has the shape where it was dragged, twice as big.
        let outDir = work.appendingPathComponent("cv-out"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let res = await runExport(s, env: env, ExportRequest(options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "canvas"))
        if let out = res.path, let img = try? await FrameGrabber.image(url: URL(fileURLWithPath: out), at: MediaTime(seconds: 2), accuracy: .exact) {
            let atNew = pixel(img, fx: 0.75 + 0.15, fy: 0.7), atOld = pixel(img, fx: 0.25, fy: 0.7)
            check(atNew.r > 200 && atNew.g > 170 && atNew.b < 90 && atOld.r < 60, "the export has the shape where it was dragged, and twice as big (new \(atNew), old place \(atOld))")
        } else { check(false, "export the moved shape (\(res.message))") }
        wc.closeVideo(); wc.window?.orderOut(nil)

        // A photo project: the same on the photo, and the logos too.
        let ppath = work.appendingPathComponent("canvas-photo.macplayer").path; try? fm.removeItem(atPath: ppath)
        guard let ps = try? await EditorSession.makeProjectFile(kind: .photo, media: nil, at: ppath) else { check(false, "make a photo project"); return }
        let pw = MainWindowController(playlists: app.playlists); app.adopt(pw)
        pw.setSession(ps, fromPlaylist: false); pw.showWindow(nil)
        await ps.place([black]); await waitFor(6) { ps.photoImage != nil }
        ps.activeTool = .picture        // the tool a photo opens on: the crop frame is not in the way any more
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard let ph = pw.contentController.photoHost else { check(false, "the photo area"); return }
        ph.layoutSubtreeIfNeeded()
        let prect = ph.pictureRect()
        func pat(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: prect.minX + fx * prect.width, y: prect.maxY - fy * prect.height) }
        _ = await drop(.shape(.rectangle), on: ph, at: pat(0.3, 0.3))
        _ = await drop(nil, files: [logo], on: ph, at: pat(0.7, 0.7))
        await waitFor(6) { ps.project.overlayClips.count == 1 }
        let pshape = ps.project.overlays.last
        let plogo = ps.project.overlayClips.first
        check(pshape.map { abs($0.x - 0.3) < 0.01 && abs($0.y - 0.3) < 0.01 } == true && plogo.map { abs($0.transform.centerX - 0.7) < 0.01 && abs($0.transform.centerY - 0.7) < 0.01 } == true,
              "on a photo, a shape and a logo land where they are dropped (shape \(String(format: "%.2f, %.2f", pshape?.x ?? -1, pshape?.y ?? -1)), logo \(String(format: "%.2f, %.2f", plogo?.transform.centerX ?? -1, plogo?.transform.centerY ?? -1)), picture \(prect))")
        ps.activeTool = .picture; try? await Task.sleep(nanoseconds: 300_000_000)
        if let p0 = pshape, let fr = ph.elements.testFrame(of: p0.id) {
            send(ph.elements, .leftMouseDown, CGPoint(x: fr.midX, y: fr.midY))
            send(ph.elements, .leftMouseDragged, CGPoint(x: fr.midX, y: fr.midY - 0.4 * prect.height), .option)
            send(ph.elements, .leftMouseUp, CGPoint(x: fr.midX, y: fr.midY - 0.4 * prect.height))
            let o = ps.project.overlays.first { $0.id == p0.id }
            check(abs((o?.y ?? 0) - 0.7) < 0.01, "on a photo, dragging the shape moves it, even on the tool the photo opens on (y \(String(format: "%.2f", o?.y ?? -1)))")
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let img = ps.photoImage {
                let moved = pixel(img, fx: 0.3, fy: 0.7), left = pixel(img, fx: 0.3, fy: 0.3)
                check(moved.r > 200 && moved.g > 170 && left.r < 60, "the photo shows the shape at its new place (\(moved), old place \(left))")
            }
        } else { check(false, "the photo's shape has a frame") }
        if let l = plogo {
            let lr = ph.layers
            let c = pat(0.7, 0.7)
            send(lr, .leftMouseDown, c)
            send(lr, .leftMouseDragged, CGPoint(x: c.x - 0.4 * prect.width, y: c.y), .option)
            send(lr, .leftMouseUp, CGPoint(x: c.x - 0.4 * prect.width, y: c.y))
            let moved = ps.project.overlayClips.first { $0.id == l.id }
            check(abs((moved?.transform.centerX ?? 0) - 0.3) < 0.02 && ps.selection == .layer(l.id), "on a photo, a logo is dragged right on it (x \(String(format: "%.2f", moved?.transform.centerX ?? -1)))")
        }
        ps.photoCropAdjusting = true; ps.activeTool = .picture; try? await Task.sleep(nanoseconds: 300_000_000)
        check(pshape.flatMap { ph.elements.testFrame(of: $0.id) } == nil, "while the crop frame is out, the elements step aside")
        ps.photoCropAdjusting = false
        _ = ps.saveNow()
        pw.closeVideo(); pw.window?.orderOut(nil)
    }

    static func writeSolidPNG(to url: URL, r: Double, g: Double, b: Double, w: Int, h: Int) {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }

    /// The colour at a place of a picture (fractions from the top-left).
    static func pixel(_ img: CGImage, fx: Double, fy: Double) -> (r: Int, g: Int, b: Int) {
        // Drawn into memory the context owns (an `&array` pointer is only good during the call that takes it).
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return (0, 0, 0) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let x = min(w - 1, max(0, Int(fx * Double(w)))), y = min(h - 1, max(0, Int(fy * Double(h))))
        let p = data.assumingMemoryBound(to: UInt8.self) + (y * w + x) * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }
}
