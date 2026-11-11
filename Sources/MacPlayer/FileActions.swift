import AppKit
import Foundation
import MacPlayerCore

enum FileActions {
    /// What moves a file to the Trash. Tests replace it so they do not fill the person's real Trash.
    @MainActor static var trasher: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
}

/// Renaming a video file and moving it to the Trash from inside the app. Both ask first, never overwrite or delete for good, and keep
/// the playlists and the open windows in step with what happened on the disk.
extension AppDelegate {
    private func standard(_ path: String) -> String { PathUtil.key(path) }

    func windows(showing path: String) -> [MainWindowController] {
        controllers.filter { c in c.session?.role == .viewer && (c.session?.sourceURL.map { standard($0.path) == standard(path) } ?? false) }
    }

    private func alert(_ title: String, _ text: String = "", style: NSAlert.Style = .warning) {
        let a = NSAlert(); a.alertStyle = style; a.messageText = title; a.informativeText = text
        a.addButton(withTitle: L("OK")); a.runModal()
    }

    /// Reasons not to touch the file now; nil when it is free.
    func reasonBusy(_ path: String) -> String? {
        let name = PathUtil.fileName(of: path)
        let key = standard(path)
        if env.exports.queue.jobs.contains(where: { j in
            switch j.state { case .queued, .running: return j.sourcePaths.contains { standard($0) == key }; default: return false }
        }) { return LF("An export is using “%@”. Wait for it to finish, or cancel it, first.", name) }
        return nil
    }

    // MARK: Rename

    func renameFile(at path: String) {
        let name = PathUtil.fileName(of: path)
        guard env.fs.exists(path) else { alert(LF("“%@” is not there any more.", name)); return }
        if let busy = reasonBusy(path) { alert(L("The file cannot be renamed now."), busy); return }
        var typed = PathUtil.stem(of: path)
        while true {
            let field = NSTextField(string: typed)
            field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
            let a = NSAlert()
            a.messageText = LF("Rename “%@”", name)
            a.informativeText = L("The video file on the disk is renamed; the extension stays. Projects that use it by its old name will have to find it again.")
            a.accessoryView = field
            a.addButton(withTitle: L("Rename")); a.addButton(withTitle: L("Cancel"))
            a.window.initialFirstResponder = field
            guard a.runModal() == .alertFirstButtonReturn else { return }
            typed = field.stringValue
            do {
                try performRename(path, toTyped: typed)
                return
            } catch let e as RenameError {
                alert(L("The file was not renamed."), renameMessage(e))
            } catch { alert(L("The file was not renamed."), error.localizedDescription) }
        }
    }

    /// The renaming itself, after the person has said yes: the file, then the playlists and windows that have it.
    @discardableResult
    func performRename(_ path: String, toTyped typed: String) throws -> String {
        let new = try FileOps.rename(path, toTyped: typed, fs: env.fs)
        didRename(from: path, to: new)
        return new
    }

    func renameMessage(_ e: RenameError) -> String {
        switch e {
        case .sourceMissing: return L("The file is not there any more.")
        case .emptyName: return L("The name is empty.")
        case .invalidCharacters: return L("A name cannot contain / or : or control characters.")
        case .hiddenName: return L("A name cannot start with a dot: the file would become hidden.")
        case .tooLong: return L("The name is too long.")
        case .sameName: return L("That is already its name.")
        case .exists: return L("A file with this name is already in the folder. Nothing was changed.")
        case .failed(let m): return LF("The disk refused: %@", m)
        }
    }

    private func didRename(from old: String, to new: String, announce: Bool = true) {
        let url = URL(fileURLWithPath: new)
        for c in windows(showing: old) { c.reopen(at: url) }
        playlists.fileRenamed(from: old, to: new)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if announce { playlists.status = LF("“%@” was renamed to “%@”.", PathUtil.fileName(of: old), PathUtil.fileName(of: new)) }
    }

    // MARK: Trash

    func trashFile(at path: String) {
        let name = PathUtil.fileName(of: path)
        guard env.fs.exists(path) else { alert(LF("“%@” is not there any more.", name)); return }
        if let busy = reasonBusy(path) { alert(L("The file cannot be moved to the Trash now."), busy); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).flatMap { $0 }.map { Format.bytes($0.int64Value) } ?? ""
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = LF("Move “%@” to the Trash?", name)
        a.informativeText = LF("The file (%@) leaves its folder and goes to the Trash, where you can put it back. It is also taken out of every playlist that has it.", size)
        // The safe choice comes first and is the default (Return); moving to the Trash has to be chosen on purpose.
        a.addButton(withTitle: L("Cancel"))
        let go = a.addButton(withTitle: L("Move to Trash")); go.hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return }
        do { try performTrash(path) }
        catch { alert(L("The file was not moved to the Trash."), LF("%@ Nothing was changed.", error.localizedDescription)) }
    }

    /// The move itself, after the person has said yes. The file goes first; the windows and playlists follow only if it really went.
    func performTrash(_ path: String, announce: Bool = true) throws {
        let name = PathUtil.fileName(of: path)
        try FileActions.trasher(URL(fileURLWithPath: path))
        for c in windows(showing: path) { c.closeVideo(confirm: { _ in true }) }
        playlists.fileTrashed(path)
        if announce { playlists.status = LF("“%@” was moved to the Trash.", name) }
    }

    // MARK: Several files at once

    /// The same file listed twice (two playlists, or twice in one) is touched once. The order is kept.
    private func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(standard($0)).inserted }
    }

    /// For each file that is in use right now, why it cannot be touched.
    func busyReasons(_ paths: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for p in paths { if let why = reasonBusy(p) { out[p] = why } }
        return out
    }

    /// One file asks for its own question; several open a sheet where the new names are chosen and shown before anything happens.
    func renameFiles(at paths: [String]) {
        let list = unique(paths)
        if list.count == 1 { renameFile(at: list[0]) }
        else if list.count > 1 { playlists.batchRename = BatchRenameRequest(paths: list, blocked: busyReasons(list)) }
    }

    /// The renaming of several files, after the person has said yes in the sheet. All or nothing on the disk; then the playlists and windows follow.
    @discardableResult
    func performBatchRename(paths: [String], rule: BatchRenameRule) throws -> [BatchRename.Renamed] {
        let plan = BatchRename.plan(paths: paths, rule: rule, blocked: busyReasons(paths), fs: env.fs)
        let done = try BatchRename.apply(plan, fs: env.fs)
        for r in done { didRename(from: r.old, to: r.new, announce: false) }
        playlists.status = LF("%d files were renamed.", done.count)
        return done
    }

    func trashFiles(at paths: [String]) {
        let list = unique(paths)
        if list.count == 1 { trashFile(at: list[0]); return }
        guard !list.isEmpty else { return }
        let present = list.filter { env.fs.exists($0) }
        let busy = busyReasons(present)
        let free = present.filter { busy[$0] == nil }
        guard !free.isEmpty else {
            alert(L("The files cannot be moved to the Trash now."), busy.values.sorted().prefix(5).joined(separator: "\n"))
            return
        }
        let bytes = free.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? NSNumber).flatMap { $0 }?.int64Value ?? 0) }
        var names = free.prefix(6).map { "• " + PathUtil.fileName(of: $0) }
        if free.count > 6 { names.append(LF("…and %d more", free.count - 6)) }
        var text = names.joined(separator: "\n") + "\n\n" + LF("The %d files (%@) leave their folders and go to the Trash, where you can put them back. They are also taken out of every playlist that has them.", free.count, Format.bytes(bytes))
        let left = present.count - free.count
        if left > 0 { text += "\n" + LF("%d files are in use and will stay where they are.", left) }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = LF("Move %d files to the Trash?", free.count)
        a.informativeText = text
        // The safe choice comes first and is the default (Return); moving to the Trash has to be chosen on purpose.
        a.addButton(withTitle: L("Cancel"))
        let go = a.addButton(withTitle: L("Move to Trash")); go.hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return }
        let r = performTrashes(free)
        if !r.failed.isEmpty {
            alert(LF("%d files could not be moved to the Trash.", r.failed.count),
                  r.failed.prefix(5).map { "“" + PathUtil.fileName(of: $0.path) + "”: " + $0.reason }.joined(separator: "\n") + "\n" + L("The others were moved. Nothing else was changed."))
        }
    }

    /// The moving of several files, after the person has said yes. One file that the Trash refuses does not stop the others.
    @discardableResult
    func performTrashes(_ paths: [String]) -> (trashed: [String], failed: [(path: String, reason: String)]) {
        var trashed: [String] = [], failed: [(path: String, reason: String)] = []
        for p in unique(paths) {
            do { try performTrash(p, announce: false); trashed.append(p) }
            catch { failed.append((p, error.localizedDescription)) }
        }
        playlists.status = failed.isEmpty ? LF("%d files were moved to the Trash.", trashed.count) : LF("%d files were moved to the Trash, %d could not be.", trashed.count, failed.count)
        return (trashed, failed)
    }

    // MARK: Menu commands (the video of the active window)

    @objc func renameCurrentFile(_ sender: Any?) { if let s = activeSession, s.role == .viewer, let u = s.sourceURL { renameFile(at: u.path) } }
    @objc func trashCurrentFile(_ sender: Any?) { if let s = activeSession, s.role == .viewer, let u = s.sourceURL { trashFile(at: u.path) } }
}
