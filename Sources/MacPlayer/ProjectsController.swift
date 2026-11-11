import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// The list of projects for the whole app (every window shows the same one): the registry, the pictures on the cards, and the
/// first look for projects made before the list existed.
@MainActor
final class ProjectsController: ObservableObject {
    let registry: ProjectRegistry
    let thumbsFolder: URL
    private let fs: FileSystem
    private let prefs: AppPreferences
    /// Bumped when a card's picture changes, so the list redraws it.
    @Published private(set) var thumbVersion = 0
    @Published private(set) var version = 0

    init(fs: FileSystem, folder: URL, prefs: AppPreferences) {
        self.fs = fs; self.prefs = prefs
        thumbsFolder = folder.appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
        let env = ProjectRegistry.Environment(
            resolveBookmark: { Bookmarks.resolve($0)?.path },
            makeBookmark: { Bookmarks.make(URL(fileURLWithPath: $0)) },
            driveConnected: { Drives.isConnected($0) },
            isInTrash: { ProjectsController.isInTrash($0) })
        registry = ProjectRegistry(fs: fs, path: folder.appendingPathComponent("registry.json").path, environment: env)
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/") || path.hasPrefix((NSHomeDirectory() as NSString).appendingPathComponent(".Trash") + "/")
    }

    private func changed() { try? registry.save(); version += 1 }

    func visible(filter: ProjectFilter, sort: ProjectSort, query: String) -> [ProjectEntry] { registry.visible(filter: filter, sort: sort, query: query) }

    func refresh() { registry.refresh(); changed() }

    @discardableResult
    func register(path: String, opened: Bool = false) -> ProjectEntry? {
        defer { changed() }
        if opened { prefs.lastProjectFolder = PathUtil.directory(of: path) }
        return registry.register(path: path, opened: opened)
    }

    func noteSaved(_ p: Project, path: String, fingerprint: FileFingerprint?) {
        if registry.entry(forPath: path) == nil { registry.register(path: path) }
        registry.noteSaved(p, at: path, fingerprint: fingerprint)
        changed()
    }

    func moved(from old: String, to new: String) { registry.moved(from: old, to: new); changed() }

    func remove(_ e: ProjectEntry) {
        registry.remove(id: e.id)
        try? FileManager.default.removeItem(at: thumbnailURL(e.projectID))
        changed()
    }

    // MARK: Pictures on the cards

    func thumbnailURL(_ projectID: UUID) -> URL { thumbsFolder.appendingPathComponent(projectID.uuidString + ".jpg") }

    func thumbnail(_ projectID: UUID) -> NSImage? {
        _ = thumbVersion
        let u = thumbnailURL(projectID)
        return FileManager.default.fileExists(atPath: u.path) ? NSImage(contentsOf: u) : nil
    }

    /// Keeps a small picture of the project for its card (MacPlayer's own folder; never next to the project or its media).
    func storeThumbnail(_ image: CGImage, projectID: UUID) {
        let url = thumbnailURL(projectID)
        let small = Self.scaled(image, maxSide: 480) ?? image
        Task.detached(priority: .utility) {
            try? ImageWriter.write(small, to: url, format: .jpeg(quality: 0.8))
            await MainActor.run { [weak self] in self?.thumbVersion += 1 }
        }
    }

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let k = Double(maxSide) / Double(max(image.width, image.height))
        guard k < 1 else { return image }
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: First run

    /// Projects made before the list existed: the recent files and the crash copies MacPlayer knows about. The disk is not searched.
    func importKnownProjectsOnce(store: ProjectStore, isSandbox: Bool) {
        guard !prefs.projectsImported else { return }
        prefs.projectsImported = true
        // A test run (--sandbox) never reads the person's own recent files.
        if !isSandbox { for u in NSDocumentController.shared.recentDocumentURLs where ProjectFile.isProject(u) && fs.exists(u.path) { registry.register(path: u.path) } }
        for c in store.recoverable() { if let p = c.savedPath, fs.exists(p) { registry.register(path: p) } }
        changed()
    }
}
