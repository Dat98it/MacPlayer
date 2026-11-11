import AppKit
import Foundation
import MacPlayerCore

/// Renaming a project and moving it to the Trash, from the list of projects or from its editor. Only the project file is touched:
/// the videos and photos it uses never are. Both ask first; nothing is ever deleted for good.
extension AppDelegate {
    private func projectAlert(_ title: String, _ text: String = "") {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = title; a.informativeText = text; a.addButton(withTitle: L("OK")); a.runModal()
    }

    private func editors(of path: String) -> [EditorSession] {
        controllers.compactMap(\.session).filter { $0.isEditor && ($0.projectPath.map { PathUtil.same($0, path) } ?? false) }
    }

    // MARK: Rename

    @objc func renameCurrentProject(_ sender: Any?) {
        guard let s = activeEditor, let p = s.projectPath else { return }
        renameProject(path: p, projectID: s.project.id)
    }

    func renameProject(entry e: ProjectEntry) { renameProject(path: e.path, projectID: e.projectID) }

    /// Asks for a new name and renames the project file in its folder (the extension stays). Nothing is overwritten.
    func renameProject(path: String, projectID: UUID) {
        let name = PathUtil.fileName(of: path)
        guard env.fs.exists(path) else { projectAlert(LF("“%@” is not there any more.", name)); return }
        guard Drives.isConnected(path) else { projectAlert(L("The disk with this project is not connected.")); return }
        guard env.fs.isWritable(PathUtil.directory(of: path)) else { projectAlert(L("The project was not renamed."), L("Its folder cannot be written to.")); return }
        var typed = PathUtil.stem(of: path)
        while true {
            let field = NSTextField(string: typed)
            field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
            let a = NSAlert()
            a.messageText = LF("Rename the project “%@”", PathUtil.stem(of: path))
            a.informativeText = L("The project file is renamed; its extension stays. The videos and photos it uses are not changed.")
            a.accessoryView = field
            a.addButton(withTitle: L("Rename")); a.addButton(withTitle: L("Cancel"))
            a.window.initialFirstResponder = field
            guard a.runModal() == .alertFirstButtonReturn else { return }
            typed = field.stringValue
            do { try performRenameProject(path, toTyped: typed, projectID: projectID); return }
            catch let e as RenameError { projectAlert(L("The project was not renamed."), renameMessage(e)) }
            catch { projectAlert(L("The project was not renamed."), (error as? CustomStringConvertible)?.description ?? error.localizedDescription) }
        }
    }

    /// The renaming itself. The editors of the project write their last edits and pause; the file is renamed; then the list, the
    /// editors, the recovery data and the name inside the project follow. If the list cannot be updated, the file gets its old
    /// name back, so nothing is left half done.
    @discardableResult
    func performRenameProject(_ path: String, toTyped typed: String, projectID: UUID) throws -> String {
        let open = editors(of: path)
        for s in open { s.saveNow(); s.writingPaused = true }
        defer { for s in open { s.writingPaused = false } }
        let new = try FileOps.rename(path, toTyped: typed, fs: env.fs)
        env.projects.registry.moved(from: path, to: new)
        do { try env.projects.registry.save() } catch {
            _ = try? FileOps.rename(new, toTyped: PathUtil.stem(of: path), fs: env.fs)
            env.projects.registry.moved(from: new, to: path)
            throw error
        }
        env.projects.moved(from: new, to: new)      // tells the list to redraw
        let newName = PathUtil.stem(of: new)
        if open.isEmpty {
            // The name inside the file follows too (only the project file is written).
            if var p = try? env.projectStore.load(path: new) {
                p.name = newName
                if let fp = try? env.projectStore.saveFile(p, to: new, expected: try? env.fs.fingerprint(new)) { env.projects.noteSaved(p, path: new, fingerprint: fp) }
            }
        } else {
            for s in open {
                s.projectFileMoved(to: new)
                s.mutateQuietly { $0.name = newName }
                s.writingPaused = false
                s.noteUnsaved()
                s.saveNow()
            }
        }
        env.projectStore.updateSavedPath(projectID: projectID, to: new)
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: new))
        return new
    }

    // MARK: Trash

    @objc func trashCurrentProject(_ sender: Any?) {
        guard let s = activeEditor, let p = s.projectPath else { return }
        trashProject(path: p, projectID: s.project.id, entryID: env.projects.registry.entry(forPath: p)?.id)
    }

    func trashProject(entry e: ProjectEntry) { trashProject(path: e.path, projectID: e.projectID, entryID: e.id) }

    /// Moves the project file to the Trash after asking (Cancel is the default). Never deletes for good, never touches media.
    func trashProject(path: String, projectID: UUID, entryID: UUID?) {
        let name = PathUtil.fileName(of: path)
        guard env.fs.exists(path) else { projectAlert(LF("“%@” is not there any more.", name)); return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).flatMap { $0 }.map { Format.bytes($0.int64Value) } ?? ""
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = LF("Move the project “%@” to the Trash?", PathUtil.stem(of: path))
        a.informativeText = LF("Only the project file (%@) goes to the Trash, where you can put it back. The videos and photos it uses are not deleted or changed.", size)
        // The safe choice comes first and is the default (Return).
        a.addButton(withTitle: L("Cancel"))
        let go = a.addButton(withTitle: L("Move to Trash")); go.hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return }
        do { try performTrashProject(path, projectID: projectID, entryID: entryID) }
        catch { projectAlert(L("The project was not moved to the Trash."), LF("%@ Nothing was changed. MacPlayer never deletes a project for good.", error.localizedDescription)) }
    }

    /// The move itself. The editors write their last edits (so the file in the Trash is complete) and stop writing; then the file
    /// goes; only if it really went are the windows closed and the recovery data removed (so the project cannot come back by itself).
    func performTrashProject(_ path: String, projectID: UUID, entryID: UUID?) throws {
        guard ProjectFile.isProject(path: path) else { throw RenameError.failed("not a project file") }
        let open = editors(of: path)
        for s in open { s.saveNow(); s.writingPaused = true }
        do { try FileActions.trasher(URL(fileURLWithPath: path)) }
        catch { for s in open { s.writingPaused = false }; throw error }
        for c in controllers where open.contains(where: { $0 === c.session }) { c.closeTrashedProject() }
        env.projectStore.removeRecovery(projectID: projectID)
        if let id = entryID, let e = env.projects.registry.entry(id: id) { env.projects.remove(e) } else { env.projects.registry.remove(path: path); env.projects.refresh() }
    }

    // MARK: The list only

    /// Takes a project off the list. The file is not touched.
    func forgetProject(entry e: ProjectEntry) {
        let a = NSAlert()
        a.messageText = LF("Remove “%@” from the list?", e.name)
        a.informativeText = L("Only the list changes. The project file stays where it is; open it again to bring it back.")
        a.addButton(withTitle: L("Cancel")); a.addButton(withTitle: L("Remove from List"))
        guard a.runModal() == .alertSecondButtonReturn else { return }
        env.projects.remove(e)
    }

    /// A project file that is not where it was: the person shows where it is now.
    func findProject(entry e: ProjectEntry) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        p.allowedContentTypes = [UTTypeHelper.project].compactMap { $0 }
        p.message = LF("Where is “%@” now?", e.name)
        guard p.runModal() == .OK, let u = p.url else { return }
        if let found = try? env.projectStore.load(path: u.path), found.id != e.projectID {
            let a = NSAlert(); a.messageText = L("This looks like another project.")
            a.informativeText = L("Use it for this entry anyway?")
            a.addButton(withTitle: L("Use It")); a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        env.projects.registry.remove(id: e.id)
        env.projects.register(path: u.path)
    }
}

import UniformTypeIdentifiers
enum UTTypeHelper {
    static var project: UTType? { UTType(filenameExtension: ProjectFile.fileExtension) }
}
