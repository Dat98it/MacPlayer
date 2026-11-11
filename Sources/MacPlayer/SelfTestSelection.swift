import AppKit
import MacPlayerCore
import MacPlayerMedia

/// Flow G5: several things on the picture at once — ⇧-click, a selection frame, moving them together, groups, locks — and the keys
/// (⌫, arrows, Esc). Mouse events go to the frames on the picture; keys go through the window's own key handling.
extension SelfTest {
    static func selectionFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G5: several things on the picture: select, move, group, lock, keys")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let black = work.appendingPathComponent("sel-black.png"); writeSolidPNG(to: black, r: 0, g: 0, b: 0, w: 640, h: 360)
        let logo = work.appendingPathComponent("sel-logo.png"); writeSolidPNG(to: logo, r: 0.1, g: 0.4, b: 1, w: 120, h: 120)
        let path = work.appendingPathComponent("selection.macplayer").path; try? fm.removeItem(atPath: path)
        guard let s = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "make a project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        await s.place([black]); await waitFor(10) { s.duration.seconds > 4 && s.previewHasCompositor }
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 500_000_000)
        guard let host = wc.contentController.host, let win = wc.window else { check(false, "the picture area"); return }
        host.layoutSubtreeIfNeeded()
        let pic = host.displayedPicture()
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: pic.minX + fx * pic.width, y: pic.maxY - fy * pic.height) }
        s.addText(.classic, position: CGPoint(x: 0.3, y: 0.3))
        s.addShape(.rectangle, position: CGPoint(x: 0.7, y: 0.3))
        await s.addOverlayPicture(logo, center: CGPoint(x: 0.5, y: 0.7))
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 500_000_000)
        guard s.project.overlays.count == 2, let layerID = s.project.overlayClips.first?.id else { check(false, "two elements and a layer"); return }
        let a = s.project.overlays[0].id, b = s.project.overlays[1].id
        let ev = host.elements
        func send(_ view: NSView, _ type: NSEvent.EventType, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
            let e = mouse(type, view.convert(p, to: nil), win, mods)
            switch type { case .leftMouseDown: view.mouseDown(with: e); case .leftMouseDragged: view.mouseDragged(with: e); default: view.mouseUp(with: e) }
        }
        func click(_ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) { send(ev, .leftMouseDown, p, mods); send(ev, .leftMouseUp, p, mods) }
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return false }
            return wc.testKey(e)
        }
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        func x(_ id: UUID) -> Double { s.project.overlays.first { $0.id == id }?.x ?? s.project.overlayClips.first { $0.id == id }?.transform.centerX ?? -1 }
        func y(_ id: UUID) -> Double { s.project.overlays.first { $0.id == id }?.y ?? s.project.overlayClips.first { $0.id == id }?.transform.centerY ?? -1 }

        // ⇧-click adds to the selection.
        guard let fa = ev.testFrame(of: a), let fb = ev.testFrame(of: b) else { check(false, "the elements have frames"); return }
        click(CGPoint(x: fa.midX, y: fa.midY))
        click(CGPoint(x: fb.midX, y: fb.midY), .shift)
        check(s.canvasSelection == [a, b], "⇧-click adds a second thing to the selection (\(s.canvasSelection.count) selected)")
        // Dragging one moves both; one undo step puts both back.
        send(ev, .leftMouseDown, CGPoint(x: fa.midX, y: fa.midY))
        for i in 1...5 { send(ev, .leftMouseDragged, CGPoint(x: fa.midX + CGFloat(i) * 0.02 * pic.width, y: fa.midY)) }
        send(ev, .leftMouseUp, CGPoint(x: fa.midX + 0.1 * pic.width, y: fa.midY))
        check(abs(x(a) - 0.4) < 0.01 && abs(x(b) - 0.8) < 0.01 && abs(y(a) - 0.3) < 0.01, "dragging one of them moves both (\(String(format: "%.2f, %.2f", x(a), x(b))))")
        s.undo()
        check(abs(x(a) - 0.3) < 0.01 && abs(x(b) - 0.7) < 0.01, "one undo puts both back")

        // A selection frame drawn over the picture takes everything it touches, the layer too.
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        click(at(0.05, 0.95))
        check(s.canvasSelection.isEmpty && s.selection == .none, "a click on an empty part of the picture selects nothing")
        send(ev, .leftMouseDown, at(0.02, 0.02)); send(ev, .leftMouseDragged, at(0.5, 0.5)); send(ev, .leftMouseDragged, at(0.98, 0.98)); send(ev, .leftMouseUp, at(0.98, 0.98))
        check(s.canvasSelection == [a, b, layerID], "a selection frame takes the texts, the shape and the layer (\(s.canvasSelection.count))")

        // The arrows move them all by one point (⇧: ten); a burst of presses is one undo step.
        let ax0 = x(a), lx0 = x(layerID)
        _ = key(124, right); _ = key(124, right); _ = key(124, right, .shift)
        let onePoint = 1 / Double(pic.width)
        check(abs((x(a) - ax0) - 12 * onePoint) < 1e-6 && abs((x(layerID) - lx0) - 12 * onePoint) < 1e-6, "→ → ⇧→ move everything selected by 1 + 1 + 10 points")
        _ = key(125, down)
        check(y(b) > 0.3 + onePoint * 0.5, "↓ moves down")
        s.undo()
        check(abs(x(a) - ax0) < 1e-6 && abs(y(b) - 0.3) < 1e-6, "the burst of arrow presses is undone in one step")

        // Group: then a click on one picks them all.
        s.groupCanvas()
        let g = s.project.overlays[0].groupID
        check(g != nil && s.project.overlays.allSatisfy { $0.groupID == g } && s.project.overlayClips[0].groupID == g, "⌘G groups the three")
        click(at(0.05, 0.95))
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 200_000_000)
        if let f = ev.testFrame(of: b) { click(CGPoint(x: f.midX, y: f.midY)) }
        check(s.canvasSelection == [a, b, layerID], "a click on one member of the group selects the whole group")

        // Lock: nothing moves, nothing is deleted.
        s.toggleLockCanvas()
        check(s.canvasAllLocked, "⌘L locks them")
        let bx = x(b)
        if let f = ev.testFrame(of: b) {
            send(ev, .leftMouseDown, CGPoint(x: f.midX, y: f.midY)); send(ev, .leftMouseDragged, CGPoint(x: f.midX + 40, y: f.midY)); send(ev, .leftMouseUp, CGPoint(x: f.midX + 40, y: f.midY))
        }
        _ = key(124, right)
        check(x(b) == bx, "locked things are not moved by a drag or the arrows")
        _ = key(51, "\u{8}")
        check(s.project.overlays.count == 2 && s.project.overlayClips.count == 1, "⌫ does not delete locked things")
        s.toggleLockCanvas()
        check(!s.canvasAllLocked && s.project.overlays.allSatisfy { $0.locked == nil }, "⌘L again unlocks them")

        // ⌘D duplicates them all (as a new group); ⌫ deletes what is selected; Esc selects nothing.
        s.duplicateSelection()
        check(s.project.overlays.count == 4 && s.project.overlayClips.count == 2 && s.canvasSelection.count == 3 && !s.canvasSelection.contains(a),
              "⌘D duplicates the three and selects the copies")
        let copyGroup = s.project.overlays.last?.groupID
        check(copyGroup != nil && copyGroup != g, "the copies are a group of their own")
        _ = key(51, "\u{8}")
        check(s.project.overlays.count == 2 && s.project.overlayClips.count == 1, "⌫ deletes the selected copies, and only them")
        if let f = ev.testFrame(of: a) { click(CGPoint(x: f.midX, y: f.midY)) }
        _ = key(53, "\u{1b}")
        check(s.canvasSelection.isEmpty && s.selection == .none, "Esc selects nothing")
        // With nothing selected on the picture, the arrows still move the playhead.
        let t0 = s.player.currentTime.seconds
        _ = key(124, right); try? await Task.sleep(nanoseconds: 400_000_000)
        check(s.player.currentTime.seconds > t0 + 0.5, "with nothing selected on the picture, → still skips forward in time")

        // A library tile: a click adds, a small wobble is still a click, and what a drag carries lands on the picture.
        var clicks = 0
        let tile = LibraryDragSourceView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        tile.writer = DragPayload.shape(.star).writer; tile.onClick = { clicks += 1 }
        win.contentView?.addSubview(tile)
        send(tile, .leftMouseDown, CGPoint(x: 20, y: 20)); send(tile, .leftMouseDragged, CGPoint(x: 22, y: 21)); send(tile, .leftMouseUp, CGPoint(x: 22, y: 21))
        check(clicks == 1 && LibraryDragSourceView.dragsStarted == 0, "a library tile clicked (even with a small wobble) adds, without starting a drag")
        tile.removeFromSuperview()
        let pb = NSPasteboard(name: NSPasteboard.Name("MacPlayer.selftest.tile.\(UUID().uuidString)")); pb.clearContents()
        pb.writeObjects([DragPayload.shape(.heart).writer])
        let before = s.project.overlays.count
        _ = host.performDragOperation(TestDraggingInfo(pb: pb, loc: host.convert(at(0.8, 0.8), to: nil), dest: win))
        pb.releaseGlobally()
        let heart = s.project.overlays.last
        check(s.project.overlays.count == before + 1 && heart?.shape?.kind == .heart && abs((heart?.x ?? 0) - 0.8) < 0.01, "what a tile's drag carries, dropped on the picture, lands there")
        _ = s.saveNow()
        wc.closeVideo(); wc.window?.orderOut(nil)
    }

    /// Flow G6: centring while dragging (on the picture, on what lies under), typing right on the picture, restyling by dropping a style.
    static func centringAndTypingFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        print("== G6: centring, typing on the picture, restyling by dropping")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let black = work.appendingPathComponent("ct-black.png"); writeSolidPNG(to: black, r: 0, g: 0, b: 0, w: 640, h: 360)
        let logo = work.appendingPathComponent("ct-logo.png"); writeSolidPNG(to: logo, r: 0.1, g: 0.4, b: 1, w: 120, h: 120)
        let path = work.appendingPathComponent("centring.macplayer").path; try? fm.removeItem(atPath: path)
        guard let s = try? await EditorSession.makeProjectFile(kind: .video, media: nil, at: path) else { check(false, "make a project"); return }
        let wc = MainWindowController(playlists: app.playlists); app.adopt(wc)
        wc.setSession(s, fromPlaylist: false); wc.showWindow(nil)
        await s.place([black]); await waitFor(10) { s.duration.seconds > 4 && s.previewHasCompositor }
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 500_000_000)
        guard let host = wc.contentController.host, let win = wc.window else { check(false, "the picture area"); return }
        host.layoutSubtreeIfNeeded()
        let pic = host.displayedPicture()
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: pic.minX + fx * pic.width, y: pic.maxY - fy * pic.height) }
        func send(_ view: NSView, _ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
            let e = NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            switch type { case .leftMouseDown: view.mouseDown(with: e); case .leftMouseDragged: view.mouseDragged(with: e); default: view.mouseUp(with: e) }
        }
        let ev = host.elements
        // A big shape off-centre, a text, and a logo.
        s.addShape(.rectangle, position: CGPoint(x: 0.3, y: 0.35))
        if let i = s.project.overlays.indices.last { s.edit("Big") { $0.overlays[i].shape?.width = 0.4; $0.overlays[i].shape?.height = 0.5 } }
        let shapeID = s.project.overlays.last!.id
        s.addText(.classic, position: CGPoint(x: 0.75, y: 0.8))
        let textID = s.project.overlays.last!.id
        await s.addOverlayPicture(logo, center: CGPoint(x: 0.85, y: 0.25))
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 500_000_000)
        func x(_ id: UUID) -> Double { s.project.overlays.first { $0.id == id }?.x ?? s.project.overlayClips.first { $0.id == id }?.transform.centerX ?? -1 }
        func y(_ id: UUID) -> Double { s.project.overlays.first { $0.id == id }?.y ?? s.project.overlayClips.first { $0.id == id }?.transform.centerY ?? -1 }

        // Dragged close to the middle of the picture: it clings, and says so.
        guard let ft = ev.testFrame(of: textID) else { check(false, "the text has a frame"); return }
        let toMiddle = CGPoint(x: at(0.505, 0.497).x - at(0.75, 0.8).x, y: at(0.505, 0.497).y - at(0.75, 0.8).y)
        send(ev, .leftMouseDown, CGPoint(x: ft.midX, y: ft.midY))
        send(ev, .leftMouseDragged, CGPoint(x: ft.midX + toMiddle.x, y: ft.midY + toMiddle.y))
        let labelsMiddle = ev.lastGuideLabels
        send(ev, .leftMouseUp, CGPoint(x: ft.midX + toMiddle.x, y: ft.midY + toMiddle.y))
        check(x(textID) == 0.5 && y(textID) == 0.5 && labelsMiddle == [L("Centre of the picture"), L("Centre of the picture")],
              "near the middle, the text centres on the picture and says so (\(String(format: "%.3f, %.3f", x(textID), y(textID))), \(labelsMiddle))")
        // Dragged onto the shape, near its middle: it centres on the shape, not on the picture.
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        if let f2 = ev.testFrame(of: textID) {
            let target = at(0.31, 0.345)
            send(ev, .leftMouseDown, CGPoint(x: f2.midX, y: f2.midY))
            send(ev, .leftMouseDragged, CGPoint(x: f2.midX + target.x - at(0.5, 0.5).x, y: f2.midY + target.y - at(0.5, 0.5).y))
            let labels = ev.lastGuideLabels
            send(ev, .leftMouseUp, CGPoint(x: f2.midX + target.x - at(0.5, 0.5).x, y: f2.midY + target.y - at(0.5, 0.5).y))
            let shapeName = TextPane.shapeName(.rectangle)
            check(abs(x(textID) - 0.3) < 0.003 && abs(y(textID) - 0.35) < 0.003 && labels.allSatisfy { $0 == LF("Centre of %@", shapeName) },
                  "dropped near the middle of the shape under it, the text centres on the shape and says so (\(String(format: "%.3f, %.3f", x(textID), y(textID))), \(labels))")
        }
        // A layer dragged near the middle centres too, with the same words.
        let lr = host.manipulator
        let lc = at(0.85, 0.25)
        send(lr, .leftMouseDown, lc)
        send(lr, .leftMouseDragged, CGPoint(x: lc.x - (at(0.85, 0.5).x - at(0.496, 0.5).x), y: lc.y))
        send(lr, .leftMouseUp, CGPoint(x: lc.x - (at(0.85, 0.5).x - at(0.496, 0.5).x), y: lc.y))
        let logoID = s.project.overlayClips.first!.id
        check(x(logoID) == 0.5 && lr.lastGuideLabels.contains(L("Centre of the picture")), "a layer dragged near the middle centres and says so (\(String(format: "%.3f", x(logoID))))")

        // Double-click a text: a field opens on it; typing shows at once; Return keeps it as one undo step.
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        let before = s.project.overlays.first { $0.id == textID }?.text ?? ""
        if let f3 = ev.testFrame(of: textID) {
            send(ev, .leftMouseDown, CGPoint(x: f3.midX, y: f3.midY), clicks: 1); send(ev, .leftMouseUp, CGPoint(x: f3.midX, y: f3.midY), clicks: 1)
            send(ev, .leftMouseDown, CGPoint(x: f3.midX, y: f3.midY), clicks: 2); send(ev, .leftMouseUp, CGPoint(x: f3.midX, y: f3.midY), clicks: 2)
        }
        guard let field = ev.testTypingField, let tv = field.currentEditor() as? NSTextView else { check(false, "a double click on a text opens a field to type in"); return }
        check(field.stringValue == before && win.firstResponder === tv, "a double click opens a field on the text, ready to type")
        tv.selectAll(nil); tv.insertText("Xin chào", replacementRange: tv.selectedRange())
        check(s.project.overlays.first { $0.id == textID }?.text == "Xin chào", "what is typed shows on the text at once")
        _ = ev.control(field, textView: tv, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        tv.insertText("MacPlayer", replacementRange: tv.selectedRange())
        _ = ev.control(field, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(ev.testTypingField == nil && s.project.overlays.first { $0.id == textID }?.text == "Xin chào\nMacPlayer", "⌥Return makes a new line; Return ends the typing")
        s.undo()
        check(s.project.overlays.first { $0.id == textID }?.text == before, "one undo takes the whole typing back")
        s.redo()
        // Esc puts the words back.
        ev.beginTyping(textID)
        if let f4 = ev.testTypingField, let tv4 = f4.currentEditor() as? NSTextView {
            tv4.selectAll(nil); tv4.insertText("oops", replacementRange: tv4.selectedRange())
            _ = ev.control(f4, textView: tv4, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        check(s.project.overlays.first { $0.id == textID }?.text == "Xin chào\nMacPlayer" && ev.testTypingField == nil, "Esc puts the words back and closes the field")
        // Shapes are not typed in.
        if let fs = ev.testFrame(of: shapeID) { send(ev, .leftMouseDown, CGPoint(x: fs.minX + 4, y: fs.minY + 4), clicks: 2); send(ev, .leftMouseUp, CGPoint(x: fs.minX + 4, y: fs.minY + 4), clicks: 2) }
        check(ev.testTypingField == nil, "a double click on a shape opens no field")

        // A style from the library dropped on the text restyles it; dropped elsewhere it adds a text.
        await s.player.seek(to: MediaTime(seconds: 1)); try? await Task.sleep(nanoseconds: 300_000_000)
        if let f5 = ev.testFrame(of: textID) {
            let count = s.project.overlays.count
            let pb = NSPasteboard(name: NSPasteboard.Name("MacPlayer.selftest.style.\(UUID().uuidString)")); pb.clearContents(); pb.writeObjects([DragPayload.text(.highlight).writer])
            _ = host.performDragOperation(TestDraggingInfo(pb: pb, loc: ev.convert(CGPoint(x: f5.midX, y: f5.midY), to: nil), dest: win))
            var expect = TextOverlay(text: "x", start: .zero, end: MediaTime(seconds: 1)); TextTemplate.highlight.apply(to: &expect)
            let o = s.project.overlays.first { $0.id == textID }
            check(s.project.overlays.count == count && o?.backgroundHex == expect.backgroundHex && o?.fontName == expect.fontName && o?.text == "Xin chào\nMacPlayer",
                  "a style dropped on a text restyles it and keeps its words")
            _ = host.performDragOperation(TestDraggingInfo(pb: pb, loc: host.convert(at(0.9, 0.9), to: nil), dest: win))
            check(s.project.overlays.count == count + 1, "dropped on an empty place, a style adds a new text")
            pb.releaseGlobally()
        }
        _ = s.saveNow()
        wc.closeVideo(); wc.window?.orderOut(nil)
    }
}
