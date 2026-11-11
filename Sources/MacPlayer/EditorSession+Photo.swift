import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// A picture opened for looking at and editing. It uses the same session, edit history, panels and renderer as a video; what differs is that
/// the picture is drawn into an image (no player, no timeline) and that it is saved as a picture.
extension EditorSession {
    /// The longest side of the copy the screen preview is drawn from. Bigger than any window needs, so zooming in stays sharp.
    static let photoPreviewPixels = 3200
    /// The longest side of the frames an animation is drawn from.
    static let animationPreviewPixels = 960

    /// The question before the photo of a project is changed; a test answers it without a dialog.
    nonisolated(unsafe) static var confirmReplacePhoto: (NSAlert) -> Bool = { $0.runModal() == .alertFirstButtonReturn }

    var isPhoto: Bool { project.kind == .photo }

    /// A photo opened to look at (the playlist side).
    static func openPhoto(url: URL) async throws -> EditorSession {
        let info = try PhotoLoader.info(url: url)
        let fs = AppEnvironment.shared.fs
        let src = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? fs.fingerprint(url.path), info: info)
        let project = Project(name: url.deletingPathExtension().lastPathComponent, kind: .photo, sources: [src])
        let s = EditorSession(project: project, projectPath: nil, role: .viewer)
        try await s.attachPhoto(url: url, info: info)
        return s
    }

    // MARK: The one photo of a photo project

    /// An empty photo project gets its photo.
    func choosePhoto(_ url: URL) async {
        switch ProjectRules.canAdd(paths: [url.path], to: project) {
        case .ok: break
        case .photoAlreadyChosen: await replacePhoto(url); return
        default: flash(Self.ruleText(ProjectRules.canAdd(paths: [url.path], to: project)), error: true); return
        }
        do {
            let info = try PhotoLoader.info(url: url)
            let ref = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? env.fs.fingerprint(url.path), info: info)
            edit("Choose photo", refreshPreview: false) { p in p.sources = [ref]; if p.name.isEmpty { p.name = url.deletingPathExtension().lastPathComponent } }
            try await attachPhoto(url: url, info: info)
            notice = nil
        } catch { flash(LF("“%@” cannot be opened.", url.lastPathComponent) + " " + ((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
    }

    /// Puts another photo in the project. The edit stays (colour, effects, text, logos); the crop and the turn start again when the new
    /// photo has another shape. One undo step; the old photo file is not touched.
    func replacePhoto(_ url: URL, ask: Bool = true) async {
        guard isPhoto, ImageFiles.isCandidate(url.path) else { flash(L("Choose a photo."), error: true); return }
        guard let info = try? PhotoLoader.info(url: url), let v = info.primaryVideo else { flash(LF("“%@” cannot be opened.", url.lastPathComponent), error: true); return }
        if ask, !project.sources.isEmpty {
            let a = NSAlert()
            a.messageText = LF("Use “%@” as the photo of this project?", url.lastPathComponent)
            a.informativeText = L("The colour, effects, text and logos stay. The crop and the turn start again if the new photo has another shape. The old photo file is not changed or removed. You can undo this.")
            a.addButton(withTitle: L("Change Photo")); a.addButton(withTitle: L("Cancel"))
            guard Self.confirmReplacePhoto(a) else { return }
        }
        let oldShape = project.sources.first?.info?.primaryVideo.map { Double($0.width) / Double(max(1, $0.height)) }
        let newShape = Double(v.width) / Double(max(1, v.height))
        let ref = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? env.fs.fingerprint(url.path), info: info)
        edit("Change photo", refreshPreview: false) { p in
            p.sources = [ref]
            if let o = oldShape, abs(o - newShape) > 0.01 { p.look.crop = .full; p.look.rotation = 0; p.look.flipHorizontal = false; p.look.flipVertical = false }
        }
        try? await attachPhoto(url: url, info: info)
        notice = nil
    }

    /// Why media cannot go into this project, in the person's words.
    static func ruleText(_ d: ProjectRules.AddDecision) -> String {
        switch d {
        case .ok: return ""
        case .wrongKind(project: .video): return L("This is a video project: only videos go on its timeline. Photos can be added as layers (File ▸ Add Overlay Picture…).")
        case .wrongKind(project: .photo): return L("This is a photo project: it holds one photo. Make a video project for videos.")
        case .photoAlreadyChosen, .onePhotoOnly: return L("A photo project holds one photo. Make another photo project for the others.")
        case .notMedia: return L("Only videos and photos can be added.")
        }
    }

    func attachPhoto(url: URL, info: MediaInfo) async throws {
        sourceURL = url
        self.info = info
        if let id = project.sources.first?.id { sourceURLs[id] = url; infos[id] = info }
        if project.sources.first?.info != info { mutateQuietly { $0.sources[0].info = info } }
        let max = Self.photoPreviewPixels
        photoAnimation = PhotoLoader.animation(url: url)
        photoFrames = []; photoFrameBases = []
        if let animation = photoAnimation {
            // An animation is drawn from smaller frames (every edit draws all of them).
            let side = Self.animationPreviewPixels
            let frames: [CGImage] = try await Task.detached(priority: .userInitiated) { try (0..<animation.frameCount).map { try PhotoLoader.frame(url: url, index: $0, maxPixel: side) } }.value
            photoFrameBases = frames.map { CIImage(cgImage: $0) }
            photoBase = PhotoLoader.Loaded(image: photoFrameBases[0], pixelWidth: info.primaryVideo?.width ?? frames[0].width, pixelHeight: info.primaryVideo?.height ?? frames[0].height, colorSpace: frames[0].colorSpace)
            photoPlaying = true
        } else {
            photoBase = try await Task.detached(priority: .userInitiated) { try PhotoLoader.preview(url: url, maxPixel: max) }.value
        }
        photoZoom = 1; photoOffset = .zero
        if photoAnimation != nil { photoDraft.options.format = .gif }
        else if let own = PhotoFormat.matching(extension: url.pathExtension) { photoDraft.options.format = own }      // saved in the format it came in unless told otherwise
        if ProcessInfo.processInfo.environment["MACPLAYER_START_TAB"] == nil { activeTool = .picture }
        photoCropRatio = nil
        updateCropEditing(tool: activeTool)
        renderPhoto()
        // Development aid: MACPLAYER_DEV_CROP="x,y,w,h" puts a frame on the picture, to look at the crop tool.
        if let v = ProcessInfo.processInfo.environment["MACPLAYER_DEV_CROP"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 4, project.look.crop.isFull { setPhotoCropFrame(CropRect(x: v[0], y: v[1], width: v[2], height: v[3]), coalesce: nil) }
    }

    /// Draws the picture with the edit as it stands. Several in a row (a slider being dragged) only show the last one.
    func renderPhoto() {
        guard let base = photoBase else { return }
        photoRenderGeneration += 1
        let generation = photoRenderGeneration
        var look = project.look
        if colorCompare { look.color = ColorAdjust() }
        let overlays = project.overlays
        if photoCropEditing { look.crop = .full; look.canvas = .source }          // the whole picture, so the frame has all of it to sit on
        let logos = PhotoLogo.load(project.overlayClips) { [weak self] path in
            if let i = self?.photoLogoCache[path] { return i }
            let i = PhotoLogo.readImage(path); self?.photoLogoCache[path] = i; return i
        }
        final class Job: @unchecked Sendable { let base: PhotoLoader.Loaded; let look: VideoLook; let overlays: [TextOverlay]; let logos: [PhotoLogo]
            init(_ b: PhotoLoader.Loaded, _ l: VideoLook, _ o: [TextOverlay], _ g: [PhotoLogo]) { base = b; look = l; overlays = o; logos = g } }
        let job = Job(base, look, overlays, photoCropEditing ? [] : logos)
        let frames = photoFrameBases
        if frames.count > 1 { photoFrames = [] }          // the one edited frame shows at once; the animation comes back when all frames are drawn
        final class Frames: @unchecked Sendable { let list: [CIImage]; init(_ l: [CIImage]) { list = l } }
        let box = Frames(frames)
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = PhotoRenderer.render(base: job.base.image, look: job.look, overlays: job.overlays, logos: job.logos)
            let cg = PhotoRenderer.cgImage(image, colorSpace: job.base.colorSpace)
            await MainActor.run { if let self, self.photoRenderGeneration == generation { self.photoImage = cg } }
            guard box.list.count > 1 else { return }
            // An animation: every frame gets the same edit; they replace the one frame when all are ready.
            var drawn: [CGImage] = []
            for f in box.list {
                if await MainActor.run(body: { self?.photoRenderGeneration != generation }) { return }
                if let cg = PhotoRenderer.cgImage(PhotoRenderer.render(base: f, look: job.look, overlays: job.overlays, logos: job.logos), colorSpace: job.base.colorSpace) { drawn.append(cg) }
            }
            await MainActor.run { if let self, self.photoRenderGeneration == generation { self.photoFrames = drawn } }
        }
    }

    /// The size the saved picture has with the edit as it stands (before any size limit).
    var photoOutputSize: CGSize? {
        guard let v = info?.primaryVideo else { return nil }
        return PhotoRenderer.outputSize(source: CGSize(width: v.width, height: v.height), look: project.look)
    }

    /// The size, to the pixel, that saving gives with the edit and the size limit as they stand now.
    var photoSavedSize: (width: Int, height: Int)? {
        guard let v = info?.primaryVideo else { return nil }
        let p = PhotoExporter.plannedSize(width: Double(v.width), height: Double(v.height), look: project.look, maxLongEdge: photoDraft.options.maxLongEdge)
        return (p.width, p.height)
    }

    // MARK: Cropping on the picture

    /// The frame is drawn when a photo is open on its Picture tool and the frame is switched on.
    func updateCropEditing(tool: InspectorTab? = nil, adjusting: Bool? = nil) {
        let editing = isPhoto && (tool ?? activeTool) == .picture && (adjusting ?? photoCropAdjusting)
        guard editing != photoCropEditing else { return }
        photoCropEditing = editing
        renderPhoto()
    }

    /// The picture as it is shown (turned by the quarter turns): its width / height in pixels.
    var photoShownAspect: Double {
        guard let v = info?.primaryVideo else { return 1 }
        let s = CropGeometry.shownSize(width: Double(v.width), height: Double(v.height), rotation: project.look.rotation)
        return s.width / max(1, s.height)
    }

    /// The crop frame as it is on the shown picture.
    var photoCropFrame: CropRect {
        let l = project.look
        return CropGeometry.toDisplay(l.crop, rotation: l.rotation, flipH: l.flipHorizontal, flipV: l.flipVertical)
    }

    /// Sets the crop from a frame on the shown picture.
    func setPhotoCropFrame(_ frame: CropRect, coalesce: String? = "photo-crop") {
        let l = project.look
        let source = CropGeometry.toSource(frame, rotation: l.rotation, flipH: l.flipHorizontal, flipV: l.flipVertical).clamped(minSize: 0.02)
        edit("Crop", coalesce: coalesce, refreshPreview: !photoCropEditing) { $0.look.crop = source }
    }

    /// Keeps the frame in a shape (nil = free) and makes it the largest of that shape, around where it was.
    func setPhotoCropShape(_ ratio: Double?) {
        photoCropRatio = ratio
        guard let ratio else { return }
        setPhotoCropFrame(CropGeometry.largest(ratio: ratio, pictureAspect: photoShownAspect, around: photoCropFrame), coalesce: nil)
    }

    // MARK: Looking

    func photoZoomIn() { photoZoom = min(16, photoZoom * 1.35) }
    func photoZoomOut() { photoZoom = max(1, photoZoom / 1.35); if photoZoom == 1 { photoOffset = .zero } }
    func photoFit() { photoZoom = 1; photoOffset = .zero }
}

// MARK: Saving

/// What the Export tool of a photo is set to; kept in the session so it survives switching tools.
struct PhotoSaveDraft {
    var options = PhotoExportOptions()
    var name = ""
    var folder: String?
    /// Where the last save went, for "Show in Finder".
    var lastSaved: URL?
    var saving = false
}

extension EditorSession {
    /// A free file name in a folder: the wanted one, or with a number added (nothing existing is ever overwritten).
    func freePhotoPath(folder: String, name: String, ext: String) -> String {
        var candidate = PathUtil.join(folder, name + "." + ext), n = 2
        while env.fs.exists(candidate) { candidate = PathUtil.join(folder, "\(name) \(n).\(ext)"); n += 1 }
        return candidate
    }

    /// Saves the photo as the Export tool says: always a NEW file, next to the photo or in the chosen folder (never over anything).
    /// Written to a temporary file, checked, and only then moved into place. The original photo is never changed.
    func savePhoto() {
        guard let url = sourceURL, isPhoto, !photoDraft.saving else { return }
        let draft = photoDraft, options = draft.options
        let look = project.look, overlays = project.overlays, layers = project.overlayClips
        let target = photoSavedSize ?? (width: 0, height: 0)
        let estimate = Int64(target.width) * Int64(target.height) * (options.format.isLossy ? 1 : 4) + 200_000
        let produce: SafeSaver.Produce = { temp in
            _ = try await Task.detached(priority: .userInitiated) { try PhotoExporter.export(source: url, look: look, overlays: overlays, layers: layers, options: options, to: URL(fileURLWithPath: temp)) }.value
        }
        let expectedFrames = options.format == .gif ? photoAnimation?.frameCount : nil
        let verify: SafeSaver.Verify = { temp in
            guard let info = try? PhotoLoader.info(url: URL(fileURLWithPath: temp)), info.primaryVideo?.width == target.width, info.primaryVideo?.height == target.height else {
                throw SaveError.verificationFailed("the saved picture cannot be read back at the expected size")
            }
            if let n = expectedFrames, PhotoLoader.animation(url: URL(fileURLWithPath: temp))?.frameCount != n {
                throw SaveError.verificationFailed("the saved animation does not have all its frames")
            }
        }
        let saver = env.saver, fs = env.fs

        let folder = draft.folder ?? env.prefs.lastExportFolder ?? PathUtil.directory(of: url.path)
        let base = draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? url.deletingPathExtension().lastPathComponent + env.prefs.copySuffix : draft.name
        let destination = freePhotoPath(folder: folder, name: base, ext: options.format.fileExtension)
        photoDraft.saving = true
        Task {
            defer { photoDraft.saving = false }
            do {
                let outcome = try await saver.saveCopy(sourcePath: url.path, destination: destination, overwrite: false, estimatedBytes: estimate, produce: produce, verify: verify)
                _ = fs
                photoDraft.lastSaved = URL(fileURLWithPath: outcome.finalPath)
                flash(LF("Saved %@", PathUtil.fileName(of: outcome.finalPath)))
            } catch { flash(ErrorText.localized((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
        }
    }
}
