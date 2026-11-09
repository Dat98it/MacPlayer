import AppKit
import SwiftUI
import Foundation
import MacPlayerCore

/// Choosing several files, renaming them together, moving them to the Trash together, and the folder tree. Only copies made here are touched.
extension SelfTest {
    static func batchFlow(work: URL, source: URL, app: AppDelegate) async {
        print("-- several files at once: rename, Trash, folder tree")
        let fm = FileManager.default
        let model = app.playlists
        let root = work.appendingPathComponent("batch"); try? fm.removeItem(at: root)
        let fakeTrash = work.appendingPathComponent("batch-trash"); try? fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }
        let files = ["Trip/Day 1/a.mp4", "Trip/Day 1/b.mp4", "Trip/Day 2/c.mp4", "Misc/d.mp4", "e.mp4"]
        for f in files {
            try? fm.createDirectory(at: URL(fileURLWithPath: path(f)).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: URL(fileURLWithPath: path(f)))
        }
        FileActions.trasher = { u in try FileManager.default.moveItem(at: u, to: fakeTrash.appendingPathComponent(u.lastPathComponent)) }
        defer { FileActions.trasher = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) } }
        let pid = model.create(name: "Batch")
        let other = model.create(name: "Batch 2")
        model.add(urls: files.map { URL(fileURLWithPath: path($0)) }, to: pid)
        model.add(urls: [URL(fileURLWithPath: path("Trip/Day 1/a.mp4"))], to: other)
        func items(_ id: UUID) -> [PlaylistItem] { model.playlists.first { $0.id == id }?.items ?? [] }
        func names(_ id: UUID) -> [String] { items(id).map { PathUtil.fileName(of: $0.path) } }

        // The folder tree of what was added.
        let rows = FolderTree.rows(for: items(pid), order: model.playlists.first { $0.id == pid }?.order ?? .manual)
        check(rows.filter { $0.kind == .folder }.map(\.title) == ["batch", "Trip", "Day 1", "Day 2", "Misc"] && rows.filter { $0.kind == .file }.count == 5, "the tree shows the folders above the files they hold")
        check(rows.first { $0.title == "Trip" }?.fileCount == 3 && rows.first { $0.title == "batch" }?.fileCount == 5, "a folder row counts every file inside it, also in folders inside it")
        model.setOrder(pid, PlaylistOrder(key: .folder))
        let treeOrder = FolderTree.rows(for: items(pid), order: PlaylistOrder(key: .folder)).compactMap(\.itemID)
        check(treeOrder == items(pid).map(\.id), "sorting by folder makes the playlist's order the tree's order")
        // The tree keeps folders under their standard path (/private/tmp is /tmp), so the row says which one to close.
        guard let trip = rows.first(where: { $0.title == "Trip" })?.path else { check(false, "the Trip folder has a row"); return }
        model.toggleFolder(trip, in: pid)
        check(model.collapsedFolders[pid]?.contains(trip) == true, "a folder can be closed")
        check(FolderTree.rows(for: items(pid), order: PlaylistOrder(key: .folder), collapsed: model.collapsedFolders[pid] ?? []).filter { $0.kind == .file }.count == 2, "its files are hidden")
        model.setFolders(FolderTree.folderPaths(for: items(pid), order: PlaylistOrder(key: .folder)), collapsed: false, in: pid)
        check((model.collapsedFolders[pid] ?? []).isEmpty, "open all folders opens them again")

        // Several files chosen: the sheet opens (one file would ask its own question instead).
        app.renameFiles(at: [path("Trip/Day 1/a.mp4"), path("Trip/Day 1/a.mp4"), path("Trip/Day 1/b.mp4")])
        check(model.batchRename?.paths.count == 2, "choosing files to rename opens the sheet, once per file")
        model.batchRename = nil

        // Renaming three files, in the order they are listed, across folders.
        var rule = BatchRenameRule(); rule.mode = .numbered; rule.baseName = "Day"; rule.digits = 2
        let chosen = ["Trip/Day 1/a.mp4", "Trip/Day 1/b.mp4", "Trip/Day 2/c.mp4"].map(path)
        let done = try? app.performBatchRename(paths: chosen, rule: rule)
        check(done?.count == 3 && fm.fileExists(atPath: path("Trip/Day 1/Day 01.mp4")) && fm.fileExists(atPath: path("Trip/Day 1/Day 02.mp4")) && fm.fileExists(atPath: path("Trip/Day 2/Day 03.mp4")), "the files are renamed on the disk, each in its own folder")
        check(!fm.fileExists(atPath: path("Trip/Day 1/a.mp4")) && fm.fileExists(atPath: path("Misc/d.mp4")) && fm.fileExists(atPath: path("e.mp4")), "the others are not touched")
        check(Set(items(pid).map(\.title)).isSuperset(of: ["Day 01", "Day 02", "Day 03", "d", "e"]) && items(pid).count == 5, "the playlist follows: same entries, new names")
        check(items(other).first?.path == path("Trip/Day 1/Day 01.mp4"), "so does every other playlist that had a file")
        check(model.status == LF("%d files were renamed.", 3), "and the message says how many")

        // A name that is taken: nothing at all is renamed.
        var taken = BatchRenameRule(); taken.mode = .findReplace; taken.find = "Day 01"; taken.replacement = "Day 02"
        do { try app.performBatchRename(paths: [path("Trip/Day 1/Day 01.mp4")], rule: taken); check(false, "a taken name is refused") }
        catch { check((error as? RenameError) == .exists && fm.fileExists(atPath: path("Trip/Day 1/Day 01.mp4")) && fm.fileExists(atPath: path("Trip/Day 1/Day 02.mp4")), "a name another file has is refused and nothing is overwritten") }

        // A file that is open with unsaved edits is left out; the others still go.
        let wc = MainWindowController(playlists: model); app.adopt(wc)
        if let s = try? await EditorSession.open(url: URL(fileURLWithPath: path("Misc/d.mp4"))) {
            wc.setSession(s, fromPlaylist: false)
            s.addClipFromInOut()
            var pre = BatchRenameRule(); pre.mode = .prefixSuffix; pre.prefix = "x-"
            _ = try? app.performBatchRename(paths: [path("Misc/d.mp4"), path("e.mp4")], rule: pre)
            check(fm.fileExists(atPath: path("Misc/d.mp4")) && fm.fileExists(atPath: path("x-e.mp4")), "a video that is open with unsaved edits is left out, the other file is renamed")
            wc.closeVideo(confirm: { _ in true })
        } else { check(false, "open a video to keep busy") }
        wc.window?.orderOut(nil)

        // Moving several files to the Trash; one the Trash refuses does not stop the others.
        let lockedName = "Day 02.mp4"
        FileActions.trasher = { u in
            if u.lastPathComponent == lockedName { struct Refused: Error {}; throw Refused() }
            try FileManager.default.moveItem(at: u, to: fakeTrash.appendingPathComponent(u.lastPathComponent))
        }
        let result = app.performTrashes([path("Trip/Day 1/Day 01.mp4"), path("Trip/Day 1/Day 02.mp4"), path("Trip/Day 2/Day 03.mp4"), path("Trip/Day 1/Day 01.mp4")])
        check(result.trashed.count == 2 && result.failed.count == 1, "two files moved, the refused one reported (the same file listed twice counts once)")
        check(!fm.fileExists(atPath: path("Trip/Day 1/Day 01.mp4")) && !fm.fileExists(atPath: path("Trip/Day 2/Day 03.mp4")) && fm.fileExists(atPath: fakeTrash.appendingPathComponent("Day 03.mp4").path), "the files left their folders and are in the Trash")
        check(fm.fileExists(atPath: path("Trip/Day 1/Day 02.mp4")) && names(pid).contains("Day 02.mp4") && !names(pid).contains("Day 01.mp4") && !names(pid).contains("Day 03.mp4"), "the playlist lost the moved ones and kept the refused one")
        check(items(other).isEmpty, "other playlists drop a moved file too")
        check(model.status == LF("%d files were moved to the Trash, %d could not be.", 2, 1), "the message tells both numbers")
        model.delete(pid); model.delete(other)
    }

    /// The tree of a big library must stay quick to draw: it was once built so that closing a folder took seconds with 2 700 files and the
    /// window stopped answering. The files are made up (they need not exist); the sidebar is really drawn in a window.
    static func treeSpeedFlow(app: AppDelegate) async {
        print("-- the folder tree of a big library stays quick")
        let model = app.playlists
        let env = AppEnvironment.shared!
        app.quitWhenLastWindowCloses = false      // the only window here is the one made for this check; the self-test ends the app itself
        let before = env.prefs.playlistLayout
        env.prefs.playlistLayout = .tree
        defer { env.prefs.playlistLayout = before }
        let urls = (0..<3000).map { i in URL(fileURLWithPath: "/private/tmp/macplayer-speed/Year \(i % 6)/Month \((i / 6) % 20)/IMG_\(i).jpg") }
        let pid = model.create(name: "Speed")
        var items = urls.map { PlaylistItem(path: $0.path) }
        for i in items.indices { items[i].availability = .available }
        model.replaceItemsForSelfTest(items, in: pid)
        let host = NSHostingView(rootView: PlaylistSidebar(model: model, openURL: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let folders = FolderTree.folderPaths(for: items, order: model.playlists.first { $0.id == pid }?.order ?? .manual)
        check(folders.count > 100, "the sidebar shows a tree of \(folders.count) folders for 3000 files")
        guard let target = folders.dropFirst(2).first else { window.orderOut(nil); Self.testWindows.append(window); model.delete(pid); return }
        var worst = Duration.zero
        let start = ContinuousClock.now
        for _ in 0..<12 {
            let one = ContinuousClock.now
            model.toggleFolder(target, in: pid)
            try? await Task.sleep(nanoseconds: 20_000_000)       // lets the window draw what changed
            worst = max(worst, ContinuousClock.now - one)
        }
        func millis(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
        check(millis(ContinuousClock.now - start) < 4000, "closing and opening a folder 12 times with 3000 files took \(millis(ContinuousClock.now - start)) ms (slowest turn \(millis(worst)) ms)")
        window.orderOut(nil); Self.testWindows.append(window)
        try? await Task.sleep(nanoseconds: 400_000_000)      // the app decides about quitting a moment after the last window closes
        model.delete(pid)
    }


    // MARK: Clicking in the tree

    /// A real click (mouse down and up, with the given keys held) on the file's row, sent to the window the way the system sends it.
    @discardableResult
    private static func press(_ id: UUID, in window: NSWindow, keys: NSEvent.ModifierFlags = []) async -> Bool {
        // The rows may still be settling into place just after the window shows: wait until a row stays where it is.
        var last = SidebarProbe.rowFrames[id]
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let now = SidebarProbe.rowFrames[id]
            if now != nil, now == last { break }
            last = now
        }
        guard let host = window.contentView, let frame = SidebarProbe.rowFrames[id] else { return false }
        // SwiftUI measures from the top of the view; the window measures from the bottom unless the view says it is flipped.
        let inView = NSPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY)
        let point = host.convert(inView, to: nil)
        for _ in 0..<30 where !window.isKeyWindow { try? await Task.sleep(nanoseconds: 100_000_000) }      // a click only counts in the key window
        // Both halves of the click are queued at once, as the hardware does: a window may wait inside the press for the release, and
        // if the release were only sent after a pause on the main thread, nothing would ever send it.
        for (type, n) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: keys, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return true
    }

    /// A click that must change what is chosen. A click sent to a window can occasionally be dropped; none of these steps leaves the choice as it
    /// was when it works, so a click that changed nothing is sent again (and counted, so the test says how often that happened).
    @discardableResult
    private static func click(_ id: UUID, in window: NSWindow, keys: NSEvent.ModifierFlags = []) async -> Bool {
        let before = SidebarProbe.chosen
        for attempt in 0..<4 {
            guard await press(id, in: window, keys: keys) else { return false }
            if ProcessInfo.processInfo.environment["MACPLAYER_AX_DEBUG"] != nil { print("   press attempt \(attempt) rows=\(SidebarProbe.rowFrames.count) chosen=\(SidebarProbe.chosen.count) before=\(before.count)") }
            if SidebarProbe.chosen != before { if attempt > 0 { clickRetries += attempt }; return true }
        }
        return true
    }

    private static var clickRetries = 0
    /// The windows made for the checks are hidden and kept, not closed: closing the last window of the app has ended the run before.
    private static var testWindows: [NSWindow] = []

    /// Choosing single files in the folder tree with the mouse: a click, ⌘-click and ⇧-click on a file, not only on a whole folder.
    static func treeClickFlow(app: AppDelegate, layout: PlaylistLayout = .tree) async {
        print("-- choosing single files with the mouse: \(layout.rawValue) layout")
        let model = app.playlists
        let env = AppEnvironment.shared!
        app.quitWhenLastWindowCloses = false
        let before = env.prefs.playlistLayout
        env.prefs.playlistLayout = layout
        defer { env.prefs.playlistLayout = before }
        SidebarProbe.enabled = true; SidebarProbe.rowFrames = [:]; SidebarProbe.chosen = []
        defer { SidebarProbe.enabled = false }
        let paths = ["Trip/aa.jpg", "Trip/bb.jpg", "Trip/cc.jpg", "Misc/dd.jpg"].map { "/private/tmp/macplayer-click/" + $0 }
        let pid = model.create(name: "Clicks")
        model.replaceItemsForSelfTest(paths.map { var i = PlaylistItem(path: $0); i.availability = .available; return i }, in: pid)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlaylistSidebar(model: model, openURL: { _ in }))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)      // a click in a window that is not the key window only brings it forward
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        SidebarProbe.chosen = []
        let items = model.playlists.first { $0.id == pid }?.items ?? []
        func id(_ name: String) -> UUID { items.first { $0.title == name }!.id }
        func names(_ ids: Set<UUID>) -> [String] { items.filter { ids.contains($0.id) }.map(\.title) }
        // The scenario is tried up to three times: a click sent to a window can occasionally be lost, and one lost click throws the rest off.
        var results: [(Bool, String)] = []
        for attempt in 1...3 {
            results = []
            func expect(_ ok: Bool, _ what: String) { results.append((ok, what)) }
            guard await click(id("aa"), in: window) else { expect(false, "the sidebar reports where its file rows are"); break }
            expect(names(SidebarProbe.chosen) == ["aa"], "a click on a file chooses that file: \(names(SidebarProbe.chosen))")
            await click(id("cc"), in: window, keys: .command)
            expect(Set(names(SidebarProbe.chosen)) == ["aa", "cc"], "⌘-click adds another file: \(names(SidebarProbe.chosen))")
            await click(id("aa"), in: window, keys: .command)
            expect(names(SidebarProbe.chosen) == ["cc"], "⌘-click on a chosen file lets it go: \(names(SidebarProbe.chosen))")
            if layout == .tree {
                await click(id("aa"), in: window)
                await click(id("cc"), in: window, keys: .shift)
                expect(Set(names(SidebarProbe.chosen)) == ["aa", "bb", "cc"], "⇧-click chooses the files between the first click and this one: \(names(SidebarProbe.chosen))")
            }
            await click(id("dd"), in: window)
            expect(names(SidebarProbe.chosen) == ["dd"], "a plain click on another file leaves only that one: \(names(SidebarProbe.chosen))")
            if results.allSatisfy(\.0) { if attempt > 1 { print("      (the click scenario needed \(attempt) tries: a click was lost on the way to the window)") }; break }
        }
        for (ok, what) in results { check(ok, what) }
        window.orderOut(nil); Self.testWindows.append(window)
        try? await Task.sleep(nanoseconds: 400_000_000)
        model.delete(pid)
    }
}
