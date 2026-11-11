import AVFoundation
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// A video project: one timeline of clips taken from several videos.
extension EditorSession {

    // MARK: Sources

    /// Finds every source of the project (moved files via bookmarks), reads what is known about it, and reports the missing.
    func resolveSources() async {
        var urls: [UUID: URL] = [:], infs: [UUID: MediaInfo] = [:]
        for src in project.sources {
            var url = URL(fileURLWithPath: src.path)
            if let photo = src.stillOf {
                // A photo clip: its little video is made again from the photo when it is gone (another Mac, a cleaned folder, a moved photo).
                var p = URL(fileURLWithPath: photo)
                if !env.fs.exists(p.path), let moved = Bookmarks.resolve(src.bookmark), env.fs.exists(moved.path) { p = moved }
                if !env.fs.exists(url.path), env.fs.exists(p.path), let made = try? await StillClip.make(from: p) { url = made }
            } else if !env.fs.exists(url.path), let moved = Bookmarks.resolve(src.bookmark), env.fs.exists(moved.path) { url = moved }
            if env.fs.exists(url.path), let info = try? await MediaProbe.probe(url: url) { urls[src.id] = url; infs[src.id] = info }
        }
        sourceURLs = urls; infos = infs
        if let first = project.sources.first { sourceURL = urls[first.id]; info = infs[first.id] }
        reportMissing()
        loadWaveforms()
    }

    func reportMissing() {
        let missing = project.sources.filter { sourceURLs[$0.id] == nil }
        if !missing.isEmpty {
            flash(LF("The video “%@” was not found. Use File ▸ Relink Video… to point to it.", missing.map { PathUtil.fileName(of: $0.mediaPath) }.joined(separator: ", ")), error: true)
        }
    }

    func loadWaveforms() {
        for (id, url) in sourceURLs where peaksBySource[id] == nil && infos[id]?.hasAudio == true {
            Task { if let p = try? await Waveform.peaks(url: url) { peaksBySource[id] = p } }
        }
    }

    /// Points a missing source at the file the user chose. The clips keep their times.
    func relinkSource(_ id: UUID, to url: URL) async {
        // A photo clip whose photo moved: its little video is made from the photo chosen now.
        if project.source(id)?.stillOf != nil {
            guard ImageFiles.isCandidate(url.path) else { flash(L("Choose a photo."), error: true); return }
            do {
                let video = try await StillClip.make(from: url)
                let new = try await MediaProbe.probe(url: video)
                edit("Relink photo", refreshPreview: false) { p in
                    guard let i = p.sources.firstIndex(where: { $0.id == id }) else { return }
                    p.sources[i].path = video.path; p.sources[i].stillOf = url.path; p.sources[i].bookmark = Bookmarks.make(url); p.sources[i].info = new
                }
                sourceURLs[id] = video; infos[id] = new
                await loadPlayer(at: player.effectiveTime)
                flash(L("Photo relinked."))
            } catch { flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
            return
        }
        do {
            let new = try await MediaProbe.probe(url: url)
            guard new.hasVideo else { flash(L("This file has no picture."), error: true); return }
            edit("Relink video", refreshPreview: false) { p in
                guard let i = p.sources.firstIndex(where: { $0.id == id }) else { return }
                p.sources[i].path = url.path; p.sources[i].bookmark = Bookmarks.make(url)
                p.sources[i].fingerprint = try? env.fs.fingerprint(url.path); p.sources[i].info = new
            }
            sourceURLs[id] = url; infos[id] = new; peaksBySource[id] = nil
            if project.sources.first?.id == id { sourceURL = url; info = new }
            loadWaveforms()
            await loadPlayer(at: player.effectiveTime)
            flash(L("Video relinked. Check that the timing of your clips is still right."))
        } catch { flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
    }

    /// Adds whole videos at `index` on the timeline (where they were dropped); without one, after the selected clip, else at the end.
    func addVideos(_ urls: [URL], at index: Int? = nil) async {
        guard isProject, canEdit else { return }
        let decision = ProjectRules.canAdd(paths: urls.map(\.path), to: project)
        guard decision == .ok else { flash(Self.ruleText(decision), error: true); return }
        var lastAdded: UUID?
        // Where the first new clip goes: after the selected clip, else at the end. Each further video goes right after the one before it,
        // so several videos added at once keep the order they were given in.
        var insertAt: Int? = index ?? project.timeline.lastIndex { selectedClipIDs.contains($0.id) }.map { $0 + 1 }
        for url in urls {
            do {
                let info = try await MediaProbe.probe(url: url)
                guard info.hasVideo, info.isExportable else { flash(LF("“%@” has no picture or cannot be used here.", url.lastPathComponent), error: true); continue }
                let ref = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? env.fs.fingerprint(url.path), info: info)
                var newID: UUID?
                edit("Add video", refreshPreview: false) { p in
                    MediaBin.add([url.path], to: &p.mediaBin, bookmark: { _ in ref.bookmark })
                    let sid = p.addSource(ref)
                    let c = TimelineClip(sourceID: sid, sourceStart: .zero, sourceEnd: info.duration, name: url.deletingPathExtension().lastPathComponent)
                    p.timeline.insert(c, at: min(insertAt ?? p.timeline.count, p.timeline.count))
                    newID = c.id
                }
                if let sid = project.timeline.first(where: { $0.id == newID })?.sourceID { sourceURLs[sid] = url; infos[sid] = info }
                if let i = insertAt { insertAt = i + 1 }
                lastAdded = newID
            } catch { flash(LF("“%@” cannot be opened.", url.lastPathComponent) + " " + ((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
        }
        if sourceURL == nil, let f = project.sources.first { sourceURL = sourceURLs[f.id]; info = infos[f.id] }
        loadWaveforms()
        if let id = lastAdded { selectedClipIDs = [id] }
        await loadPlayer(at: player.effectiveTime)
    }

    /// Puts photos on the main track at `index` (else after the selected clip, else at the end), each for a few seconds. A photo is played
    /// from a short silent video MacPlayer makes of it in its own folder; the photo itself is only read.
    func addPhotosToTimeline(_ urls: [URL], at index: Int? = nil) async {
        guard isProject, canEdit else { return }
        var insertAt: Int? = index ?? project.timeline.lastIndex { selectedClipIDs.contains($0.id) }.map { $0 + 1 }
        var lastAdded: UUID?
        for url in urls {
            do {
                let video = try await StillClip.make(from: url)
                let info = try await MediaProbe.probe(url: video)
                let ref = SourceRef(path: video.path, bookmark: Bookmarks.make(url), fingerprint: nil, info: info, stillOf: url.path)
                var newID: UUID?
                edit("Add photo", refreshPreview: false) { p in
                    MediaBin.add([url.path], to: &p.mediaBin, bookmark: { _ in ref.bookmark })
                    // The same photo twice uses the same little video.
                    let sid = p.sources.first(where: { $0.stillOf.map { PathUtil.same($0, url.path) } ?? false })?.id ?? { p.sources.append(ref); return ref.id }()
                    let length = MediaTime(seconds: min(StillClip.defaultLength, info.duration.seconds), timescale: 600)
                    let c = TimelineClip(sourceID: sid, sourceStart: .zero, sourceEnd: length, name: url.deletingPathExtension().lastPathComponent)
                    p.timeline.insert(c, at: min(insertAt ?? p.timeline.count, p.timeline.count))
                    newID = c.id
                }
                if let sid = project.timeline.first(where: { $0.id == newID })?.sourceID { sourceURLs[sid] = video; infos[sid] = info }
                if let i = insertAt { insertAt = i + 1 }
                lastAdded = newID
            } catch { flash(LF("“%@” cannot be opened.", url.lastPathComponent) + " " + ((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
        }
        if sourceURL == nil, let f = project.sources.first { sourceURL = sourceURLs[f.id]; info = infos[f.id] }
        if let id = lastAdded { selectedClipIDs = [id] }
        await loadPlayer(at: player.effectiveTime)
    }

    // MARK: Editing the timeline

    func syncActiveClip(_ ids: Set<UUID>) {
        guard isProject else { return }
        let id = project.timeline.first(where: { ids.contains($0.id) })?.id
        guard project.activeClipID != id else { return }
        var p = project; p.activeClipID = id
        history.amend(p)
        objectWillChange.send()
    }

    /// Cuts the clip under the playhead in two, at the exact frame.
    func splitAtPlayhead() {
        guard isProject, let loc = TimelineMap.locate(project.timeline, at: player.currentTime) else { return }
        Task {
            var t = loc.sourceTime
            if let url = sourceURLs[project.timeline[loc.index].sourceID], let f = try? await FrameLocator.frame(url: url, at: t + MediaTime(value: 1, timescale: 6000)) { t = f.time }
            var ok = false
            edit("Split clip") { p in ok = TimelineEditor.split(&p.timeline, clipID: loc.clipID, atSourceTime: t) }
            if ok, let second = project.timeline.firstIndex(where: { $0.id == loc.clipID }).map({ project.timeline[$0 + 1].id }) { selectedClipIDs = [second] }
            else if !ok { flash(L("Move the playhead inside a clip, away from its edges, to split it."), error: true) }
        }
    }

    /// Where the clip the Picture tools edit starts on the timeline, and how long it is.
    var activeClipStart: MediaTime {
        guard isProject, let id = project.activeClipID else { return .zero }
        return TimelineEditor.starts(project.timeline)[id] ?? .zero
    }
    var activeClipDuration: MediaTime {
        if isProject, let id = project.activeClipID, let c = project.timeline.first(where: { $0.id == id }) { return c.duration }
        return isProject ? (project.timeline.first?.duration ?? .zero) : duration
    }
    /// The playhead counted from the start of that clip.
    var localPlayhead: Double { max(0, (player.currentTime - activeClipStart).seconds) }

    func deleteTimelineClips(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        edit("Delete clip") { TimelineEditor.rippleDelete(&$0.timeline, ids: ids) }
        selectedClipIDs.subtract(ids)
    }

    func duplicateTimelineClips(_ ids: Set<UUID>) {
        var last: UUID?
        edit("Duplicate clip") { p in for id in ids { last = TimelineEditor.duplicate(&p.timeline, id: id) ?? last } }
        if let l = last { selectedClipIDs = [l] }
    }

    /// Moves a clip so it sits before the clip that is now at `index` (0...count).
    func moveClip(_ id: UUID, toIndex index: Int) {
        guard let from = project.timeline.firstIndex(where: { $0.id == id }) else { return }
        guard index != from, index != from + 1 else { return }
        edit("Move clip") { TimelineEditor.move(&$0.timeline, fromOffsets: [from], toOffset: index) }
    }

    /// Drag an edge to a timeline time: trims the clip's source range (the picture, not the clip's place).
    func trimClip(_ id: UUID, leftEdge: Bool, toTimelineTime t: MediaTime) {
        guard let c = project.timeline.first(where: { $0.id == id }), let start = TimelineEditor.starts(project.timeline)[id],
              let srcDur = infos[c.sourceID]?.duration else { return }
        let src = c.sourceStart + MediaTime(seconds: max(0, (t - start).seconds) * max(VideoLook.minimumSpeed, c.look.speed), timescale: 6000)
        edit("Trim clip", coalesce: "trim-\(id)") { p in
            if leftEdge { TimelineEditor.trim(&p.timeline, clipID: id, start: src, sourceDuration: srcDur) }
            else { TimelineEditor.trim(&p.timeline, clipID: id, end: src, sourceDuration: srcDur) }
        }
    }

    // MARK: Preview

    func loadProjectPreview(at start: MediaTime?, since generation: Int? = nil) async {
        LayerLive.clear() // the rebuilt preview carries the current values itself
        EffectsLive.clear(); ColorLive.clear(); TransitionLive.clear(); ElementLive.clear(); colorCompare = false
        let used = Set(project.timeline.map(\.sourceID) + project.overlayClips.compactMap(\.sourceID))
        if !missingSourceIDs.intersection(used).isEmpty {
            // With media missing, the preview would not match the timeline's positions, so it waits for a relink.
            player.unload(); reportMissing(); return
        }
        let pieces = project.timeline.compactMap { c in sourceURLs[c.sourceID].map { RenderPiece(sourceURL: $0, span: c.sourceSpan, look: c.look, audio: c.audio, liveKey: c.id) } }
        guard let first = pieces.first else { player.unload(); return }
        let layers = project.layerSpecs(resolve: { sourceURLs[$0]?.path })
        let built = try? await CompositionBuilder.build(pieces: pieces, overlays: project.overlays, cues: project.subtitles.cues,
                                                        subtitleStyle: project.subtitles.style, maxHeight: Self.previewMaxHeight, includeAudio: true, layers: layers, soundClips: resolvedSounds(), frameAccurate: false)
        previewHasCompositor = built?.videoComposition != nil
        await player.load(url: first.sourceURL, preview: built, at: start, since: generation)
    }

    // MARK: Exporting the whole timeline as one new file

    func planProjectExport(_ r: ExportRequest) throws -> (jobs: [ExportJob], batch: BatchPlan) {
        let p = project
        guard !p.timeline.isEmpty else { throw PlanError.nothingToExport }
        let missing = Set(p.timeline.map(\.sourceID) + p.overlayClips.compactMap(\.sourceID)).filter { sourceURLs[$0] == nil }
        var missingNames = p.sources.filter { missing.contains($0.id) }.map { PathUtil.fileName(of: $0.path) }
        for c in p.overlayClips { if case .image(let path, _) = c.kind, !env.fs.exists(path) { missingNames.append(PathUtil.fileName(of: path)) } }
        missingNames += p.soundClips.filter { isMissing($0) }.map(\.name)
        if !missingNames.isEmpty { throw PlanError.missingMedia(missingNames) }
        let layers = p.layerSpecs(resolve: { sourceURLs[$0]?.path })
        guard r.options.mode == .exact else { throw PlanError.projectNeedsExact }
        var options = r.options
        if infos.values.allSatisfy({ !$0.hasAudio }) && !p.overlayClips.contains(where: { $0.isVideo }) && p.soundClips.isEmpty { options.includeAudio = false }

        // Paths from where the videos really are now (a moved source is found through its bookmark).
        let pieces: [JobPiece] = p.timeline.compactMap { c in
            sourceURLs[c.sourceID].map { JobPiece(sourcePath: $0.path, span: c.sourceSpan, look: c.look, audio: c.audio) }
        }
        let base = r.baseName ?? p.name
        let ext = options.container.fileExtension
        let total = p.timelineDuration
        let first = infos.values.first
        let bps = first.map { options.estimatedBytesPerSecond(source: $0) } ?? 2_000_000
        let batch = BatchPlan.make(selections: [ClipSelection(name: base, start: .zero, end: total)], sourcePath: pieces.first?.sourcePath ?? "", folder: r.folder,
                                   fileExtension: ext, template: NamingTemplate(pattern: "{name}"), fs: env.fs, estimatedBytesPerSecond: bps)
        guard batch.canRun else { throw PlanError.issues(batch.issues) }
        let dest = batch.outputs[0].path
        let allPaths = pieces.map(\.sourcePath) + layers.map(\.path)
        if allPaths.contains(where: { PathUtil.same($0, dest) }) { throw PlanError.issues([BatchIssue(kind: .destinationIsSource(dest))]) }

        let shift = MediaTime(seconds: p.subtitles.syncOffset)
        var cues = p.subtitles.cues
        if p.subtitles.syncOffset != 0 { for i in cues.indices { cues[i].start = cues[i].start + shift; cues[i].end = cues[i].end + shift } }
        let recipe = RenderRecipe(look: VideoLook(), audio: AudioSettings(), overlays: p.overlays, subtitleStyle: p.subtitles.style, burnedInCues: p.subtitles.burnIn ? cues : [], layers: layers, soundClips: resolvedSounds())
        let job = ExportJob(label: base, pieces: pieces, recipe: recipe, options: options, target: .newCopy(path: dest, overwrite: r.overwrite),
                            sidecarSubtitles: p.subtitles.burnIn ? [] : cues)
        return ([job], batch)
    }
}
