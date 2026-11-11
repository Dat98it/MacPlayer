import Foundation
import MacPlayerCore

/// Writes one project into its file, one write at a time and in order, off the main thread. Each write first refreshes the crash
/// copy (MacPlayer's own folder), then writes the project file (checked against what MacPlayer last left there, so a change made
/// by someone else is never overwritten), then keeps a restore point now and then. Only project files are ever written.
final class ProjectFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacPlayer.ProjectFileWriter", qos: .utility)
    private let store: ProjectStore
    // Touched only on `queue`.
    private var path: String?
    private var expected: FileFingerprint?
    private var fileSchema = Project.currentSchema
    private var projectID: UUID?
    private var forceNext = false
    // Touched only on the main thread.
    private var requested = 0
    private let latest = Latest()

    private final class Latest: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    init(store: ProjectStore) { self.store = store }

    /// The file this writer keeps up to date, and the file as it is now (nil when it should not be compared, e.g. after recovery).
    func begin(path: String, expected: FileFingerprint?, fileSchema: Int, projectID: UUID, force: Bool = false) {
        queue.sync {
            self.path = path; self.expected = expected; self.fileSchema = fileSchema; self.projectID = projectID; self.forceNext = force
        }
    }

    /// The project file was renamed or moved by MacPlayer.
    func moved(to path: String, expected: FileFingerprint?) {
        queue.sync { self.path = path; if let expected { self.expected = expected } }
    }

    /// Writes in the background. An older write that is still waiting when a newer one arrives is dropped: the newer one has it all.
    func write(_ project: Project, force: Bool, completion: @escaping @Sendable (Result<FileFingerprint, Error>) -> Void) {
        requested += 1
        let n = requested
        latest.set(n)
        queue.async { [self] in
            guard n == latest.get() else { return }
            let r = perform(project, force: force)
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Writes and waits (after anything already waiting).
    func writeNow(_ project: Project, force: Bool) -> Result<FileFingerprint, Error> {
        requested += 1
        latest.set(requested)
        return queue.sync { perform(project, force: force) }
    }

    private func perform(_ project: Project, force: Bool) -> Result<FileFingerprint, Error> {
        guard let path else { return .failure(ProjectSaveError.folderMissing("")) }
        // The crash copy first: if the project's disk is gone, the edits are still safe on this Mac.
        try? store.autosave(project, savedPath: path)
        if fileSchema < Project.currentSchema, let id = projectID { store.keepPreUpgradeCopy(of: path, projectID: id, fileSchema: fileSchema) }
        do {
            let fp = try store.saveFile(project, to: path, expected: expected, force: force || forceNext)
            expected = fp; fileSchema = Project.currentSchema; forceNext = false
            try? store.takeSnapshot(project)
            return .success(fp)
        } catch {
            return .failure(error)
        }
    }
}
