import AVFoundation
import AppKit
import ImageIO
import MacPlayerCore
import MacPlayerMedia

/// Layers: videos and pictures laid over the main timeline (Picture in Picture, logos, watermarks).
extension EditorSession {
    var selectedOverlay: OverlayClip? { project.overlayClips.first { $0.id == selectedOverlayID } }

    /// What the compositor will do for the output picture's shape, so presets land inside the frame.
    var outputAspect: Double {
        if isPhoto, let size = photoOutputSize, size.height > 0 { return Double(size.width / size.height) }
        guard let v = infos[project.timeline.first?.sourceID ?? UUID()]?.primaryVideo ?? info?.primaryVideo else { return 16.0 / 9 }
        let size = RenderGeometry.outputSize(source: PixelSize(width: v.width, height: v.height), look: project.timeline.first?.look ?? VideoLook())
        return Double(size.width) / Double(max(1, size.height))
    }

    /// The layer's own width / height (video size, or the picture's pixel size).
    func layerAspect(_ c: OverlayClip) -> Double {
        switch c.kind {
        case .video(let sid, _, _): if let v = infos[sid]?.primaryVideo, v.height > 0 { return Double(v.width) / Double(v.height) }
        case .image(let path, _):
            if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double, h > 0 { return w / h }
        }
        return 16.0 / 9
    }

    /// Shows a change to a layer's look at once, without rebuilding the preview: the compositor reads the new numbers
    /// and, when paused, the frame on screen is drawn again. (The full rebuild follows shortly after, as for any edit.)
    func pushLiveLayer(_ id: UUID) {
        if isPhoto { renderPhoto(); return }
        guard isProject else { return }
        if let spec = project.layerSpecs(resolve: { sourceURLs[$0]?.path }).first(where: { $0.id == id }) { LayerLive.set(spec) }
        player.refreshFrame()
    }

    // MARK: Adding

    /// The lane asked for when nothing is on it at that time, else the first free one; nil when all are busy.
    func freeLane(_ wanted: Int?, start: MediaTime, duration: MediaTime) -> Int? {
        if let w = wanted, w >= 0, w < OverlayClip.laneCount {
            let end = start + duration
            if !project.overlayClips.contains(where: { $0.lane == w && $0.start < end && start < $0.end }) { return w }
        }
        return OverlayEditor.firstFreeLane(project.overlayClips, start: start, duration: duration)
    }

    /// Adds videos as layers at `start` (the playhead by default), on `lane` when it is free there, else on the first free one.
    func addOverlayVideos(_ urls: [URL], at start0: MediaTime? = nil, lane wanted: Int? = nil) async {
        guard isProject else { return }
        guard !project.timeline.isEmpty else { flash(L("Add a video to the timeline first."), error: true); return }
        var last: UUID?
        for url in urls {
            do {
                let info = try await MediaProbe.probe(url: url)
                guard info.hasVideo, info.isExportable, let v = info.primaryVideo else { flash(LF("“%@” has no picture or cannot be used here.", url.lastPathComponent), error: true); continue }
                let total = project.timelineDuration
                let start = min(start0 ?? player.currentTime, max(.zero, total - MediaTime(seconds: 0.5)))
                let length = min(info.duration, total - start)
                guard let lane = freeLane(wanted, start: start, duration: length) else {
                    flash(L("All three layers are busy at this point. Move the playhead or remove a layer."), error: true); continue
                }
                let ref = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? env.fs.fingerprint(url.path), info: info)
                var made: OverlayClip?
                edit("Add layer", refreshPreview: false) { p in
                    MediaBin.add([url.path], to: &p.mediaBin, bookmark: { _ in ref.bookmark })
                    let sid = p.addSource(ref)
                    var t = OverlayTransform(); t.width = 0.3
                    OverlayEditor.apply(.bottomRight, to: &t, outputAspect: outputAspect, layerAspect: Double(v.width) / Double(max(1, v.height)))
                    let c = OverlayClip(name: url.deletingPathExtension().lastPathComponent, kind: .video(sourceID: sid, sourceStart: .zero, sourceEnd: length), lane: lane, start: start, duration: length, transform: t)
                    p.overlayClips.append(c); made = c
                }
                if let c = made, let sid = c.sourceID { sourceURLs[sid] = url; infos[sid] = info; last = c.id }
            } catch { flash(LF("“%@” cannot be opened.", url.lastPathComponent) + " " + ((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
        }
        loadWaveforms()
        if let id = last { selectedOverlayID = id; selectedClipIDs = []; activeTool = .layers }
        await loadPlayer(at: player.effectiveTime)
    }

    /// Adds a picture as a layer for 5 seconds at `start` (the playhead by default), on `lane` when it is free there.
    func addOverlayPicture(_ url: URL, at start0: MediaTime? = nil, lane wanted: Int? = nil, center: CGPoint? = nil) async {
        guard canEdit else { return }
        if isPhoto { addLogo(url, center: center); return }
        guard isProject else { return }
        guard !project.timeline.isEmpty else { flash(L("Add a video to the timeline first."), error: true); return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else {
            flash(LF("“%@” cannot be opened.", url.lastPathComponent), error: true); return
        }
        // An animation (a moving sticker, 0.16) is played from a see-through video MacPlayer makes of it, as a video layer.
        if PhotoLoader.animation(url: url) != nil { await addAnimatedLayer(url, at: start0, lane: wanted, center: center, aspect: w / h); return }
        let total = project.timelineDuration
        let start = min(start0 ?? player.currentTime, max(.zero, total - MediaTime(seconds: 0.5)))
        let length = min(MediaTime(seconds: 5), total - start)
        guard let lane = freeLane(wanted, start: start, duration: length) else {
            flash(L("All three layers are busy at this point. Move the playhead or remove a layer."), error: true); return
        }
        var made: UUID?
        edit("Add layer", refreshPreview: false) { p in
            MediaBin.add([url.path], to: &p.mediaBin, bookmark: { Bookmarks.make(URL(fileURLWithPath: $0)) })
            var t = OverlayTransform(); t.width = 0.18
            OverlayEditor.apply(.topRight, to: &t, outputAspect: outputAspect, layerAspect: w / h)
            if let center { t.centerX = Double(center.x); t.centerY = Double(center.y) }
            let c = OverlayClip(name: url.deletingPathExtension().lastPathComponent, kind: .image(path: url.path, bookmark: Bookmarks.make(url)), lane: lane, start: start, duration: length, transform: t)
            p.overlayClips.append(c); made = c.id
        }
        if let made { select(.layer(made)) }; activeTool = .layers
        await loadPlayer(at: player.effectiveTime)
    }

    /// An animated picture as a layer: at least 5 seconds (the animation repeats), at least once through, top right like a picture layer.
    func addAnimatedLayer(_ url: URL, at start0: MediaTime?, lane wanted: Int?, center: CGPoint?, aspect: Double) async {
        do {
            guard let video = try await StillClip.makeLayer(from: url), let anim = PhotoLoader.animation(url: url) else { return }
            let info = try await MediaProbe.probe(url: video)
            let total = project.timelineDuration
            let start = min(start0 ?? player.currentTime, max(.zero, total - MediaTime(seconds: 0.5)))
            let want = MediaTime(seconds: min(info.duration.seconds, max(5, anim.duration)), timescale: 600)
            let length = min(want, total - start)
            guard let lane = freeLane(wanted, start: start, duration: length) else {
                flash(L("All three layers are busy at this point. Move the playhead or remove a layer."), error: true); return
            }
            let ref = SourceRef(path: video.path, bookmark: Bookmarks.make(url), fingerprint: nil, info: info, stillOf: url.path)
            var made: OverlayClip?
            edit("Add layer", refreshPreview: false) { p in
                MediaBin.add([url.path], to: &p.mediaBin, bookmark: { _ in ref.bookmark })
                let sid = p.sources.first(where: { $0.stillOf.map { PathUtil.same($0, url.path) } ?? false && $0.path == video.path })?.id ?? p.addSource(ref)
                var t = OverlayTransform(); t.width = 0.18
                OverlayEditor.apply(.topRight, to: &t, outputAspect: outputAspect, layerAspect: aspect)
                if let center { t.centerX = Double(center.x); t.centerY = Double(center.y) }
                let c = OverlayClip(name: url.deletingPathExtension().lastPathComponent, kind: .video(sourceID: sid, sourceStart: .zero, sourceEnd: length), lane: lane, start: start, duration: length, transform: t)
                p.overlayClips.append(c); made = c
            }
            if let c = made, let sid = c.sourceID { sourceURLs[sid] = video; infos[sid] = info; select(.layer(c.id)) }
            activeTool = .layers
            await loadPlayer(at: player.effectiveTime)
        } catch { flash(LF("“%@” cannot be opened.", url.lastPathComponent) + " " + ((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
    }

    /// A logo on a photo project: a picture laid over the photo, always shown. The photo itself stays the only photo of the project.
    func addLogo(_ url: URL, center: CGPoint? = nil) {
        guard isPhoto else { return }
        guard !project.sources.isEmpty else { flash(L("Choose the photo of this project first."), error: true); return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else {
            flash(LF("“%@” cannot be opened.", url.lastPathComponent), error: true); return
        }
        var made: UUID?
        edit("Add logo") { p in
            var t = OverlayTransform(); t.width = 0.2
            OverlayEditor.apply(.topRight, to: &t, outputAspect: outputAspect, layerAspect: w / h)
            if let center { t.centerX = Double(center.x); t.centerY = Double(center.y) }
            let lane = min(OverlayClip.laneCount - 1, p.overlayClips.count)
            let c = OverlayClip(name: url.deletingPathExtension().lastPathComponent, kind: .image(path: url.path, bookmark: Bookmarks.make(url)), lane: lane,
                                start: .zero, duration: MediaTime(seconds: 200_000), transform: t)
            p.overlayClips.append(c); made = c.id
        }
        if let made { select(.layer(made)) }; activeTool = .layers
    }

    // MARK: Editing

    func deleteOverlay(_ id: UUID) {
        edit("Delete layer") { $0.overlayClips.removeAll { $0.id == id } }
        if selectedOverlayID == id { selectedOverlayID = nil }
    }

    func duplicateOverlay(_ id: UUID) {
        guard let c = project.overlayClips.first(where: { $0.id == id }) else { return }
        var copy = c; copy.id = UUID(); copy.name = c.name + " 2"; copy.keyframes = c.keyframes.map { var k = $0; k.id = UUID(); return k }
        if isPhoto {
            copy.transform.centerX = min(0.95, c.transform.centerX + 0.05); copy.transform.centerY = min(0.95, c.transform.centerY + 0.05)
            edit("Duplicate layer") { $0.overlayClips.append(copy) }
            selectedOverlayID = copy.id
            return
        }
        // Next free place: right after the original in its lane, or another lane at the same time.
        let after = c.end
        let total = project.timelineDuration
        if let lane = OverlayEditor.firstFreeLane(project.overlayClips, start: c.start, duration: c.duration) { copy.lane = lane }
        else if after + c.duration <= total, OverlayEditor.firstFreeLane(project.overlayClips, start: after, duration: c.duration) != nil {
            copy.start = after; copy.lane = OverlayEditor.firstFreeLane(project.overlayClips, start: after, duration: c.duration) ?? c.lane
        } else { flash(L("There is no free place for a copy."), error: true); return }
        edit("Duplicate layer") { $0.overlayClips.append(copy) }
        selectedOverlayID = copy.id
    }

    /// Runs `change` on one layer as a single undo step (steps with the same `coalesce` key in a row merge).
    func updateOverlay(_ id: UUID, _ label: String, coalesce: String? = nil, _ change: @escaping (inout OverlayClip) -> Void) {
        edit(label, coalesce: coalesce.map { "\($0)-\(id)" }) { p in
            if let i = p.overlayClips.firstIndex(where: { $0.id == id }) { change(&p.overlayClips[i]) }
        }
        pushLiveLayer(id)
    }

    func moveOverlay(_ id: UUID, toStart start: MediaTime, lane: Int? = nil, coalesce: Bool = true) {
        let total = project.timelineDuration
        var probe = project.overlayClips
        guard OverlayEditor.move(&probe, id: id, toStart: start, lane: lane, limit: total) else { return }
        edit("Move layer", coalesce: coalesce ? "ovmove-\(id)" : nil) { p in _ = OverlayEditor.move(&p.overlayClips, id: id, toStart: start, lane: lane, limit: total) }
    }

    func trimOverlay(_ id: UUID, leftEdge: Bool, toTimelineTime t: MediaTime) {
        guard let c = project.overlayClips.first(where: { $0.id == id }) else { return }
        let srcDur = c.sourceID.flatMap { infos[$0]?.duration }
        let total = project.timelineDuration
        edit("Trim layer", coalesce: "ovtrim-\(id)") { p in OverlayEditor.trim(&p.overlayClips, id: id, leftEdge: leftEdge, toTimelineTime: t, sourceDuration: srcDur, limit: total) }
    }

    /// Changes position, size or opacity at the playhead. A layer with keyframes gets (or updates) one here, as video editors
    /// do; one without keyframes changes its base values.
    /// The same change on a draft of the project (a drag on the picture, written once at the drop).
    func setOverlayValue(_ id: UUID, in p: inout Project, _ change: (inout OverlayState) -> Void) {
        guard let i = p.overlayClips.firstIndex(where: { $0.id == id }) else { return }
        Self.applyOverlayValue(&p.overlayClips[i], at: player.currentTime, change)
    }

    static func applyOverlayValue(_ c: inout OverlayClip, at now: MediaTime, _ change: (inout OverlayState) -> Void) {
        var s = OverlayEditor.editableState(c, at: now)
        change(&s)
        if c.keyframes.isEmpty {
            c.transform.centerX = s.centerX; c.transform.centerY = s.centerY; c.transform.width = s.width; c.transform.opacity = s.opacity; c.transform.rotation = s.rotation
            c.transform = c.transform.clamped()
        } else {
            var clamped = OverlayTransform(); clamped.centerX = s.centerX; clamped.centerY = s.centerY; clamped.width = s.width; clamped.opacity = s.opacity; clamped.rotation = s.rotation
            clamped = clamped.clamped()
            OverlayEditor.setKeyframe(&c, at: now - c.start, to: OverlayState(centerX: clamped.centerX, centerY: clamped.centerY, width: clamped.width, opacity: clamped.opacity, rotation: clamped.rotation))
        }
    }

    func setOverlayValue(_ id: UUID, _ label: String, _ change: @escaping (inout OverlayState) -> Void) {
        let now = player.currentTime
        updateOverlay(id, label, coalesce: "ovval-\(label)") { c in
            var s = OverlayEditor.editableState(c, at: now)
            change(&s)
            if c.keyframes.isEmpty {
                c.transform.centerX = s.centerX; c.transform.centerY = s.centerY; c.transform.width = s.width; c.transform.opacity = s.opacity; c.transform.rotation = s.rotation
                c.transform = c.transform.clamped()
            } else {
                var clamped = OverlayTransform(); clamped.centerX = s.centerX; clamped.centerY = s.centerY; clamped.width = s.width; clamped.opacity = s.opacity; clamped.rotation = s.rotation
                clamped = clamped.clamped()
                OverlayEditor.setKeyframe(&c, at: now - c.start, to: OverlayState(centerX: clamped.centerX, centerY: clamped.centerY, width: clamped.width, opacity: clamped.opacity, rotation: clamped.rotation))
            }
        }
    }

    func applyOverlayPreset(_ id: UUID, _ preset: OverlayEditor.Preset) {
        guard let c = project.overlayClips.first(where: { $0.id == id }) else { return }
        let layerAspect = self.layerAspect(c)
        let oa = outputAspect, now = player.currentTime
        updateOverlay(id, "Layer position") { c in
            if c.keyframes.isEmpty { OverlayEditor.apply(preset, to: &c.transform, outputAspect: oa, layerAspect: layerAspect) }
            else {
                var t = c.transform; t.width = OverlayEditor.editableState(c, at: c.start).width
                OverlayEditor.apply(preset, to: &t, outputAspect: oa, layerAspect: layerAspect)
                OverlayEditor.setKeyframe(&c, at: now - c.start, to: OverlayState(centerX: t.centerX, centerY: t.centerY, width: t.width, opacity: OverlayEditor.editableState(c, at: now).opacity, rotation: OverlayEditor.editableState(c, at: now).rotation))
            }
        }
    }

    func addKeyframe(_ id: UUID) {
        let now = player.currentTime
        updateOverlay(id, "Add keyframe") { c in
            let s = OverlayEditor.editableState(c, at: now)
            OverlayEditor.setKeyframe(&c, at: now - c.start, to: s)
            // The first keyframe also fixes the starting look, so the layer does not jump when it is animated.
            if c.keyframes.count == 1, now > c.start { OverlayEditor.setKeyframe(&c, at: .zero, to: s) }
        }
    }

    func removeKeyframe(_ id: UUID, keyframe kid: UUID) { updateOverlay(id, "Delete keyframe") { $0.keyframes.removeAll { $0.id == kid } } }
    /// How the values move on from one keyframe to the next.
    func setKeyframeEasing(_ id: UUID, keyframe kid: UUID, _ easing: Easing) {
        updateOverlay(id, "Keyframe easing") { c in if let i = c.keyframes.firstIndex(where: { $0.id == kid }) { c.keyframes[i].easing = easing } }
    }
    func clearKeyframes(_ id: UUID) { updateOverlay(id, "Clear animation") { $0.keyframes = [] } }
}
