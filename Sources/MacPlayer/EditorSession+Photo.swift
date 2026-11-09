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

    /// The question before an original is replaced; a test answers it without a dialog.
    nonisolated(unsafe) static var confirmReplace: (NSAlert) -> Bool = { $0.runModal() == .alertFirstButtonReturn }

    var isPhoto: Bool { sourceURL.map { ImageFiles.isCandidate($0.path) } ?? false }

    static func openPhoto(url: URL) async throws -> EditorSession {
        let info = try PhotoLoader.info(url: url)
        let fs = AppEnvironment.shared.fs
        let src = SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: try? fs.fingerprint(url.path), info: info)
        let project = Project(name: url.deletingPathExtension().lastPathComponent, mode: .quick, sources: [src])
        let s = EditorSession(project: project, projectPath: nil)
        try await s.attachPhoto(url: url, info: info)
        return s
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
        final class Job: @unchecked Sendable { let base: PhotoLoader.Loaded; let look: VideoLook; let overlays: [TextOverlay]
            init(_ b: PhotoLoader.Loaded, _ l: VideoLook, _ o: [TextOverlay]) { base = b; look = l; overlays = o } }
        let job = Job(base, look, overlays)
        let frames = photoFrameBases
        if frames.count > 1 { photoFrames = [] }          // the one edited frame shows at once; the animation comes back when all frames are drawn
        final class Frames: @unchecked Sendable { let list: [CIImage]; init(_ l: [CIImage]) { list = l } }
        let box = Frames(frames)
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = PhotoRenderer.render(base: job.base.image, look: job.look, overlays: job.overlays)
            let cg = PhotoRenderer.cgImage(image, colorSpace: job.base.colorSpace)
            await MainActor.run { if let self, self.photoRenderGeneration == generation { self.photoImage = cg } }
            guard box.list.count > 1 else { return }
            // An animation: every frame gets the same edit; they replace the one frame when all are ready.
            var drawn: [CGImage] = []
            for f in box.list {
                if await MainActor.run(body: { self?.photoRenderGeneration != generation }) { return }
                if let cg = PhotoRenderer.cgImage(PhotoRenderer.render(base: f, look: job.look, overlays: job.overlays), colorSpace: job.base.colorSpace) { drawn.append(cg) }
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
    var replaceOriginal = false
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

    /// Why the original cannot be replaced right now (nil when it can).
    var photoReplaceProblem: String? {
        guard let url = sourceURL else { return L("No photo is open.") }
        if sourceChangedExternally { return L("The original was changed by another app, so it cannot be replaced.") }
        if project.sources.first?.fingerprint == nil { return L("The original cannot be checked, so it will not be replaced.") }
        if PhotoFormat.matching(extension: url.pathExtension) != photoDraft.options.format {
            return LF("Replacing the original keeps its format (.%@). Choose that format, or save a new photo.", url.pathExtension.lowercased())
        }
        return nil
    }

    /// Saves the photo as the Export tool says: a new file next to it (or in the chosen folder), or in place of the original after a question, with
    /// a backup copy first when that is switched on. Written to a temporary file, checked, and only then moved into place.
    func savePhoto() {
        guard let url = sourceURL, isPhoto, !photoDraft.saving else { return }
        let draft = photoDraft, options = draft.options
        let look = project.look, overlays = project.overlays
        let target = photoSavedSize ?? (width: 0, height: 0)
        let estimate = Int64(target.width) * Int64(target.height) * (options.format.isLossy ? 1 : 4) + 200_000
        let produce: SafeSaver.Produce = { temp in
            _ = try await Task.detached(priority: .userInitiated) { try PhotoExporter.export(source: url, look: look, overlays: overlays, options: options, to: URL(fileURLWithPath: temp)) }.value
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

        if draft.replaceOriginal {
            if let problem = photoReplaceProblem { flash(problem, error: true); return }
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = LF("Replace the original photo “%@”?", url.lastPathComponent)
            a.informativeText = env.prefs.backupBeforeReplace ? L("The original is replaced after the new picture has been checked. A backup copy of the original is kept first.")
                                                                 : L("The original is replaced and no backup is kept (Settings).")
            a.addButton(withTitle: L("Replace")); a.addButton(withTitle: L("Cancel"))
            guard Self.confirmReplace(a), let fp = project.sources.first?.fingerprint else { return }
            let plan = ReplacePlan(sourcePath: url.path, expected: fp, backupFolder: backupFolder(), newExtension: url.pathExtension)
            photoDraft.saving = true
            Task {
                defer { photoDraft.saving = false }
                do {
                    let outcome = try await saver.replaceOriginal(plan: plan, estimatedBytes: estimate, produce: produce, verify: verify)
                    photoDraft.lastSaved = url
                    await afterReplacePhoto(backupPath: outcome.backupPath)
                } catch { flash(ErrorText.localized((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true) }
            }
            return
        }

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

    /// After the original was replaced the file on disk is the edited picture, so the session starts again from it.
    func afterReplacePhoto(backupPath: String?) async {
        guard let url = sourceURL, let newInfo = try? PhotoLoader.info(url: url) else { return }
        let fp = try? env.fs.fingerprint(url.path)
        var p = Project(name: project.name, mode: .quick, sources: [SourceRef(path: url.path, bookmark: Bookmarks.make(url), fingerprint: fp, info: newInfo, changedAfterReplace: true)])
        p.id = project.id
        history = History(p)
        sourceChangedExternally = false
        isDirty = false
        try? await attachPhoto(url: url, info: newInfo)
        flash(backupPath.map { LF("Original replaced. Undo does not restore the old file; the backup is at %@", $0) } ?? L("Original replaced. No backup was kept."))
    }
}
