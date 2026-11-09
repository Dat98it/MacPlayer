import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import MacPlayerCore
import MacPlayerMedia

/// Small stills for playlist rows, loaded only when a row appears (lazy) and a couple at a time.
@MainActor
final class RowThumbs {
    static let shared = RowThumbs()
    private let cache = NSCache<NSString, NSImage>()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func image(for path: String, large: Bool = false) async -> NSImage? {
        let key = (large ? path + "#large" : path) as NSString
        if let c = cache.object(forKey: key) { return c }
        while running >= 2 { await withCheckedContinuation { waiting.append($0) } }
        running += 1
        defer { running -= 1; if !waiting.isEmpty { waiting.removeFirst().resume() } }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let size = large ? CGSize(width: 360, height: 203) : CGSize(width: 120, height: 68)
        let still: CGImage?
        if ImageFiles.isCandidate(path) { still = await Task.detached(priority: .utility) { PhotoLoader.thumbnail(url: URL(fileURLWithPath: path), maxSize: size) }.value }
        else { still = try? await FrameGrabber.representativeImage(url: URL(fileURLWithPath: path), maxSize: size) }
        guard let cg = still else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        cache.setObject(img, forKey: key)
        return img
    }
}

enum SidebarTab: String { case playlists, recent }

struct PlaylistSidebar: View {
    @ObservedObject var model: PlaylistModel
    @StateObject private var chosen = Box<Set<UUID>>([])
    @StateObject private var tab = Box<SidebarTab>(AppEnvironment.shared.prefs.sidebarShowsRecent ? .recent : .playlists)
    @ObservedObject private var info = ItemInfoStore.shared
    @StateObject private var sortOpen = Box<Bool>(false)
    @StateObject private var pickerOpen = Box<Bool>(false)
    @StateObject private var hoverPlaylist = Box<UUID?>(nil)
    @StateObject private var foldersOpen = Box<Bool>(false)
    @StateObject private var layout = Box<PlaylistLayout>(AppEnvironment.shared.prefs.playlistLayout)
    @StateObject private var anchor = Box<UUID?>(nil)
    @StateObject private var recentQuery = Box<String>("")
    @StateObject private var recentTick = Box<Int>(0)
    @StateObject private var renaming = Box<Bool>(false)
    @StateObject private var nameDraft = Box<String>("")
    @StateObject private var hideTreeHint = Box<Bool>(false)
    var openURL: (URL) -> Void

    /// What a playlist can be sorted by, and what each direction means for it.
    struct SortKey: Identifiable {
        let key: PlaylistSort
        let label: String
        let icon: String
        let ascending: String
        let descending: String
        /// Which way the first choice of this key goes: names and lengths from the smallest, dates and sizes from the newest or biggest.
        let startsDescending: Bool
        var id: String { key.rawValue }
    }

    static var sortKeys: [SortKey] {
        [SortKey(key: .naturalName, label: L("Name"), icon: "textformat", ascending: L("A → Z"), descending: L("Z → A"), startsDescending: false),
         SortKey(key: .created, label: L("Date created"), icon: "calendar.badge.plus", ascending: L("Oldest first"), descending: L("Newest first"), startsDescending: true),
         SortKey(key: .modified, label: L("Date modified"), icon: "calendar", ascending: L("Oldest first"), descending: L("Newest first"), startsDescending: true),
         SortKey(key: .duration, label: L("Length"), icon: "clock", ascending: L("Shortest first"), descending: L("Longest first"), startsDescending: false),
         SortKey(key: .size, label: L("File size"), icon: "externaldrive", ascending: L("Smallest first"), descending: L("Largest first"), startsDescending: true),
         SortKey(key: .folder, label: L("Folder"), icon: "folder", ascending: L("A → Z"), descending: L("Z → A"), startsDescending: false)]
    }

    /// "Date created · Newest first", or nil for a list in the order the person arranged.
    /// "12 videos · 1:03:20", "40 photos", or "52 items · 1:03:20" for a mix.
    static func summary(_ p: Playlist) -> String {
        let n = p.items.count, photos = p.items.filter(\.isImage).count
        let what = photos == 0 ? LF("%d videos", n) : (photos == n ? LF("%d photos", n) : LF("%d items", n))
        return p.totalDuration > .zero ? what + " · " + Format.duration(p.totalDuration) : what
    }

    /// How long a video is, or "Photo" for a picture (which has no length).
    static func lengthText(_ item: PlaylistItem) -> String { item.isImage ? L("Photo") : (item.duration.map(Format.duration) ?? "–") }

    static func orderLabel(_ order: PlaylistOrder) -> String? {
        guard let k = sortKeys.first(where: { $0.key == order.key }) else { return nil }
        return k.label + " · " + (order.descending ? k.descending : k.ascending)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab.value }, set: { tab.value = $0; AppEnvironment.shared.prefs.sidebarShowsRecent = ($0 == .recent) })) { Text(L("Playlists")).tag(SidebarTab.playlists); Text(L("Recent")).tag(SidebarTab.recent) }
                .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            if tab.value == .recent { recent } else { playlists }
        }
        .coordinateSpace(name: "macplayer.sidebar")
        .sheet(item: Binding(get: { model.folderPreview }, set: { if $0 == nil { model.cancelFolderPreview() } })) { _ in FolderSheet(model: model) }
    }

    // MARK: Recent

    private var recent: some View {
        _ = recentTick.value      // the list is re-read when this changes (a file was opened, or the list was cleared)
        let all = NSDocumentController.shared.recentDocumentURLs
        let urls = RecentFiles.search(all, query: recentQuery.value)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(L("Search recent files"), text: $recentQuery.value).textFieldStyle(.roundedBorder)
                Button(L("Clear All")) { (NSApp.delegate as? AppDelegate)?.clearRecentFiles(nil) }
                    .disabled(all.isEmpty).help(L("Clear the list of recent files. The video files are not deleted."))
            }.padding(8)
            List {
                if all.isEmpty { Text(L("Nothing opened yet.")).foregroundColor(.secondary) }
                else if urls.isEmpty { Text(LF("No recent file matches “%@”.", recentQuery.value)).foregroundColor(.secondary) }
                ForEach(urls, id: \.self) { u in
                    Label(u.lastPathComponent, systemImage: ProjectFile.isProject(u) ? "doc.text" : "film").lineLimit(1)
                        .help(u.path)
                        .onTapGesture(count: 2) { openURL(u) }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .onAppear { recentTick.value += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .recentsChanged)) { _ in recentTick.value += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in recentTick.value += 1 }
    }

    // MARK: Playlists

    private var playlists: some View {
        VStack(spacing: 0) {
            playlistPicker.padding(8)

            if let p = model.selected { actionBar(p) }
            if let p = model.selected {
                header(p)
                TextField(L("Search this playlist"), text: $model.query).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 6)
                HStack(spacing: 6) {
                    sortButton(p)
                    Spacer(minLength: 0)
                    Picker("", selection: Binding(get: { layout.value }, set: { layout.value = $0; AppEnvironment.shared.prefs.playlistLayout = $0 })) {
                        Image(systemName: "list.bullet").accessibilityLabel(L("Show as a list")).tag(PlaylistLayout.list)
                        Image(systemName: "square.grid.2x2").accessibilityLabel(L("Show as a grid")).tag(PlaylistLayout.grid)
                        Image(systemName: "list.bullet.indent").accessibilityLabel(L("Show as a folder tree")).tag(PlaylistLayout.tree)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 88).help(L("List, grid or folder tree"))
                }.padding(.horizontal, 8).padding(.bottom, 6)
                // Only a count here: this runs at every redraw. The files themselves are listed when a button is pressed.
                let pickedCount = chosen.value.isEmpty ? 0 : p.items.reduce(0) { chosen.value.contains($1.id) ? $0 + 1 : $0 }
                if pickedCount > 0 { selectionBar(p, count: pickedCount) }
                if layout.value == .tree { treeBar(p); treeHint(p) }
                if layout.value == .grid { grid(p) } else if layout.value == .tree { tree(p) } else { list(p) }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 42)).foregroundColor(.accentColor).accessibilityHidden(true)
                    Text(L("No playlists yet")).font(.headline)
                    Text(L("Create a playlist, then drop videos, photos or a folder here.")).multilineTextAlignment(.center).foregroundColor(.secondary).padding(.horizontal, 20)
                    Button { model.create() } label: { Label(L("New Playlist"), systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
                    Spacer()
                }.frame(maxWidth: .infinity)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in load(providers) { model.add(urls: $0) }; return true }
            }
            footer
        }
        .onAppear {
            _ = ClickKeys.shared          // starts noting the keys held at each press
            devTree()
            // Development aid: open one of the pop-overs a moment after the panel is shown, to look at it.
            guard let which = ProcessInfo.processInfo.environment["MACPLAYER_OPEN_POPOVER"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if which == "sort" { sortOpen.value = true } else if which == "picker" { pickerOpen.value = true } else if which == "tip", let it = model.selected?.items.dropFirst(2).first { ItemInfoStore.shared.hover(it, entered: true) } }
        }
        .sheet(item: $model.batchRename) { request in BatchRenameSheet(model: model, request: request) }
        .alert(L("Rename Playlist"), isPresented: $renaming.value) {
            TextField(L("Name"), text: $nameDraft.value)
            Button(L("Rename")) { if let id = model.selectedID { model.rename(id, to: nameDraft.value) } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    /// Development aid, for looking at the tree and the choosing of files: MACPLAYER_DEV_TREE=<folder> makes a playlist of everything under
    /// the folder (subfolders too) and shows it as a tree; MACPLAYER_DEV_SIDEBAR may add "select" (chooses the first files) and
    /// "rename" (opens the sheet for them a moment later). Nothing is renamed: the sheet only previews.
    private func devTree() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MACPLAYER_DEV_TREE"], model.selected?.name != "Demo" else { return }
        let found = FolderScanner.scan(folder: dir, includeSubfolders: true, fs: AppEnvironment.shared.fs)
        let id = model.create(name: "Demo")
        model.add(urls: FolderScanner.sort(found.videos, by: .naturalName).map { URL(fileURLWithPath: $0.path) }, to: id)
        model.setOrder(id, PlaylistOrder(key: .folder))
        let tokens = env["MACPLAYER_DEV_SIDEBAR"] ?? ""
        layout.value = tokens.contains("list") ? .list : (tokens.contains("grid") ? .grid : .tree)
        let first = Array((model.selected?.items ?? []).prefix(3))
        if tokens.contains("time"), let p = model.selected {
            // How long the tree takes to arrange, and what happens to the screen when everything is chosen and the folders are closed and opened.
            func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            let clock = ContinuousClock()
            let build = clock.measure { _ = FolderTree.rows(for: p.items, order: p.order) }
            log("TREE items=\(p.items.count) build=\(build)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let t0 = ContinuousClock.now
                chosen.value = Set(p.items.map(\.id)); log("TREE select-all issued")
                DispatchQueue.main.async {
                    log("TREE select-all drawn after \(ContinuousClock.now - t0)")
                    let t1 = ContinuousClock.now
                    model.setFolders(FolderTree.folderPaths(for: p.items, order: p.order), collapsed: true, in: p.id)
                    DispatchQueue.main.async {
                        log("TREE close-all drawn after \(ContinuousClock.now - t1)")
                        let t2 = ContinuousClock.now
                        model.setFolders(FolderTree.folderPaths(for: p.items, order: p.order), collapsed: false, in: p.id)
                        DispatchQueue.main.async { log("TREE open-all drawn after \(ContinuousClock.now - t2)") }
                    }
                }
            }
        }
        if tokens.contains("select") { chosen.value = Set(first.map(\.id)) }
        if tokens.contains("rename") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { (NSApp.delegate as? AppDelegate)?.renameFiles(at: first.map(\.path)) } }
    }

    /// The playlist's commands, all on show (they used to be inside a menu).
    private func actionBar(_ p: Playlist) -> some View {
        LazyVGrid(columns: panelColumns(), spacing: 4) {
            PanelButton(title: L("New"), icon: "plus", help: L("New Playlist")) { model.create() }
            PanelButton(title: L("Rename"), icon: "pencil", help: L("Rename the playlist")) { nameDraft.value = p.name; renaming.value = true }
            PanelButton(title: L("Duplicate"), icon: "plus.square.on.square", help: L("Make a copy of the playlist")) { model.duplicate(p.id) }
            PanelButton(title: L("Refresh"), icon: "arrow.clockwise", help: L("Refresh Folders and Files")) {
                model.refreshAvailability(p.id); model.refreshFolders(p.id); model.pruneDeleted(p.id); model.probeMissing(p.id)
            }
            if !p.folderSources.isEmpty {
                PanelButton(title: L("Folders"), icon: "folder.badge.gearshape", help: L("Folders in this Playlist")) { foldersOpen.value = true }
                    .popover(isPresented: $foldersOpen.value, arrowEdge: .bottom) { foldersPopover(p) }
            }
            PanelButton(title: L("Delete"), icon: "trash", help: L("Delete Playlist (videos are kept)"), tint: .red) { confirmDelete(p) }
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    /// The button that shows how the list is sorted and opens the choices.
    private func sortButton(_ p: Playlist) -> some View {
        let label = Self.orderLabel(p.order)
        return Button { sortOpen.value = true } label: {
            HStack(spacing: 5) {
                Image(systemName: p.order.isAutomatic ? (p.order.descending ? "arrow.down" : "arrow.up") : "arrow.up.arrow.down").font(.caption.weight(.semibold))
                Text(label ?? L("Manual order")).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundColor(p.order.isAutomatic ? .white : .primary)
            .background(Capsule().fill(p.order.isAutomatic ? Color.accentColor : Color.secondary.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Sort By"))
        .accessibilityLabel(L("Sort By") + ": " + (label ?? L("Manual order")))
        .popover(isPresented: $sortOpen.value, arrowEdge: .bottom) { sortPopover(p) }
    }

    private func sortPopover(_ p: Playlist) -> some View {
        func choose(_ k: SortKey) {
            let desc = p.order.key == k.key ? p.order.descending : k.startsDescending
            model.applyOrder(p.id, PlaylistOrder(key: k.key, descending: desc))
        }
        func row(_ icon: String, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 18).foregroundColor(selected ? .accentColor : .secondary)
                    Text(title)
                    Spacer(minLength: 12)
                    if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundColor(.accentColor) }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
        let current = Self.sortKeys.first { $0.key == p.order.key }
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("Sort By")).font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(Self.sortKeys) { k in row(k.icon, k.label, selected: p.order.key == k.key) { choose(k) } }
            row("hand.draw", L("Manual order"), selected: !p.order.isAutomatic) { model.setOrder(p.id, .manual) }
            if let k = current {
                Divider().padding(.vertical, 4)
                Picker("", selection: Binding(get: { p.order.descending }, set: { model.applyOrder(p.id, PlaylistOrder(key: k.key, descending: $0)) })) {
                    Text(k.ascending).tag(false); Text(k.descending).tag(true)
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 8)
            }
        }.padding(10).frame(width: 270)
    }

    // MARK: Choosing the playlist

    /// The playlist that is open, as a card: its name and what is in it. A click opens the list of all of them.
    private var playlistPicker: some View {
        Button { pickerOpen.value = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 15)).foregroundColor(.accentColor)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selected?.name ?? L("No playlist")).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(model.selected.map { Self.summary($0) } ?? L("Create your first playlist")).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundColor(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.secondary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(L("Choose a playlist"))
        .accessibilityLabel(L("Choose a playlist") + ": " + (model.selected?.name ?? L("No playlist")))
        .popover(isPresented: $pickerOpen.value, arrowEdge: .bottom) { pickerPopover }
    }

    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Playlists")).font(.headline)
                Spacer()
                Text("\(model.playlists.count)").font(.caption).foregroundColor(.secondary)
            }.padding(.horizontal, 6)
            if model.playlists.isEmpty {
                Text(L("No playlists yet")).foregroundColor(.secondary).padding(.horizontal, 6).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.playlists) { p in
                            let selected = p.id == model.selectedID
                            Button { model.selectedID = p.id; chosen.value = []; pickerOpen.value = false } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected ? "rectangle.stack.fill" : "rectangle.stack").foregroundColor(selected ? .accentColor : .secondary).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                                        Text(Self.summary(p)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if model.playingPlaylistID == p.id { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundColor(.accentColor).accessibilityLabel(L("Playing")) }
                                    if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundColor(.accentColor) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.14) : (hoverPlaylist.value == p.id ? Color.secondary.opacity(0.14) : Color.clear)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoverPlaylist.value = $0 ? p.id : (hoverPlaylist.value == p.id ? nil : hoverPlaylist.value) }
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }.frame(maxHeight: 300)
            }
            Divider()
            Button { pickerOpen.value = false; model.create() } label: { Label(L("New Playlist"), systemImage: "plus") }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        }.padding(12).frame(width: 290)
    }

    private func foldersPopover(_ p: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(p.folderSources) { src in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "folder")
                        Text(URL(fileURLWithPath: src.path).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 8)
                        if src.follow { Text(L("followed")).font(.caption).foregroundColor(.secondary) }
                    }
                    Text(src.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                    HStack(spacing: 6) {
                        Button(src.follow ? L("Stop Following") : L("Follow This Folder")) { model.setFollow(src.id, to: !src.follow, in: p.id) }
                        Button(L("Remove Folder and Its Videos…")) { askAboutFolder(src, from: p, withVideos: true) }
                        Button(L("Stop Using Folder (keep its videos)…")) { askAboutFolder(src, from: p, withVideos: false) }
                    }.buttonStyle(.bordered).controlSize(.small).fixedSize(horizontal: false, vertical: true)
                }
                if src.id != p.folderSources.last?.id { Divider() }
            }
        }.padding(12).frame(width: 330)
    }

    /// The question is a dialog, so the popover goes first.
    private func askAboutFolder(_ src: PlaylistFolderSource, from p: Playlist, withVideos: Bool) {
        foldersOpen.value = false
        DispatchQueue.main.async { confirmRemoveFolder(src, from: p, withVideos: withVideos) }
    }

    private func header(_ p: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let unknown = p.unknownDurationCount
            Text(Self.summary(p) + (unknown > 0 ? " " + L("(some lengths still loading)") : "")
                 + (PlaylistSidebar.orderLabel(p.order).map { " · " + LF("Sorted: %@", $0) } ?? "")).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button { model.previous() } label: { Image(systemName: "backward.fill") }.accessibilityLabel(L("Previous video")).help(L("Previous video"))
                Button { model.playSelected(p.id) } label: { Image(systemName: "play.fill") }.accessibilityLabel(L("Play playlist")).help(L("Play playlist"))
                Button { model.advance(auto: false) } label: { Image(systemName: "forward.fill") }.accessibilityLabel(L("Next video")).help(L("Next video"))
                Spacer()
                Button { model.setMode(p.id, play: p.playMode == .shuffle ? .sequential : .shuffle) } label: {
                    Image(systemName: "shuffle").foregroundColor(p.playMode == .shuffle ? .accentColor : .secondary)
                }.help(p.playMode == .shuffle ? L("Shuffle: on") : L("Shuffle: off")).accessibilityLabel(p.playMode == .shuffle ? L("Shuffle on") : L("Shuffle off"))
                Button {
                    let next: RepeatMode = p.repeatMode == .off ? .all : (p.repeatMode == .all ? .one : .off)
                    model.setMode(p.id, rep: next)
                } label: {
                    Image(systemName: p.repeatMode == .one ? "repeat.1" : "repeat").foregroundColor(p.repeatMode == .off ? .secondary : .accentColor)
                }.help(p.repeatMode == .off ? L("Repeat: off") : p.repeatMode == .all ? L("Repeat: whole list") : L("Repeat: one video"))
                .accessibilityLabel(p.repeatMode == .off ? L("Repeat off") : p.repeatMode == .all ? L("Repeat all") : L("Repeat one"))
                Button { model.setMode(p.id, auto: !p.autoAdvance) } label: {
                    Image(systemName: "arrow.right.to.line").foregroundColor(p.autoAdvance ? .accentColor : .secondary)
                }.help(p.autoAdvance ? L("Play the next video automatically") : L("Stop after each video")).accessibilityLabel(p.autoAdvance ? L("Auto-play next on") : L("Auto-play next off"))
            }.buttonStyle(.borderless)
        }.padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func list(_ p: Playlist) -> some View {
        let shown = PlaylistEditor.search(p.items, query: model.query)
        return List(selection: $chosen.value) {
            ForEach(shown) { item in
                row(item, p)
            }
            .onMove(perform: model.query.isEmpty ? { model.move($0, to: $1, in: p.id) } : nil)
            .onInsert(of: [.fileURL]) { index, providers in load(providers) { model.add(urls: $0, to: p.id, at: index) } }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in load(providers) { model.add(urls: $0, to: p.id) }; return true }
        .onDeleteCommand { model.remove(chosen.value, from: p.id); chosen.value = [] }
        .overlay(Group { if p.items.isEmpty { Text(L("Drop videos, photos or a folder here.")).foregroundColor(.secondary) } })
    }

    private func row(_ item: PlaylistItem, _ p: Playlist, indent: CGFloat = 0) -> some View {
        rowContent(item, p, indent: indent)
            .onTapGesture(count: 2) { model.play(item.id, in: p.id) }
            .tag(item.id)
    }

    /// What a file row looks like and answers to, apart from what a click does (the list and the tree decide that for themselves).
    private func rowContent(_ item: PlaylistItem, _ p: Playlist, indent: CGFloat = 0) -> some View {
        HStack(spacing: 8) {
            RowThumb(path: item.path).frame(width: 48, height: 27).clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).font(.callout.weight(model.playingID == item.id ? .bold : .regular))
                HStack(spacing: 4) {
                    Text(Self.lengthText(item)).font(.caption).foregroundColor(.secondary)
                    if !item.availability.isPlayable {
                        Label(badge(item.availability), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange)
                    }
                }
            }
            Spacer()
            if model.playingID == item.id { Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor).accessibilityLabel(L("Playing")) }
        }
        .padding(.leading, indent)
        .opacity(item.availability.isPlayable ? 1 : 0.55)
        .contentShape(Rectangle())
        .contextMenu { itemMenu(item, p) }
        .onHover { info.hover(item, entered: $0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title + (item.availability.isPlayable ? "" : ", " + badge(item.availability)))
    }

    @ViewBuilder
    private func itemMenu(_ item: PlaylistItem, _ p: Playlist) -> some View {
        Button(L("Play")) { model.play(item.id, in: p.id) }
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
        Button(L("Remove from Playlist")) { model.remove(chosen.value.contains(item.id) ? chosen.value : [item.id], from: p.id) }
        Divider()
        // The menu works on everything that is chosen when the item is one of them, and on this item alone otherwise. SwiftUI builds the menu
        // every time the row is drawn, so nothing heavy is done here: the files are worked out only when a command is chosen.
        let many = chosen.value.contains(item.id) && chosen.value.count > 1
        Button(many ? LF("Rename %d Files…", chosen.value.count) : L("Rename File…")) { (NSApp.delegate as? AppDelegate)?.renameFiles(at: menuTargets(item, p, many: many).map(\.path)) }
        Button(many ? LF("Move %d Files to Trash…", chosen.value.count) : L("Move File to Trash…")) { trash(menuTargets(item, p, many: many), in: p) }
    }

    private func menuTargets(_ item: PlaylistItem, _ p: Playlist, many: Bool) -> [PlaylistItem] { many ? selectedItems(p) : [item] }

    /// The playlist entries for some ids, in the order of the ids.
    private func entries(_ ids: [UUID], in p: Playlist) -> [PlaylistItem] {
        let byID = Dictionary(p.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    private func trash(_ items: [PlaylistItem], in p: Playlist) {
        (NSApp.delegate as? AppDelegate)?.trashFiles(at: items.map(\.path))
        chosen.value.subtract(items.map(\.id))
    }

    // MARK: Choosing several files

    /// The files of the playlist that are chosen and on the list now (a search can hide some), in the order the list shows them.
    private func selectedItems(_ p: Playlist) -> [PlaylistItem] {
        let c = chosen.value
        guard !c.isEmpty else { return [] }
        return visibleOrder(p).filter { c.contains($0.id) }
    }

    /// Every file the list shows, top to bottom (the tree's order for the tree, also for files in closed folders).
    private func visibleOrder(_ p: Playlist) -> [PlaylistItem] {
        let shown = PlaylistEditor.search(p.items, query: model.query)
        guard layout.value == .tree else { return shown }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FolderTree.rows(for: shown, order: p.order, expandAll: true).compactMap { $0.itemID.flatMap { byID[$0] } }
    }

    /// What the chosen files can be given: new names, the Trash, or a place off the list. The number says how many are chosen.
    private func selectionBar(_ p: Playlist, count: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(LF("%d selected", count)).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button(L("Select All")) { chosen.value = Set(visibleOrder(p).map(\.id)) }
                Button(L("Clear Selection")) { chosen.value = []; anchor.value = nil }
            }.font(.caption).buttonStyle(.link)
            LazyVGrid(columns: panelColumns(), spacing: 4) {
                PanelButton(title: L("Rename"), icon: "pencil", help: count > 1 ? LF("Rename %d Files…", count) : L("Rename File…")) {
                    (NSApp.delegate as? AppDelegate)?.renameFiles(at: selectedItems(p).map(\.path))
                }
                PanelButton(title: L("Trash"), icon: "trash", help: count > 1 ? LF("Move %d Files to Trash…", count) : L("Move File to Trash…"), tint: .red) {
                    trash(selectedItems(p), in: p)
                }
                PanelButton(title: L("Remove"), icon: "minus.circle", help: L("Remove the chosen files from the playlist (the files stay where they are)")) {
                    model.remove(Set(selectedItems(p).map(\.id)), from: p.id); chosen.value = []
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12)))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    // MARK: Folder tree

    /// Opening and closing every folder at once.
    private func treeBar(_ p: Playlist) -> some View {
        func all() -> [String] { FolderTree.folderPaths(for: p.items, order: p.order) }      // only when a button is pressed
        return HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button { model.setFolders(all(), collapsed: false, in: p.id) } label: { Label(L("Open all"), systemImage: "chevron.down.2") }.help(L("Open all folders"))
            Button { model.setFolders(all(), collapsed: true, in: p.id) } label: { Label(L("Close all"), systemImage: "chevron.up.2") }.help(L("Close all folders"))
        }
        .font(.caption).buttonStyle(.link).padding(.horizontal, 8).padding(.bottom, 6)
    }

    /// The playlist as the folders its files are in. Playing still follows the playlist's order, so a one-line note offers to make the
    /// order the same as the tree.
    @ViewBuilder
    private func treeHint(_ p: Playlist) -> some View {
        if p.order.key != .folder, !hideTreeHint.value, let first = p.items.first, p.items.contains(where: { PathUtil.directory(of: $0.path) != PathUtil.directory(of: first.path) }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundColor(.secondary).accessibilityHidden(true)
                Text(L("Playing follows the playlist's order, not the tree.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L("Sort by Folder")) { model.applyOrder(p.id, PlaylistOrder(key: .folder)) }.buttonStyle(.link).font(.caption)
                Button { hideTreeHint.value = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.caption2)
                    .help(L("Hide this note")).accessibilityLabel(L("Hide this note"))
            }.padding(.horizontal, 8).padding(.bottom, 6)
        }
    }

    /// A scrolling column that draws only the rows on screen. (A SwiftUI `List` of thousands of mixed folder and file rows made the app
    /// stop responding while it compared the rows, so the tree is drawn like the grid is: choosing is done here, by click, ⌘-click and ⇧-click.)
    private func tree(_ p: Playlist) -> some View {
        let shown = PlaylistEditor.search(p.items, query: model.query)
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = FolderTree.rows(for: shown, order: p.order, collapsed: model.collapsedFolders[p.id] ?? [], expandAll: searching)
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let onScreen = rows.compactMap(\.itemID)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    if r.kind == .folder { folderRow(r, p, searching: searching) }
                    else if let item = r.itemID.flatMap({ byID[$0] }) { treeFileRow(item, p, depth: r.depth, order: onScreen) }
                }
            }.padding(.vertical, 4)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in load(providers) { model.add(urls: $0, to: p.id) }; return true }
        .onDeleteCommand { model.remove(chosen.value, from: p.id); chosen.value = [] }
        .overlay(Group { if p.items.isEmpty { Text(L("Drop videos, photos or a folder here.")).foregroundColor(.secondary) } })
    }

    /// A click on a file: alone, with ⌘ (add or take away) or with ⇧ (everything from the last one clicked). The keys are those of the click itself.
    private func choose(_ item: PlaylistItem, order: [UUID]) {
        let flags = ClickKeys.shared.held
        let click: ItemSelection.Click = flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .range : .plain)
        let r = ItemSelection.apply(click, on: item.id, order: order, selected: chosen.value, anchor: anchor.value)
        chosen.value = r.selected; anchor.value = r.anchor
        if SidebarProbe.enabled { SidebarProbe.chosen = r.selected }
    }

    private func treeFileRow(_ item: PlaylistItem, _ p: Playlist, depth: Int, order: [UUID]) -> some View {
        let selected = chosen.value.contains(item.id)
        return rowContent(item, p, indent: CGFloat(depth) * 14 + 18)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.28) : Color.clear))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            // One gesture for every click. A tap and a double tap on the same row compete, and the plain tap then never came through:
            // so each click chooses, and the second click of a double click plays the file.
            .onTapGesture {
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.play(item.id, in: p.id) } else { choose(item, order: order) }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("macplayer.sidebar")) }) { if SidebarProbe.enabled { SidebarProbe.rowFrames[item.id] = $0 } }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func folderRow(_ r: FolderTree.Row, _ p: Playlist, searching: Bool) -> some View {
        let ids = r.itemIDs
        let picked = ids.filter { chosen.value.contains($0) }.count
        let playing = model.playingID.map { ids.contains($0) } ?? false
        let state = picked == 0 ? L("none chosen") : (picked == ids.count ? L("all chosen") : L("some chosen"))
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                .rotationEffect(.degrees(r.isExpanded ? 90 : 0)).frame(width: 12).accessibilityHidden(true)
            Image(systemName: r.isExpanded ? "folder.fill" : "folder").foregroundColor(.accentColor).accessibilityHidden(true)
            Text(r.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text("\(ids.count)").font(.caption).foregroundColor(.secondary).accessibilityLabel(LF("%d files", ids.count))
            Spacer(minLength: 4)
            if playing && !r.isExpanded { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundColor(.accentColor).accessibilityLabel(L("Playing")) }
            // Chooses (or lets go of) every file in the folder, also those in folders inside it.
            Button {
                if picked == ids.count { chosen.value.subtract(ids) } else { chosen.value.formUnion(ids) }
            } label: {
                Image(systemName: picked == 0 ? "circle" : (picked == ids.count ? "checkmark.circle.fill" : "minus.circle.fill"))
                    .foregroundColor(picked == 0 ? .secondary : .accentColor)
            }
            .buttonStyle(.borderless).help(picked == ids.count ? L("Let go of the files in this folder") : L("Choose all the files in this folder"))
            .accessibilityLabel(LF("Files in “%@”", r.title) + ": " + state)
        }
        .padding(.leading, CGFloat(r.depth) * 14 + 10).padding(.trailing, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !searching { model.toggleFolder(r.path, in: p.id) } }
        .help(r.path)
        .contextMenu {
            Button(r.isExpanded ? L("Close Folder") : L("Open Folder")) { model.toggleFolder(r.path, in: p.id) }.disabled(searching)
            Button(L("Choose All Files in Folder")) { chosen.value.formUnion(ids) }
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            Divider()
            // The files of the folder, in the tree's order, found only when a command is chosen (this menu is built at every redraw).
            Button(LF("Rename %d Files…", ids.count)) { (NSApp.delegate as? AppDelegate)?.renameFiles(at: entries(ids, in: p).map(\.path)) }.disabled(ids.count < 1)
            Button(LF("Move %d Files to Trash…", ids.count)) { trash(entries(ids, in: p), in: p) }.disabled(ids.count < 1)
            Button(L("Remove from Playlist")) { model.remove(Set(ids), from: p.id); chosen.value.subtract(ids) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(r.title + ", " + LF("%d files", ids.count) + ", " + (r.isExpanded ? L("open") : L("closed")))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Grid

    /// The same videos as pictures, several to a row: far less scrolling when the list is long. The sidebar can be dragged wider for more columns.
    private func grid(_ p: Playlist) -> some View {
        let shown = PlaylistEditor.search(p.items, query: model.query)
        let order = shown.map(\.id)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 190), spacing: 8, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(shown) { item in cell(item, p, order: order) }
            }.padding(8)
        }
        .focusable()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in load(providers) { model.add(urls: $0, to: p.id) }; return true }
        .onDeleteCommand { model.remove(chosen.value, from: p.id); chosen.value = [] }
        .overlay(Group { if p.items.isEmpty { Text(L("Drop videos, photos or a folder here.")).foregroundColor(.secondary) } })
    }

    private func cell(_ item: PlaylistItem, _ p: Playlist, order: [UUID]) -> some View {
        let selected = chosen.value.contains(item.id), playing = model.playingID == item.id
        return VStack(alignment: .leading, spacing: 4) {
            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(RowThumb(path: item.path, large: true))
                .overlay(alignment: .bottomTrailing) {
                    Text(Self.lengthText(item)).font(.caption2.monospacedDigit()).foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.65)).cornerRadius(3).padding(3)
                }
                .overlay(alignment: .topLeading) {
                    if playing { Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundColor(.white).padding(4).background(Circle().fill(Color.accentColor)).padding(3).accessibilityHidden(true) }
                }
                .overlay(alignment: .topTrailing) {
                    if !item.availability.isPlayable { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange).padding(3).accessibilityHidden(true) }
                }
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: selected || playing ? 2 : 0))
            Text(item.title).font(.caption.weight(playing ? .bold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .opacity(item.availability.isPlayable ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(item.id, in: p.id) }
        .onTapGesture {
            choose(item, order: order)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("macplayer.sidebar")) }) { if SidebarProbe.enabled { SidebarProbe.rowFrames[item.id] = $0 } }
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .onDrop(of: [.text, .fileURL], isTargeted: nil) { providers in dropOnCell(providers, item, p) }
        .contextMenu { itemMenu(item, p) }
        .onHover { info.hover(item, entered: $0) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title + (item.availability.isPlayable ? "" : ", " + badge(item.availability)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Dropping a picture on another one moves it there; dropping files from Finder adds them there.
    private func dropOnCell(_ providers: [NSItemProvider], _ item: PlaylistItem, _ p: Playlist) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) {
            let at = p.items.firstIndex { $0.id == item.id }
            load(providers) { model.add(urls: $0, to: p.id, at: at) }
            return true
        }
        guard model.query.isEmpty, let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            DispatchQueue.main.async {
                guard let text = text as? String, let id = UUID(uuidString: text),
                      let from = p.items.firstIndex(where: { $0.id == id }), let to = p.items.firstIndex(where: { $0.id == item.id }), from != to else { return }
                model.move(IndexSet(integer: from), to: to, in: p.id)
            }
        }
        return true
    }

    private func badge(_ a: Availability) -> String {
        switch a { case .missing: return L("Missing"); case .unreadable: return L("Cannot be read"); case .unsupported: return L("Not supported"); case .available: return "" }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { addFiles() } label: { Label(L("Add Files…"), systemImage: "film.stack") }
                Button { addFolder() } label: { Label(L("Add Folder…"), systemImage: "folder.badge.plus") }
            }.font(.caption).controlSize(.small)
            if let s = model.status { Text(s).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(8)
    }

    private func addFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .image]
        if p.runModal() == .OK { model.add(urls: p.urls) }
    }

    private func addFolder() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = L("Choose a folder of videos. You will see what was found before anything is added.")
        if p.runModal() == .OK, let u = p.url { model.beginAddFolder(u) }
    }

    private func confirmRemoveFolder(_ src: PlaylistFolderSource, from p: Playlist, withVideos: Bool) {
        let count = PlaylistEditor.itemIDs(ofSource: src.id, in: p).count
        let name = URL(fileURLWithPath: src.path).lastPathComponent
        let a = NSAlert()
        a.messageText = withVideos ? LF("Remove the folder “%@” and its %d videos from “%@”?", name, count, p.name) : LF("Stop using the folder “%@” in “%@”?", name, p.name)
        a.informativeText = withVideos ? L("Only this list changes. The video files stay where they are, and other playlists are not touched.")
                                       : L("Its videos stay in the list as ordinary entries, and new videos in the folder are no longer added.")
        a.addButton(withTitle: withVideos ? L("Remove") : L("Stop Using")); a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn { model.removeFolder(src.id, from: p.id, removeVideos: withVideos) }
    }

    private func confirmDelete(_ p: Playlist) {
        let a = NSAlert(); a.messageText = LF("Delete the playlist “%@”?", p.name)
        a.informativeText = L("Only the list is deleted. The video files are not touched.")
        a.addButton(withTitle: L("Delete Playlist")); a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn { model.delete(p.id) }
    }

    private func load(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { urls.append(u) } }; group.leave() }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

final class ThumbHolder: ObservableObject { @Published var image: NSImage? }

struct RowThumb: View {
    let path: String
    var large = false
    @StateObject private var h = ThumbHolder()
    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.2))
            if let i = h.image { Image(nsImage: i).resizable().aspectRatio(contentMode: .fill) } else { Image(systemName: "film").foregroundColor(.secondary) }
        }.clipped().cornerRadius(3).task { h.image = await RowThumbs.shared.image(for: path, large: large) }.accessibilityHidden(true)
    }
}

struct FolderSheet: View {
    @ObservedObject var model: PlaylistModel
    var body: some View {
        let prev = model.folderPreview
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Add a folder")).font(.title3.bold())
            if let target = prev?.targetID.flatMap({ id in model.playlists.first { $0.id == id } }) {
                Label(LF("It will be added to the playlist “%@”.", target.name), systemImage: "list.and.film").font(.callout)
            }
            Text(prev?.url.path ?? "").font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
            Toggle(L("Include subfolders"), isOn: Binding(get: { prev?.includeSubfolders ?? false }, set: { v in model.folderPreview?.includeSubfolders = v; model.rescanPreview() }))
            Toggle(L("Follow this folder (add new videos automatically)"), isOn: Binding(get: { prev?.follow ?? false }, set: { model.folderPreview?.follow = $0 }))
            Picker(L("Order"), selection: Binding(get: { prev?.sort ?? .naturalName }, set: { model.folderPreview?.sort = $0; model.rescanPreview() })) {
                Text(L("Name (1, 2, 10)")).tag(PlaylistSort.naturalName); Text(L("Date modified")).tag(PlaylistSort.modified); Text(L("Length (sorted once known)")).tag(PlaylistSort.duration)
            }
            if prev?.scanning == true { HStack { ProgressView().controlSize(.small); Text(L("Looking for videos…")) } }
            else {
                Text(LF("%d videos and photos found", prev?.videos.count ?? 0) + ((prev?.skippedOther ?? 0) > 0 ? " · " + LF("%d other files ignored", prev?.skippedOther ?? 0) : "")).font(.callout)
                if let bad = prev?.unreadable, !bad.isEmpty { Label(LF("%d folders could not be read.", bad.count), systemImage: "exclamationmark.triangle").foregroundColor(.orange).font(.caption) }
            }
            List { ForEach(prev?.videos ?? [], id: \.path) { Text($0.name).lineLimit(1) } }.frame(height: 180)
            HStack {
                Spacer()
                Button(L("Cancel")) { model.cancelFolderPreview() }
                Button(L("Add")) { model.confirmFolderPreview() }.keyboardShortcut(.defaultAction).disabled(prev?.scanning != false || (prev?.videos.isEmpty ?? true))
            }
        }.padding(16).frame(width: 440)
    }
}

/// What the self-test needs to see of the sidebar: where each file row of the tree is, and which files a click chose. Only filled while
/// a test has switched it on.
@MainActor
enum SidebarProbe {
    static var enabled = false
    static var rowFrames: [UUID: CGRect] = [:]
    static var chosen: Set<UUID> = []
}

/// Which of ⌘ and ⇧ were held when the mouse was last pressed. A tap is reported a moment after the click, when the keys may be gone
/// and the event being handled may be another one, so the press itself is noted as it goes by.
@MainActor
final class ClickKeys {
    static let shared = ClickKeys()
    private var last: NSEvent.ModifierFlags?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.last = event.modifierFlags }
            return event
        }
    }

    /// The keys held at the last press (the keys held now, if there has been none).
    var held: NSEvent.ModifierFlags { last ?? NSEvent.modifierFlags }
}
