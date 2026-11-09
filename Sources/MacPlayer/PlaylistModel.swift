import AVFoundation
import AppKit
import Combine
import MacPlayerCore
import MacPlayerMedia

@MainActor
protocol PlaylistHost: AnyObject {
    /// Opens the item in the window and starts it. Returns false if it could not be opened.
    func playPlaylistItem(url: URL, startAt: MediaTime?) async -> Bool
    func showPlaylistMessage(_ text: String, isError: Bool)
    /// The video being played left the playlist (removed from it, or the whole playlist was deleted): stop it and let go of it.
    /// `path` is the removed video's file, or nil when the whole playlist went. A video that was opened some other way is left alone.
    func stopPlaylistPlayback(path: String?)
    var hostHasUnsavedEdits: Bool { get }
    /// The slideshow was switched on or off: a photo that is showing starts or stops its countdown.
    func slideshowChanged()
}

extension PlaylistHost { func slideshowChanged() {} }

/// Several files chosen to be renamed: shown in a sheet that previews the new names. `blocked` says which ones are in use and why.
struct BatchRenameRequest: Identifiable {
    let id = UUID()
    var paths: [String]
    var blocked: [String: String]
}

struct FolderPreview: Identifiable {
    var id = UUID()
    /// The playlist the folder goes into, fixed when the person chose the folder (not whatever is selected when they confirm).
    var targetID: UUID?
    var url: URL
    var includeSubfolders = false
    var follow = false
    var sort: PlaylistSort = .naturalName
    var videos: [ScannedVideo] = []
    var skippedOther = 0
    var unreadable: [String] = []
    var scanning = true
}

/// All playlists, the selected one, and what is playing. Playlists are saved after every change.
@MainActor
final class PlaylistModel: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    /// The playlist on show. Remembered, so opening the app again lands on the same one.
    @Published var selectedID: UUID? { didSet { if selectedID != oldValue { env.prefs.lastPlaylistID = selectedID } } }
    @Published var query = ""
    @Published var status: String?
    @Published var folderPreview: FolderPreview?
    @Published var batchRename: BatchRenameRequest?
    /// The folders that are closed in the tree view, for each playlist (remembered while the app runs).
    @Published private(set) var collapsedFolders: [UUID: Set<String>] = [:]
    @Published private(set) var playingID: UUID?
    @Published private(set) var playingPlaylistID: UUID?
    /// While on, a photo stays for a few seconds and then the playlist moves on; videos play to their end as always.
    @Published private(set) var slideshowOn = false

    weak var host: PlaylistHost?
    /// The window that is playing the playlist's video. `host` follows whichever window was clicked last, which need not be this one.
    private weak var playingHost: PlaylistHost?
    private let env = AppEnvironment.shared!
    private var cursor: PlaylistCursor?
    /// Whose items the cursor walks. `playingPlaylistID` only changes once a video has actually opened, so it cannot say.
    private var cursorPlaylistID: UUID?
    private var scanTask: Task<Void, Never>?
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var followTimer: Timer?

    init() {
        let r = env.playlistStore.loadAll()
        playlists = r.playlists
        let last = env.prefs.lastPlaylistID
        selectedID = playlists.first(where: { $0.id == last })?.id ?? playlists.first?.id
        if !r.damaged.isEmpty { status = LF("%d playlist files could not be read and were left untouched.", r.damaged.count) }
        followTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.followTick() } }
        for p in playlists { refreshAvailability(p.id); probeMissing(p.id) }
    }

    var selected: Playlist? { playlists.first { $0.id == selectedID } }

    func index(_ id: UUID) -> Int? { playlists.firstIndex { $0.id == id } }

    private func mutate(_ id: UUID, _ f: (inout Playlist) -> Void) {
        guard let i = index(id) else { return }
        f(&playlists[i])
        playlists[i].modified = Date()
        persist(id)
        if id == cursorPlaylistID { cursor?.itemsChanged(playlists[i].items); cursor?.playMode = playlists[i].playMode; cursor?.repeatMode = playlists[i].repeatMode; cursor?.autoAdvance = playlists[i].autoAdvance }
    }

    /// Saves shortly after the last change, off the main thread.
    private func persist(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, let p = self.playlists.first(where: { $0.id == id }) else { return }
            let store = self.env.playlistStore
            await Task.detached { try? store.save(p) }.value
        }
    }

    // MARK: Lists

    @discardableResult
    func create(name: String? = nil) -> UUID {
        let p = Playlist(name: name ?? LF("Playlist %d", playlists.count + 1))
        playlists.append(p); selectedID = p.id
        try? env.playlistStore.save(p)
        return p.id
    }

    /// How the person is asked for the name of a new playlist: the suggested name goes in as a hint, and nil means they cancelled.
    /// Tests replace it, so that no dialog opens.
    static var nameAsker: (_ suggestion: String, _ note: String?) -> String? = { suggestion, note in
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = suggestion
        let a = NSAlert()
        a.messageText = L("New Playlist")
        a.informativeText = note ?? L("Give the playlist a name.")
        a.accessoryView = field
        a.addButton(withTitle: L("Create")); a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// A playlist the person has named: they are asked first, a name made of nothing is asked for again, and Cancel makes nothing.
    @discardableResult
    func createAsking() -> UUID? {
        var note: String?
        while true {
            guard let typed = Self.nameAsker(LF("Playlist %d", playlists.count + 1), note) else { return nil }
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return create(name: name) }
            note = L("A playlist needs a name.")
        }
    }

    func rename(_ id: UUID, to name: String) { let n = name.trimmingCharacters(in: .whitespaces); if !n.isEmpty { mutate(id) { $0.name = n } } }

    func duplicate(_ id: UUID) {
        guard let p = playlists.first(where: { $0.id == id }) else { return }
        let c = PlaylistEditor.duplicate(p, newName: LF("%@ copy", p.name))
        playlists.append(c); selectedID = c.id
        try? env.playlistStore.save(c)
    }

    /// Removes the playlist only. The videos stay exactly where they are.
    func delete(_ id: UUID) {
        if playingPlaylistID == id { endPlayback(path: nil) }
        env.playlistStore.delete(id)
        playlists.removeAll { $0.id == id }
        if selectedID == id { selectedID = playlists.first?.id }
    }

    // MARK: Items

    func makeItem(_ url: URL) -> PlaylistItem {
        let facts = Self.fileFacts(url.path)
        return PlaylistItem(path: url.path, bookmark: Bookmarks.make(url), modified: facts.modified ?? (try? env.fs.fingerprint(url.path))?.modified, created: facts.created, fileSize: facts.size)
    }

    /// When a file was created, last changed, and how big it is.
    nonisolated static func fileFacts(_ path: String) -> (created: Date?, modified: Date?, size: Int64?) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return (nil, nil, nil) }
        return (a[.creationDate] as? Date, a[.modificationDate] as? Date, (a[.size] as? NSNumber)?.int64Value)
    }

    /// Sorts a playlist. Creation dates and sizes are read first for videos added before the app kept them (a quick look at each file).
    func applyOrder(_ pid: UUID, _ order: PlaylistOrder) {
        guard order.key == .created || order.key == .size, let p = playlists.first(where: { $0.id == pid }) else { setOrder(pid, order); return }
        let lacking = p.items.filter { order.key == .created ? $0.created == nil : $0.fileSize == nil }.map { (id: $0.id, path: $0.path) }
        if lacking.isEmpty { setOrder(pid, order); return }
        Task {
            let facts = await Task.detached { lacking.map { ($0.id, Self.fileFacts($0.path)) } }.value
            mutate(pid) { pl in
                for (id, f) in facts { if let i = pl.items.firstIndex(where: { $0.id == id }) { pl.items[i].created = pl.items[i].created ?? f.created; pl.items[i].fileSize = pl.items[i].fileSize ?? f.size } }
            }
            setOrder(pid, order)
        }
    }

    /// Files and folders dropped or chosen. A folder adds the videos directly inside it.
    @discardableResult
    func add(urls: [URL], to playlistID: UUID? = nil, at index: Int? = nil, allowDuplicates: Bool = false) -> AddReport? {
        var files: [URL] = []
        var folderName: String?
        for u in urls {
            if env.fs.isDirectory(u.path) {
                folderName = folderName ?? u.lastPathComponent
                let r = FolderScanner.scan(folder: u.path, includeSubfolders: false, fs: env.fs)
                files += FolderScanner.sort(r.videos, by: .naturalName).map { URL(fileURLWithPath: $0.path) }
            } else { files.append(u) }
        }
        guard !files.isEmpty else { status = L("No videos were found."); return nil }
        let id = playlistID ?? selectedID ?? create(name: folderName)
        var report = AddReport()
        mutate(id) { p in report = PlaylistEditor.add(files.map(makeItem), to: &p, at: index, allowDuplicates: allowDuplicates) }
        if index == nil { reapplyOrder(id) }      // dropped at a chosen place: that place stands (and the list becomes manual below)
        else if !report.added.isEmpty { mutate(id) { $0.order = .manual } }
        selectedID = id
        var parts = [LF("%d added", report.added.count)]
        if !report.duplicates.isEmpty { parts.append(LF("%d already in the list", report.duplicates.count)) }
        if !report.unsupported.isEmpty { parts.append(LF("%d not video or photo files", report.unsupported.count)) }
        status = parts.joined(separator: " · ")
        probeMissing(id)
        return report
    }

    /// Takes videos out of the playlist (the files stay where they are). If one of them is playing, it stops: a video that is no longer
    /// in any list should not go on playing in the window.
    func remove(_ ids: Set<UUID>, from pid: UUID, remembering: Bool = true) {
        let playingPath = (pid == playingPlaylistID) ? playingID.flatMap { id in ids.contains(id) ? playlists.first { $0.id == pid }?.items.first { $0.id == id }?.path : nil } : nil
        mutate(pid) { PlaylistEditor.remove(ids, from: &$0, remembering: remembering) }
        if let path = playingPath { endPlayback(path: path) }
    }

    /// The playing video left the playlist: forget it here and make the window that plays it stop.
    private func endPlayback(path: String?) {
        let window = playingHost ?? host
        stop()
        window?.stopPlaylistPlayback(path: path)
    }
    /// Arranging by hand means the person's order is the order: an automatic one no longer applies.
    func move(_ offsets: IndexSet, to dest: Int, in pid: UUID) { mutate(pid) { PlaylistEditor.move(fromOffsets: offsets, toOffset: dest, in: &$0); $0.order = .manual } }

    /// Chooses how a playlist is kept in order, sorts it now, and keeps it so as videos are added or their lengths become known.
    /// Remembered with the playlist, so it is the same after the app is closed and opened again.
    func setOrder(_ pid: UUID, _ order: PlaylistOrder) {
        mutate(pid) { $0.order = order; $0.items = PlaylistEditor.sorted($0.items, by: order) }
    }

    /// Puts the list back in its order after something changed it (a video added, a length learnt). Nothing happens for a manual order,
    /// or when the order is already right (so nothing is saved or reshuffled for no reason).
    private func reapplyOrder(_ pid: UUID) {
        guard let p = playlists.first(where: { $0.id == pid }), p.order.isAutomatic else { return }
        let sorted = PlaylistEditor.sorted(p.items, by: p.order)
        if sorted.map(\.id) != p.items.map(\.id) { mutate(pid) { $0.items = sorted } }
    }
    func sort(_ pid: UUID, by s: PlaylistSort) { mutate(pid) { $0.items = PlaylistEditor.sorted($0.items, by: s) } }
    func setMode(_ pid: UUID, play: PlayMode? = nil, rep: RepeatMode? = nil, auto: Bool? = nil) {
        mutate(pid) { if let p = play { $0.playMode = p }; if let r = rep { $0.repeatMode = r }; if let a = auto { $0.autoAdvance = a } }
    }

    /// Part of "Refresh": takes out of the list the videos whose files are really gone from the disk (deleted, or only in the Trash).
    /// A video that was just moved or renamed is found again through its bookmark and kept. A video whose drive or folder is not
    /// reachable is kept too and counted, so an unplugged disk never empties a list. Files themselves are never touched.
    func pruneDeleted(_ pid: UUID) {
        guard let p = playlists.first(where: { $0.id == pid }) else { return }
        let snapshot = p.items.map { (id: $0.id, path: $0.path, bookmark: $0.bookmark) }
        let fs = env.fs
        Task {
            struct Verdict: Sendable { var id: UUID; var gone = false; var unknown = false; var movedTo: String? }
            let verdicts: [Verdict] = await Task.detached {
                snapshot.compactMap { item -> Verdict? in
                    switch MissingFiles.status(of: item.path, fs: fs, driveConnected: Drives.isConnected) {
                    case .present: return nil
                    case .unknown: return Verdict(id: item.id, unknown: true)
                    case .deleted:
                        if let moved = Bookmarks.resolve(item.bookmark), fs.exists(moved.path), !MissingFiles.isInTrash(moved.path) { return Verdict(id: item.id, movedTo: moved.path) }
                        return Verdict(id: item.id, gone: true)
                    }
                }
            }.value
            guard self.index(pid) != nil else { return }
            let moved = verdicts.filter { $0.movedTo != nil }
            if !moved.isEmpty {
                self.mutate(pid) { pl in
                    for v in moved { if let j = pl.items.firstIndex(where: { $0.id == v.id }), let to = v.movedTo { pl.items[j].path = to; pl.items[j].availability = .available } }
                }
            }
            let gone = Set(verdicts.filter(\.gone).map(\.id))
            if !gone.isEmpty { self.remove(gone, from: pid, remembering: false) }
            let unknown = verdicts.filter(\.unknown).count
            var parts: [String] = []
            if !gone.isEmpty { parts.append(LF("%d videos removed: their files are no longer on the disk.", gone.count)) }
            if !moved.isEmpty { parts.append(LF("%d moved videos found again.", moved.count)) }
            if unknown > 0 { parts.append(LF("%d videos not checked: their drive or folder is not connected.", unknown)) }
            self.status = parts.isEmpty ? L("Refreshed. Every video is still on the disk.") : parts.joined(separator: " · ")
        }
    }

    // MARK: Availability and durations (background, never blocks the list)

    func refreshAvailability(_ pid: UUID) {
        guard let p = playlists.first(where: { $0.id == pid }) else { return }
        let items = p.items.map { ($0.id, $0.path, $0.availability) }
        let fs = env.fs
        Task {
            let changes: [(UUID, Availability)] = await Task.detached {
                items.compactMap { id, path, old in
                    let now: Availability = fs.exists(path) ? (old == .missing ? .available : old) : .missing
                    return now != old ? (id, now) : nil
                }
            }.value
            guard !changes.isEmpty, let i = self.index(pid) else { return }
            for (id, a) in changes { if let j = self.playlists[i].items.firstIndex(where: { $0.id == id }) { self.playlists[i].items[j].availability = a } }
            self.persist(pid)
        }
    }

    /// Reads durations in the background, a few at a time.
    func probeMissing(_ pid: UUID) {
        guard let p = playlists.first(where: { $0.id == pid }) else { return }
        let todo = p.items.filter { $0.duration == nil && $0.availability != .missing && !$0.isImage }.map { ($0.id, $0.path) }
        // A picture has no length to find out; it only has to be readable.
        let pictures = p.items.filter { $0.isImage && $0.availability != .missing }.map { ($0.id, $0.path) }
        if !pictures.isEmpty {
            Task {
                let bad = await Task.detached(priority: .utility) { pictures.filter { (try? PhotoLoader.info(url: URL(fileURLWithPath: $0.1))) == nil }.map { $0.0 } }.value
                guard let i = self.index(pid) else { return }
                var changed = false
                for id in bad { if let j = self.playlists[i].items.firstIndex(where: { $0.id == id }), self.playlists[i].items[j].availability != .unreadable { self.playlists[i].items[j].availability = .unreadable; changed = true } }
                if changed { self.persist(pid) }
            }
        }
        guard !todo.isEmpty else { return }
        Task {
            for chunk in stride(from: 0, to: todo.count, by: 4).map({ Array(todo[$0..<min($0 + 4, todo.count)]) }) {
                let results: [(UUID, MediaInfo?)] = await withTaskGroup(of: (UUID, MediaInfo?).self) { group in
                    for (id, path) in chunk { group.addTask { (id, try? await MediaProbe.probe(url: URL(fileURLWithPath: path))) } }
                    var out: [(UUID, MediaInfo?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                guard let i = self.index(pid) else { return }
                for (id, info) in results {
                    guard let j = self.playlists[i].items.firstIndex(where: { $0.id == id }) else { continue }
                    if let info { self.playlists[i].items[j].duration = info.duration; if !(info.isPlayable || info.isExportable) { self.playlists[i].items[j].availability = .unsupported } }
                    else { self.playlists[i].items[j].availability = .unreadable }
                }
                self.persist(pid)
                if self.playlists[i].order.key == .duration { self.reapplyOrder(pid) }      // lengths just became known
            }
        }
    }

    // MARK: Folders (preview before adding; optional follow)

    func beginAddFolder(_ url: URL) {
        scanTask?.cancel()
        folderPreview = FolderPreview(targetID: selectedID, url: url)
        rescanPreview()
    }

    func rescanPreview() {
        guard var prev = folderPreview else { return }
        prev.scanning = true; folderPreview = prev
        scanTask?.cancel()
        let fs = env.fs
        let url = prev.url, sub = prev.includeSubfolders, sort = prev.sort
        let box = CancelBox()
        scanTask = Task {
            let result: FolderScanResult = await withTaskCancellationHandler {
                await Task.detached { FolderScanner.scan(folder: url.path, includeSubfolders: sub, fs: fs, isCancelled: { box.cancelled }) }.value
            } onCancel: { box.cancel() }
            guard !Task.isCancelled, var p = self.folderPreview, p.url == url else { return }
            p.videos = FolderScanner.sort(result.videos, by: sort); p.skippedOther = result.skippedOther; p.unreadable = result.unreadableFolders; p.scanning = false
            self.folderPreview = p
        }
    }

    func cancelFolderPreview() { scanTask?.cancel(); folderPreview = nil }

    func confirmFolderPreview() {
        guard let prev = folderPreview, !prev.videos.isEmpty else { folderPreview = nil; return }
        let pid = prev.targetID.flatMap { t in playlists.contains { $0.id == t } ? t : nil } ?? selectedID ?? create(name: prev.url.lastPathComponent)
        let src = PlaylistFolderSource(path: prev.url.path, bookmark: Bookmarks.make(prev.url), includeSubfolders: prev.includeSubfolders, follow: prev.follow, lastScan: Date(), sort: prev.sort)
        var items = prev.videos.map { v -> PlaylistItem in var i = makeItem(URL(fileURLWithPath: v.path)); i.folderSourceID = src.id; i.modified = v.modified; return i }
        if prev.sort == .duration { items = PlaylistEditor.sorted(items, by: .naturalName) } // durations arrive later; re-sort once known
        var report = AddReport()
        mutate(pid) { p in report = PlaylistEditor.add(items, to: &p); p.folderSources.append(src) }
        reapplyOrder(pid)
        status = LF("%d added", report.added.count) + (report.duplicates.isEmpty ? "" : " · " + LF("%d already in the list", report.duplicates.count))
        folderPreview = nil
        probeMissing(pid)
        if prev.sort == .duration { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.sort(pid, by: .duration) } }
    }

    // MARK: Files renamed or trashed from inside the app

    private func standard(_ path: String) -> String { (path as NSString).standardizingPath }

    /// The video file was renamed on the disk: every playlist that has it follows (same entry, new path and name).
    func fileRenamed(from old: String, to new: String) {
        let key = standard(old), url = URL(fileURLWithPath: new)
        let oldStem = PathUtil.stem(of: old), newStem = PathUtil.stem(of: new)
        for p in playlists where p.items.contains(where: { standard($0.path) == key }) {
            mutate(p.id) { pl in
                for j in pl.items.indices where standard(pl.items[j].path) == key {
                    pl.items[j].path = new
                    if pl.items[j].title == oldStem { pl.items[j].title = newStem }
                    pl.items[j].bookmark = Bookmarks.make(url)
                    pl.items[j].availability = .available
                }
            }
            reapplyOrder(p.id)
        }
    }

    /// The video file went to the Trash: every playlist drops it (and, if it was playing, stops). If the file is put back, a followed
    /// folder picks it up again, so it is not remembered as "taken out".
    func fileTrashed(_ path: String) {
        let key = standard(path)
        for p in playlists {
            let ids = Set(p.items.filter { standard($0.path) == key }.map(\.id))
            if !ids.isEmpty { remove(ids, from: p.id, remembering: false) }
        }
    }

    /// For the self-test only: puts ready-made entries in a playlist without looking at the disk.
    func replaceItemsForSelfTest(_ items: [PlaylistItem], in pid: UUID) { mutate(pid) { $0.items = items; $0.order = PlaylistOrder(key: .folder) } }

    // MARK: Folder tree

    func toggleFolder(_ path: String, in pid: UUID) {
        var set = collapsedFolders[pid] ?? []
        if !set.insert(path).inserted { set.remove(path) }
        collapsedFolders[pid] = set
    }

    /// Opens or closes every folder given (all of them, for "open all" and "close all").
    func setFolders(_ paths: [String], collapsed: Bool, in pid: UUID) {
        var set = collapsedFolders[pid] ?? []
        if collapsed { set.formUnion(paths) } else { set.subtract(paths) }
        collapsedFolders[pid] = set
    }

    // MARK: Folders in a playlist

    /// Turns following on or off for one folder of a playlist.
    func setFollow(_ sourceID: UUID, to on: Bool, in pid: UUID) {
        mutate(pid) { p in if let k = p.folderSources.firstIndex(where: { $0.id == sourceID }) { p.folderSources[k].follow = on } }
    }

    /// Stops using a folder in a playlist. With `removeVideos`, the videos that came from it leave the list too (the files stay where
    /// they are); a video of it that is playing stops. Without, they stay as ordinary entries.
    func removeFolder(_ sourceID: UUID, from pid: UUID, removeVideos: Bool) {
        guard let p = playlists.first(where: { $0.id == pid }) else { return }
        let ids = PlaylistEditor.itemIDs(ofSource: sourceID, in: p)
        mutate(pid) { PlaylistEditor.removeFolderSource(sourceID, from: &$0) }     // first: removing the videos must not mark them as "taken out"
        if removeVideos, !ids.isEmpty { remove(ids, from: pid) }
        status = removeVideos ? LF("%d videos removed from the list.", ids.count) : L("The folder is no longer followed.")
    }

    /// "Follow folder": adds new videos at the end, flags vanished ones, never removes anything.
    func refreshFolders(_ pid: UUID) {
        guard let p = playlists.first(where: { $0.id == pid }) else { return }
        let fs = env.fs
        let excluded = Set(p.excludedPaths)
        for src in p.folderSources {
            let items = p.items
            Task {
                let scan = await Task.detached { FolderScanner.scan(folder: src.path, includeSubfolders: src.includeSubfolders, fs: fs) }.value
                let change = FolderScanner.followChanges(items: items, sourceID: src.id, scan: scan, excluded: excluded)
                self.mutate(pid) { pl in
                    for v in change.newVideos { var i = self.makeItem(URL(fileURLWithPath: v.path)); i.folderSourceID = src.id; _ = PlaylistEditor.add([i], to: &pl) }
                    for id in change.nowMissing { if let j = pl.items.firstIndex(where: { $0.id == id }) { pl.items[j].availability = .missing } }
                    for id in change.backAgain { if let j = pl.items.firstIndex(where: { $0.id == id }) { pl.items[j].availability = .available } }
                    if let k = pl.folderSources.firstIndex(where: { $0.id == src.id }) { pl.folderSources[k].lastScan = Date() }
                }
                if !change.newVideos.isEmpty { self.reapplyOrder(pid); self.status = LF("%d new videos added from the folder.", change.newVideos.count); self.probeMissing(pid) }
                if !scan.unreadableFolders.isEmpty { self.status = L("A followed folder cannot be read (is the drive connected?). Nothing was removed.") }
            }
        }
    }

    private func followTick() {
        for p in playlists where p.folderSources.contains(where: \.follow) { refreshFolders(p.id) }
    }

    // MARK: Playing

    func play(_ itemID: UUID, in pid: UUID, startAt: MediaTime? = nil) {
        guard let p = playlists.first(where: { $0.id == pid }), p.items.contains(where: { $0.id == itemID }) else { return }
        if cursorPlaylistID != pid || cursor == nil { cursor = PlaylistCursor(playlist: p); cursorPlaylistID = pid }
        cursor?.select(itemID)
        Task { await open(itemID, in: pid, startAt: startAt) }
    }

    func playSelected(_ pid: UUID) {
        guard let p = playlists.first(where: { $0.id == pid }), !p.items.isEmpty else { return }
        let start = p.currentItemID.flatMap { id in p.items.contains { $0.id == id } ? id : nil } ?? p.items.first(where: { $0.availability.isPlayable })?.id ?? p.items[0].id
        let resume = (start == p.currentItemID) ? p.resumePosition : nil
        switch env.prefs.resumeBehavior {
        case .always: play(start, in: pid, startAt: resume)
        case .never: play(start, in: pid)
        case .ask:
            if let r = resume, r.seconds > 5 {
                let a = NSAlert(); a.messageText = L("Continue where you stopped?"); a.informativeText = LF("Resume at %@.", Timecode.format(r))
                a.addButton(withTitle: L("Continue")); a.addButton(withTitle: L("Start Over"))
                play(start, in: pid, startAt: a.runModal() == .alertFirstButtonReturn ? r : nil)
            } else { play(start, in: pid) }
        }
    }

    private func open(_ itemID: UUID, in pid: UUID, startAt: MediaTime?) async {
        guard let i = index(pid), let item = playlists[i].items.first(where: { $0.id == itemID }) else { return }
        var url = URL(fileURLWithPath: item.path)
        if !env.fs.exists(url.path), let moved = Bookmarks.resolve(item.bookmark), env.fs.exists(moved.path) {
            url = moved
            mutate(pid) { p in if let j = p.items.firstIndex(where: { $0.id == itemID }) { p.items[j].path = moved.path; p.items[j].availability = .available } }
        }
        let window = host
        let ok = env.fs.exists(url.path) ? await (window?.playPlaylistItem(url: url, startAt: startAt) ?? false) : false
        if ok {
            playingID = itemID; playingPlaylistID = pid; playingHost = window
            mutate(pid) { $0.currentItemID = itemID }
        } else {
            let a: Availability = env.fs.exists(url.path) ? .unreadable : .missing
            mutate(pid) { p in if let j = p.items.firstIndex(where: { $0.id == itemID }) { p.items[j].availability = a } }
            host?.showPlaylistMessage(LF("“%@” cannot be played. Skipping.", item.title), isError: true)
            advance(auto: true)
        }
    }

    /// The video ended (auto: true) or the user pressed Next.
    func advance(auto: Bool) {
        guard let pid = playingPlaylistID ?? selectedID, let p = playlists.first(where: { $0.id == pid }) else { return }
        if cursor == nil || cursorPlaylistID != pid { cursor = PlaylistCursor(playlist: p); cursorPlaylistID = pid }
        if auto, host?.hostHasUnsavedEdits == true { host?.showPlaylistMessage(L("Stopped: the current video has unsaved edits."), isError: false); return }
        guard let r = cursor?.next(userInitiated: !auto, isPlayable: { $0.availability.isPlayable }) else { return }
        handle(r, pid)
    }

    func previous() {
        guard let pid = playingPlaylistID, cursor != nil, cursorPlaylistID == pid else { return }
        if let r = cursor?.previous(isPlayable: { $0.availability.isPlayable }) { handle(r, pid) }
    }

    private func handle(_ r: Advance, _ pid: UUID) {
        switch r {
        case .play(let id): Task { await open(id, in: pid, startAt: nil) }
        case .stop(let reason):
            switch reason {
            case .endOfList: host?.showPlaylistMessage(L("End of the playlist."), isError: false)
            case .noPlayableItems: host?.showPlaylistMessage(L("No video in this playlist can be played."), isError: true)
            case .autoAdvanceOff: break
            case .emptyList: host?.showPlaylistMessage(L("The playlist is empty."), isError: false)
            }
        }
    }

    func toggleSlideshow() { slideshowOn.toggle(); (playingHost ?? host)?.slideshowChanged() }
    func stopSlideshow() { guard slideshowOn else { return }; slideshowOn = false; (playingHost ?? host)?.slideshowChanged() }

    /// Development aid: shows a file as the open one without opening it (for looking at how the open file is marked).
    func markPlayingForDev(_ id: UUID, in pid: UUID) { playingID = id; playingPlaylistID = pid }

    func stop() { slideshowOn = false; cursor = nil; cursorPlaylistID = nil; playingID = nil; playingPlaylistID = nil; playingHost = nil }

    /// Where the viewer stopped, so reopening the playlist continues from there.
    func rememberResume(_ position: MediaTime) {
        guard let pid = playingPlaylistID else { return }
        mutate(pid) { $0.resumePosition = position }
    }
}

final class CancelBox: @unchecked Sendable {
    private let l = NSLock(); private var c = false
    var cancelled: Bool { l.lock(); defer { l.unlock() }; return c }
    func cancel() { l.lock(); c = true; l.unlock() }
}
