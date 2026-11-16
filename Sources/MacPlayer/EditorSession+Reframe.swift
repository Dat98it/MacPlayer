import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Turning a video to another shape with the frame following the people in it (0.21): the finished frame gets the new shape, every
/// clip fills it, and each clip whose picture is wider (or taller) than the frame gets a path that keeps the people in view.
extension EditorSession {
    /// The shape of a clip's picture after its crop and turn (width / height), or nil when it is not known yet.
    func editedAspect(_ c: TimelineClip) -> Double? {
        guard let v = infos[c.sourceID]?.primaryVideo, v.width > 0, v.height > 0 else { return nil }
        var w = Double(v.width) * c.look.crop.width, h = Double(v.height) * c.look.crop.height
        if c.look.rotation % 180 != 0 { swap(&w, &h) }
        return w / h
    }

    /// `shape`: the new frame. `only`: these clips (nil: every clip). Runs in the background with progress; one undo step at the end.
    func autoReframe(to shape: CanvasPreset, only: Set<UUID>? = nil) {
        guard isProject, !project.timeline.isEmpty, let target = shape.aspect else { return }
        guard reframeProgress == nil else { return }
        let clips = project.timeline.filter { only?.contains($0.id) ?? true }
        reframeProgress = 0
        flash(L("Looking for people in the clips…"))
        reframeTask = Task {
            var paths: [UUID: [ReframeKey]] = [:]
            var followed = 0
            for (n, c) in clips.enumerated() {
                defer { reframeProgress = Double(n + 1) / Double(max(1, clips.count)) }
                guard let url = sourceURLs[c.sourceID], !StillClip.isMade(url), let a = editedAspect(c) else { continue }
                // A picture already of the frame's shape fills it as it is: nothing to follow.
                guard abs(a - target) / target > 0.04 else { continue }
                do {
                    let base = Double(n) / Double(clips.count), share = 1 / Double(clips.count)
                    let samples = try await PersonTracker.track(url: url, span: c.sourceSpan, progress: { p in
                        Task { @MainActor [weak self] in self?.reframeProgress = base + p * share }
                    })
                    let placed = samples.map { s in PersonSample(time: s.time, center: s.center.flatMap { Reframe.edited($0, crop: c.look.crop, rotation: c.look.rotation) }) }
                    let keys = Reframe.path(placed)
                    if !keys.isEmpty { paths[c.id] = keys; followed += 1 }
                } catch is CancellationError {
                    reframeProgress = nil; flash(L("Stopped.")); return
                } catch { continue }
            }
            let only = only
            edit("Follow people") { p in
                p.setFrame(shape, fill: .fill)
                for i in p.timeline.indices where only?.contains(p.timeline[i].id) ?? true { p.timeline[i].look.reframe = paths[p.timeline[i].id] }
            }
            reframeProgress = nil
            flash(followed == 0 ? L("The frame now has the new shape. No clip needed following: their pictures already have that shape.")
                                : LF("The frame follows the people in %d clips.", followed))
        }
    }

    func cancelReframe() { reframeTask?.cancel() }

    /// Back to a centred frame (the shape stays).
    func clearReframe(only: Set<UUID>? = nil) {
        edit("Stop following") { p in for i in p.timeline.indices where only?.contains(p.timeline[i].id) ?? true { p.timeline[i].look.reframe = nil } }
    }

    var hasReframe: Bool { project.timeline.contains { $0.look.reframe != nil } }
}
