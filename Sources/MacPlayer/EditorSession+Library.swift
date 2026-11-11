import AppKit
import UniformTypeIdentifiers
import MacPlayerCore
import MacPlayerMedia

/// What is selected in a video project: one thing at a time, as in most editors. The Properties panel shows its settings.
enum EditSelection: Equatable {
    case none, clip(UUID), layer(UUID), text(UUID), sound(UUID)
}

/// The library (Media panel) and the drag-and-drop actions of the editor: files brought into the project, then put on the timeline where
/// they are dropped; filters, transitions and text styles dropped on a clip or at a time.
extension EditorSession {
    // MARK: Selection

    var selection: EditSelection {
        if let id = selectedClipIDs.first, project.timeline.contains(where: { $0.id == id }) { return .clip(id) }
        if let id = selectedOverlayID, project.overlayClips.contains(where: { $0.id == id }) { return .layer(id) }
        if let id = selectedTextID, project.overlays.contains(where: { $0.id == id }) { return .text(id) }
        if let id = selectedSoundID, project.soundClips.contains(where: { $0.id == id }) { return .sound(id) }
        return .none
    }

    /// Selects one thing (and nothing else), and opens the settings that fit it.
    func select(_ s: EditSelection) {
        switch s {
        case .text(let id), .layer(let id): canvasSelection = CanvasSelection.expandingGroups([id], in: project)
        default: canvasSelection = []
        }
        switch s {
        case .none: selectedClipIDs = []; selectedOverlayID = nil; selectedTextID = nil; selectedSoundID = nil
        case .clip(let id): selectedOverlayID = nil; selectedTextID = nil; selectedSoundID = nil; selectedClipIDs = [id]
        case .layer(let id): selectedClipIDs = []; selectedTextID = nil; selectedSoundID = nil; selectedOverlayID = id
        case .text(let id): selectedClipIDs = []; selectedOverlayID = nil; selectedSoundID = nil; selectedTextID = id
        case .sound(let id): selectedClipIDs = []; selectedOverlayID = nil; selectedTextID = nil; selectedSoundID = id
        }
        let tabs = InspectorTab.propertyTabs(for: s)
        if !tabs.contains(activeTool) { activeTool = tabs.first ?? .clips }
    }

    /// Deletes what is selected (the Delete key, the toolbar's bin). Several things on the picture go in one step; locked ones stay.
    func deleteSelection() {
        if canvasSelection.count > 1 || (canvasSelection.count == 1 && { if case .clip = selection { return false }; return true }()) {
            let ids = canvasSelection
            var kept = 0
            edit(ids.count > 1 ? "Delete" : "Delete from the picture") { kept = CanvasSelection.delete(ids, in: &$0) }
            if kept > 0 { flash(kept == 1 ? L("A locked item was kept. Unlock it to delete it.") : LF("%d locked items were kept. Unlock them to delete them.", kept)) }
            let left = CanvasSelection.items(of: project).map(\.id).filter(ids.contains)
            canvasSelection = Set(left)
            if !left.contains(where: { $0 == selectedTextID }) { selectedTextID = nil }
            if !left.contains(where: { $0 == selectedOverlayID }) { selectedOverlayID = nil }
            return
        }
        switch selection {
        case .clip: deleteTimelineClips(selectedClipIDs)
        case .layer(let id): deleteOverlay(id)
        case .text(let id): edit("Delete from the picture") { p in p.overlays.removeAll { $0.id == id } }; selectedTextID = nil
        case .sound(let id): deleteSound(id)
        case .none: break
        }
    }

    /// Duplicates what is selected. Several things on the picture are copied together, a little down and to the right, and the copies selected.
    func duplicateSelection() {
        if canvasSelection.count > 1 {
            let ids = canvasSelection
            var made: Set<UUID> = []
            edit("Duplicate") { p in
                var newGroups: [UUID: UUID] = [:]
                for o in p.overlays where ids.contains(o.id) {
                    var c = o; c.id = UUID(); c.x = min(1, o.x + 0.03); c.y = min(1, o.y + 0.03); c.locked = nil
                    c.groupID = o.groupID.map { g in newGroups[g] ?? { let n = UUID(); newGroups[g] = n; return n }() }
                    p.overlays.append(c); made.insert(c.id)
                }
                for l in p.overlayClips where ids.contains(l.id) {
                    var c = l; c.id = UUID(); c.transform.centerX = min(1, l.transform.centerX + 0.03); c.transform.centerY = min(1, l.transform.centerY + 0.03); c.locked = nil
                    c.groupID = l.groupID.map { g in newGroups[g] ?? { let n = UUID(); newGroups[g] = n; return n }() }
                    if let lane = OverlayEditor.firstFreeLane(p.overlayClips, start: c.start, duration: c.duration) { c.lane = lane; p.overlayClips.append(c); made.insert(c.id) }
                }
            }
            if !made.isEmpty { selectCanvas(made) }
            return
        }
        switch selection {
        case .clip: duplicateTimelineClips(selectedClipIDs)
        case .layer(let id): duplicateOverlay(id)
        case .text(let id):
            guard var o = project.overlays.first(where: { $0.id == id }) else { return }
            let len = o.end - o.start
            o.id = UUID(); o.start = o.end; o.end = min(max(duration, o.start + len), o.start + len)
            edit("Duplicate") { $0.overlays.append(o) }
            selectedTextID = o.id
        case .sound(let id): duplicateSound(id)
        case .none: break
        }
    }

    // MARK: Library

    /// Brings files into the project's library (nothing is copied or changed). Returns how many were new.
    @discardableResult
    func importToLibrary(_ urls: [URL]) -> Int {
        guard isProject || isPhoto, canEdit else { return 0 }
        var expanded: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                expanded += items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else { expanded.append(u) }
        }
        // A photo project's library holds pictures (its photo and logos).
        let usable = expanded.filter { isPhoto ? MediaBin.kind(of: $0.path) == .photo : MediaBin.kind(of: $0.path) != nil }
        let skipped = expanded.count - usable.count
        var added = 0
        let known = project.libraryItems
        let fresh = usable.filter { u in !known.contains { PathUtil.same($0.path, u.path) } }
        if !fresh.isEmpty {
            edit("Import media", refreshPreview: false) { p in
                added = MediaBin.add(fresh.map(\.path), to: &p.mediaBin, bookmark: { Bookmarks.make(URL(fileURLWithPath: $0)) }).count
            }
        }
        if skipped > 0 { flash(isPhoto ? LF("%d files are not pictures and were left out.", skipped) : LF("%d files are not videos, photos or sounds and were left out.", skipped), error: true) }
        else if added > 0 { flash(added == 1 ? L("Added to the library. Drag it onto the timeline.") : LF("%d files added to the library. Drag them onto the timeline.", added)) }
        return added
    }

    /// Asks for files to bring into the library.
    func chooseLibraryFiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .image, .audio]
        p.allowsMultipleSelection = true; p.canChooseDirectories = true
        p.message = L("Choose videos, photos or sounds for this project. They are not copied or changed.")
        if let folder = env.prefs.lastMediaFolder { p.directoryURL = URL(fileURLWithPath: folder) }
        guard p.runModal() == .OK else { return }
        if let first = p.urls.first { env.prefs.lastMediaFolder = first.deletingLastPathComponent().path }
        importToLibrary(p.urls)
    }

    /// Takes a file out of the library (only the library: the file and the timeline are not touched).
    func removeFromLibrary(_ item: BinItem) {
        edit("Remove from library", refreshPreview: false) { p in p.mediaBin.removeAll { PathUtil.same($0.path, item.path) } }
    }

    /// Puts library files into the project: videos on the timeline (at `index`, or after the selection, else at the end), photos as
    /// layers at `time`, sounds as music at `time` (the playhead when nil).
    func place(_ urls: [URL], videoIndex: Int? = nil, at time: MediaTime? = nil, lane: Int? = nil) async {
        if isPhoto, canEdit {
            // A photo project: the first picture becomes its photo when it has none yet; the others go over it as logos.
            var pictures = urls.filter { MediaBin.kind(of: $0.path) == .photo }
            importToLibrary(pictures.filter { u in !project.libraryItems.contains { PathUtil.same($0.path, u.path) } })
            if project.sources.isEmpty, let first = pictures.first { await choosePhoto(first); pictures.removeFirst() }
            for u in pictures { addLogo(u) }
            return
        }
        guard isProject, canEdit else { return }
        importToLibrary(urls.filter { u in !project.libraryItems.contains { PathUtil.same($0.path, u.path) } })
        let videos = urls.filter { MediaBin.kind(of: $0.path) == .video }
        let photos = urls.filter { MediaBin.kind(of: $0.path) == .photo }
        let sounds = urls.filter { MediaBin.kind(of: $0.path) == .audio }
        if !videos.isEmpty {
            if let lane, !project.timeline.isEmpty { await addOverlayVideos(videos, at: time, lane: lane) }
            else { await addVideos(videos, at: videoIndex) }
        }
        if !photos.isEmpty {
            // Dropped on a layer line: over the video, as a layer. Anywhere else: on the main track, as a clip of its own.
            if let lane, !project.timeline.isEmpty {
                var t = time
                for u in photos { await addOverlayPicture(u, at: t, lane: lane); t = t.map { $0 + MediaTime(seconds: 5) } }
            } else {
                await addPhotosToTimeline(photos, at: videos.isEmpty ? videoIndex : nil)
            }
        }
        if !sounds.isEmpty { await addSounds(urls: sounds, kind: .music, at: time) }
    }

    // MARK: Looks dropped on a clip

    /// A filter dropped on a clip (or chosen for the selected one).
    func applyFilter(_ preset: FilterPreset, toClip id: UUID) {
        guard isProject, canEdit else { return }
        if selectedClipIDs != [id] { select(.clip(id)) }
        editEffects(LF("Filter %@", EffectsPane.name(preset))) { e in e.filter = preset; if preset != .none && e.filterAmount == 0 { e.filterAmount = 1 } }
        flash(LF("Filter “%@” on clip %d.", EffectsPane.name(preset), (project.timeline.firstIndex { $0.id == id } ?? 0) + 1))
    }

    /// A filter for the photo of a photo project.
    func applyPhotoFilter(_ preset: FilterPreset) {
        guard isPhoto, canEdit else { return }
        editEffects(LF("Filter %@", EffectsPane.name(preset))) { e in e.filter = preset; if preset != .none && e.filterAmount == 0 { e.filterAmount = 1 } }
    }

    /// Something from the library dropped on the picture (a photo project: there is no timeline).
    func applyDropped(_ item: DragPayload, position: CGPoint? = nil) {
        switch item {
        case .filter(let f):
            if isPhoto { applyPhotoFilter(f) }
            else if let id = selectedClipIDs.first ?? TimelineMap.locate(project.timeline, at: player.currentTime)?.clipID { applyFilter(f, toClip: id) }
        case .text(let t): addText(t, position: position)
        case .sticker(let e): addSticker(e, position: position)
        case .shape(let k): addShape(k, position: position)
        case .preset(let p): addPreset(p, position: position)
        case .transition: flash(L("Drop a transition on the cut between two clips, on the timeline."), error: true)
        }
    }

    /// A transition dropped on a cut: it goes into the clip after the cut.
    func applyTransition(_ kind: TransitionKind, intoClip id: UUID) {
        guard isProject, canEdit, let i = project.timeline.firstIndex(where: { $0.id == id }) else { return }
        guard i > 0 else { flash(L("The first clip has nothing before it. Drop the transition on a cut between two clips."), error: true); return }
        if selectedClipIDs != [id] { select(.clip(id)) }
        chooseTransition(kind, label: LF("Transition %@", TransitionsPane.name(kind)))
        flash(LF("Transition “%@” between clips %d and %d.", TransitionsPane.name(kind), i, i + 1))
    }

    // MARK: Text

    /// A text in one of the ready-made styles, at `time` (the playhead) for 3 seconds; selected so it can be typed into.
    func addText(_ template: TextTemplate?, at time: MediaTime? = nil, position: CGPoint? = nil) {
        guard canEdit else { return }
        let start = isPhoto ? .zero : min(time ?? player.currentTime, max(.zero, duration - MediaTime(seconds: 0.5)))
        let end = isPhoto ? MediaTime(seconds: 100_000) : min(max(duration, start + MediaTime(seconds: 0.5)), start + MediaTime(seconds: 3))
        var o = TextOverlay(text: template.map { TextPane.templateName($0) } ?? L("Text"), start: start, end: end, sizeFraction: 0.07, y: 0.5)
        template?.apply(to: &o)
        if let position { o.x = Double(position.x); o.y = Double(position.y) }
        edit("Add text") { $0.overlays.append(o) }
        select(.text(o.id)); activeTool = .text
    }

    /// A sticker (a large emoji) at `time`, popping in.
    func addSticker(_ e: String, at time: MediaTime? = nil, position: CGPoint? = nil) {
        guard canEdit else { return }
        let start = isPhoto ? .zero : min(time ?? player.currentTime, max(.zero, duration - MediaTime(seconds: 0.5)))
        let end = isPhoto ? MediaTime(seconds: 100_000) : min(max(duration, start + MediaTime(seconds: 0.5)), start + MediaTime(seconds: 3))
        var o = TextOverlay(text: e, start: start, end: end, sizeFraction: 0.22, y: 0.5)
        var f = TextFlair(); f.outlineWidth = 0; o.flair = f; o.animationIn = ElementAnimation(kind: .pop, duration: 0.4)
        if let position { o.x = Double(position.x); o.y = Double(position.y) }
        edit("Add sticker") { $0.overlays.append(o) }
        select(.text(o.id)); activeTool = .text
    }

    /// A ready-made text (a subscribe button, a sale badge…) at `time` and `position` (its own place when nil).
    func addPreset(_ preset: TextPreset, at time: MediaTime? = nil, position: CGPoint? = nil) {
        guard canEdit else { return }
        let start = isPhoto ? .zero : min(time ?? player.currentTime, max(.zero, duration - MediaTime(seconds: 0.5)))
        let end = isPhoto ? MediaTime(seconds: 100_000) : min(max(duration, start + MediaTime(seconds: 0.5)), start + MediaTime(seconds: 3))
        var o = preset.make()
        o.id = UUID(); o.start = start; o.end = end
        if let position { o.x = Double(position.x); o.y = Double(position.y) }
        edit("Add text") { $0.overlays.append(o) }
        select(.text(o.id)); activeTool = .text
    }

    /// A shape (rectangle, circle, star, arrow…) at `time` and `position` (the middle of the picture when nil).
    func addShape(_ k: ShapeKind, at time: MediaTime? = nil, position: CGPoint? = nil) {
        guard canEdit else { return }
        let start = isPhoto ? .zero : min(time ?? player.currentTime, max(.zero, duration - MediaTime(seconds: 0.5)))
        let end = isPhoto ? MediaTime(seconds: 100_000) : min(max(duration, start + MediaTime(seconds: 0.5)), start + MediaTime(seconds: 3))
        // Its height follows the picture's shape, so a square is square on a wide or a tall picture (it was 18% × 18%: a wide rectangle on 16:9).
        let spec = ShapeSpec.made(k, width: k == .arrow ? 0.25 : 0.18, aspect: outputAspect)
        var o = TextOverlay.shape(spec, start: start, end: end)
        if let position { o.x = Double(position.x); o.y = Double(position.y) }
        edit("Add shape") { $0.overlays.append(o) }
        select(.text(o.id)); activeTool = .text
    }

    /// Moves a text in time, keeping its length.
    func moveText(_ id: UUID, toStart t: MediaTime) {
        edit("Move text", coalesce: "tmove-\(id)") { p in
            guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
            let len = p.overlays[i].end - p.overlays[i].start
            let start = max(.zero, t)
            p.overlays[i].start = start; p.overlays[i].end = start + len
        }
    }

    /// Drags an edge of a text in time.
    func trimText(_ id: UUID, leftEdge: Bool, to t: MediaTime) {
        edit("Trim text", coalesce: "ttrim-\(id)") { p in
            guard let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
            let minLen = MediaTime(seconds: 0.2)
            if leftEdge { p.overlays[i].start = min(max(.zero, t), p.overlays[i].end - minLen) }
            else { p.overlays[i].end = max(t, p.overlays[i].start + minLen) }
        }
    }

    /// Drags an edge of a sound: the left edge starts it later or earlier in the file, the right edge ends it sooner or later (never past the
    /// file's end, nor shorter than a fifth of a second).
    func trimSound(_ id: UUID, leftEdge: Bool, to t: MediaTime) {
        updateSound(id, "Trim sound", coalesce: "strim-\(id)") { c in
            let minLen = MediaTime(seconds: 0.2)
            let fileEnd = c.fileDuration ?? (c.sourceStart + c.duration)
            if leftEdge {
                let end = c.end
                var start = min(max(.zero, t), end - minLen)
                var src = c.sourceStart + (start - c.start)
                if src < .zero { start = start - src; src = .zero }
                c.start = start; c.sourceStart = src; c.duration = end - start
            } else {
                c.duration = min(max(minLen, t - c.start), fileEnd - c.sourceStart)
            }
        }
    }

    /// Moves a sound in time, keeping its length.
    func moveSound(_ id: UUID, toStart t: MediaTime) {
        updateSound(id, "Move sound", coalesce: "smove-\(id)") { $0.start = max(.zero, t) }
    }
}

extension InspectorTab {
    /// The settings shown in the Properties panel for what is selected.
    static func propertyTabs(for s: EditSelection) -> [InspectorTab] {
        switch s {
        case .clip: return [.picture, .color, .effects, .timing, .audio, .transitions, .mask]
        case .layer: return [.layers]
        case .text: return [.text]
        case .sound: return [.audio]
        case .none: return [.clips, .subtitles]          // exporting is the Export button at the top right
        }
    }
}

// MARK: Several things on the picture (0.12)

extension EditorSession {
    /// Selects these things on the picture (and the rest of their groups). The first text or layer among them gets the settings on the right.
    func selectCanvas(_ ids: Set<UUID>) {
        let all = CanvasSelection.expandingGroups(ids, in: project)
        guard !all.isEmpty else { select(.none); return }
        let primary = project.overlays.first { all.contains($0.id) }.map { EditSelection.text($0.id) } ?? project.overlayClips.first { all.contains($0.id) }.map { EditSelection.layer($0.id) } ?? .none
        let keepPrimary: EditSelection? = {
            switch selection { case .text(let id), .layer(let id): return all.contains(id) ? selection : nil; default: return nil }
        }()
        select(keepPrimary ?? primary)
        canvasSelection = all
    }

    /// ⇧/⌘-click: adds a thing (with its group) to what is selected on the picture, or takes it out.
    func toggleCanvas(_ id: UUID) {
        let group = CanvasSelection.expandingGroups([id], in: project)
        var next = canvasSelection
        if next.isSuperset(of: group) { next.subtract(group) } else { next.formUnion(group) }
        if next.isEmpty { select(.none) } else { selectCanvas(next) }
    }

    /// Whether this thing on the picture is locked.
    func isLocked(_ id: UUID) -> Bool {
        (project.overlays.first { $0.id == id }?.locked ?? project.overlayClips.first { $0.id == id }?.locked) ?? false
    }

    /// Moves what is selected on the picture by `dx`, `dy` (fractions of the picture). Arrow keys: repeated presses within a second are one undo step.
    func nudgeCanvas(dx: Double, dy: Double) {
        let ids = CanvasSelection.movable(canvasSelection, in: project)
        guard !ids.isEmpty, canEdit else {
            if !canvasSelection.isEmpty { flash(L("Locked: unlock it to move it.")) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastNudge > 1 { endCoalescing() }
        lastNudge = now
        edit("Move", coalesce: "canvas-nudge", refreshPreview: isPhoto) { CanvasSelection.nudge(ids, dx: dx, dy: dy, in: &$0) }
        pushLiveCanvas(ids)
    }

    /// Moves the things from where they were when a drag began (`origin`), all by the same amount: one undo step per drag.
    func moveCanvas(_ ids: Set<UUID>, from origin: Project, dx: Double, dy: Double) {
        let ok = CanvasSelection.movable(ids, in: origin)
        guard !ok.isEmpty, canEdit else { return }
        edit("Move", coalesce: "canvas-drag", refreshPreview: isPhoto) { p in
            p.overlays = p.overlays.map { o in origin.overlays.first { $0.id == o.id && ok.contains(o.id) } ?? o }
            p.overlayClips = p.overlayClips.map { c in origin.overlayClips.first { $0.id == c.id && ok.contains(c.id) } ?? c }
            CanvasSelection.nudge(ok, dx: dx, dy: dy, in: &p)
        }
        pushLiveCanvas(ok)
    }

    /// The preview shows the new places at once (no rebuild): texts through `ElementLive`, layers through `LayerLive`.
    func pushLiveCanvas(_ ids: Set<UUID>) {
        guard !isPhoto else { return }
        for o in project.overlays where ids.contains(o.id) { ElementLive.set(.init(x: o.x, y: o.y, scale: o.scale ?? 1), for: o.id) }
        for c in project.overlayClips where ids.contains(c.id) {
            if let spec = project.layerSpecs(resolve: { sourceURLs[$0]?.path }).first(where: { $0.id == c.id }) { LayerLive.set(spec) }
        }
        player.refreshFrame()
    }

    func groupCanvas() {
        guard canvasSelection.count > 1 else { flash(L("Select two or more things on the picture to group them (⇧-click or drag a frame around them).")); return }
        let ids = canvasSelection
        edit("Group") { CanvasSelection.group(ids, in: &$0) }
        flash(LF("%d things grouped: they move and are selected together.", ids.count))
    }

    func ungroupCanvas() {
        let ids = canvasSelection
        guard CanvasSelection.items(of: project).contains(where: { ids.contains($0.id) && $0.group != nil }) else { return }
        edit("Ungroup") { CanvasSelection.ungroup(ids, in: &$0) }
    }

    /// Locks what is selected, or unlocks it when it is all locked already.
    func toggleLockCanvas() {
        let ids = canvasSelection
        guard !ids.isEmpty else { return }
        let lock = !ids.allSatisfy(isLocked)
        edit(lock ? "Lock" : "Unlock") { CanvasSelection.setLocked(lock, ids, in: &$0) }
    }

    var canvasHasGroup: Bool { CanvasSelection.items(of: project).contains { canvasSelection.contains($0.id) && $0.group != nil } }
    var canvasAllLocked: Bool { !canvasSelection.isEmpty && canvasSelection.allSatisfy(isLocked) }
}

