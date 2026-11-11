import Foundation

/// What may go into a project. A video project holds videos (pictures only as layers over them); a photo project holds exactly
/// one photo, plus logos laid over it. Every way of adding media (drop, menus, relink, upgrade of an old file) asks here first,
/// so the rule lives in one place.
public enum ProjectRules {
    public enum AddDecision: Equatable, Sendable {
        case ok
        /// The file is not of the project's kind (a photo dropped on a video project, a video on a photo project).
        case wrongKind(project: ProjectKind)
        /// A photo project already has its photo.
        case photoAlreadyChosen
        /// Several photos for a photo project at once.
        case onePhotoOnly
        /// Neither a video nor a picture.
        case notMedia
    }

    /// Can these files become the project's main media (timeline clips, or the photo)?
    public static func canAdd(paths: [String], to p: Project) -> AddDecision {
        guard !paths.isEmpty else { return .notMedia }
        let kinds = paths.map { MediaFiles.kind(of: $0) }
        if kinds.contains(where: { $0 == nil }) { return .notMedia }
        switch p.kind {
        case .video:
            return kinds.allSatisfy { $0 == .video } ? .ok : .wrongKind(project: .video)
        case .photo:
            guard kinds.allSatisfy({ $0 == .image }) else { return .wrongKind(project: .photo) }
            if paths.count > 1 { return .onePhotoOnly }
            return p.sources.isEmpty ? .ok : .photoAlreadyChosen
        }
    }

    public enum Violation: Equatable, Sendable {
        case photoProjectHasSeveralSources(Int)
        case photoProjectHasTimeline
        case photoProjectHasVideoLayer
        case photoSourceIsNotAPicture(String)
    }

    /// Breaks of the rules in a project read from disk (a damaged or hand-edited file). Such a project opens read-only.
    public static func violations(_ p: Project) -> [Violation] {
        guard p.kind == .photo else { return [] }
        var out: [Violation] = []
        if p.sources.count > 1 { out.append(.photoProjectHasSeveralSources(p.sources.count)) }
        if !p.timeline.isEmpty { out.append(.photoProjectHasTimeline) }
        if p.overlayClips.contains(where: { $0.isVideo }) { out.append(.photoProjectHasVideoLayer) }
        for s in p.sources where !ImageFiles.isCandidate(s.path) { out.append(.photoSourceIsNotAPicture(s.path)) }
        return out
    }
}

/// Turns what MacPlayer 0.7 and older saved into today's projects. Pure, so every old shape is tested.
public enum ProjectUpgrade {
    /// The kind an old file stands for: a "quick" edit of a picture is a photo project; everything else is a video project.
    public static func kind(legacyMode: String?, firstSourcePath: String?) -> ProjectKind {
        if legacyMode == "quick", let path = firstSourcePath, ImageFiles.isCandidate(path) { return .photo }
        return .video
    }

    /// An old "quick" edit of one video becomes a video project with one clip: the whole video, with the edit that was on it.
    /// The result is what exporting the whole video gave before: text and subtitles stay where they were, sounds and markers
    /// follow the video's speed. In/Out ranges stay in the file, unused. When the video's length is not known yet, the clip is
    /// made later by `finishQuickVideo` (the app calls it once it has read the video).
    public static func upgradeQuickVideo(_ p: inout Project) {
        guard p.kind == .video, p.mode == .quick else { p.mode = nil; return }
        p.mode = nil
        guard let src = p.sources.first, let duration = src.info?.duration, duration > .zero else {
            p.pendingQuickUpgrade = true
            return
        }
        finishQuickVideo(&p, duration: duration)
    }

    /// Makes the one clip of an upgraded quick edit, now that the video's length is known.
    public static func finishQuickVideo(_ p: inout Project, duration: MediaTime) {
        guard let src = p.sources.first else { p.pendingQuickUpgrade = nil; return }
        let look = p.look, audio = p.audio
        let whole = TimeSpan(start: .zero, end: duration)
        let speed = max(VideoLook.minimumSpeed, look.speed)
        let clip = TimelineClip(sourceID: src.id, sourceStart: .zero, sourceEnd: duration, name: p.name, look: look, audio: audio)
        p.timeline = [clip]
        p.activeClipID = clip.id
        p.look = VideoLook(); p.audio = AudioSettings()
        // Sounds were placed in the video's own time and slowed or sped with it on export.
        p.soundClips = p.soundClips.compactMap { $0.cropped(to: whole, speed: look.speed) }
        if speed != 1 {
            for i in p.markers.indices { p.markers[i].time = MediaTime(seconds: p.markers[i].time.seconds / speed, timescale: 6000) }
            p.playhead = MediaTime(seconds: p.playhead.seconds / speed, timescale: 6000)
        }
        p.pendingQuickUpgrade = nil
    }
}
