import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Time tools on the selected timeline clip: speed ramps, freeze frames, reversing. They change the timeline itself (cut the clip into
/// parts, add a held frame, swap in a reversed copy), so what the timeline shows is exactly what plays and exports.
extension EditorSession {
    /// The clip the tools act on: the selected one, or the only one.
    var timingClip: TimelineClip? {
        if let id = project.activeClipID, let c = project.timeline.first(where: { $0.id == id }) { return c }
        return project.timeline.count == 1 ? project.timeline.first : nil
    }

    func applySpeedRamp(_ preset: SpeedRamp.Preset, name: String) {
        guard isProject, let c = timingClip else { flash(L("Select a clip on the timeline first."), error: true); return }
        var ids: [UUID]?
        edit(LF("Speed ramp: %@", name)) { ids = TimelineEditor.applySpeedRamp(&$0.timeline, clipID: c.id, preset: preset) }
        if let ids { selectedClipIDs = Set(ids.prefix(1)); flash(LF("The clip was cut into %d parts with changing speed.", ids.count)) }
        else { flash(L("This clip is too short for a speed ramp."), error: true) }
    }

    func freezeFrameAtPlayhead(hold: Double) {
        guard isProject, let loc = TimelineMap.locate(project.timeline, at: player.currentTime) else { flash(L("Select a clip on the timeline first."), error: true); return }
        Task {
            var t = loc.sourceTime
            if let url = sourceURLs[project.timeline[loc.index].sourceID], let f = try? await FrameLocator.frame(url: url, at: t + MediaTime(value: 1, timescale: 6000)) { t = f.time }
            var made: UUID?
            edit("Freeze frame") { made = TimelineEditor.freezeFrame(&$0.timeline, clipID: loc.clipID, atSourceTime: t, frameDuration: frameRate.frameDuration, hold: hold) }
            if let made { selectedClipIDs = [made]; flash(LF("The frame is held for %.1f s.", hold)) }
            else { flash(L("Move the playhead inside a clip to freeze a frame."), error: true) }
        }
    }

    /// Makes a reversed copy of the clip (kept in the app's own folder) and puts it in the clip's place. The original video is not touched.
    func reverseClip() {
        guard isProject, let c = timingClip, let url = sourceURLs[c.sourceID] else { flash(L("Select a clip on the timeline first."), error: true); return }
        guard (c.sourceEnd - c.sourceStart).seconds <= ReverseRenderer.maxSeconds else {
            flash(LF("A clip longer than %d seconds is too long to reverse. Split it first.", Int(ReverseRenderer.maxSeconds)), error: true); return
        }
        let folder = env.support.appendingPathComponent("Reversed", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("\(UUID().uuidString.prefix(8)).mov")
        flash(L("Reversing the clip…"))
        let span = c.sourceSpan, env = self.env
        Task {
            do {
                try await ReverseRenderer.reverse(source: url, span: span, to: out)
                let info = try await MediaProbe.probe(url: out)
                let ref = SourceRef(path: out.path, bookmark: Bookmarks.make(out), fingerprint: try? env.fs.fingerprint(out.path), info: info)
                edit("Reverse clip") { p in
                    let sid = p.addSource(ref)
                    guard let i = p.timeline.firstIndex(where: { $0.id == c.id }) else { return }
                    p.timeline[i].sourceID = sid; p.timeline[i].sourceStart = .zero; p.timeline[i].sourceEnd = info.duration
                    p.timeline[i].look.motion = []
                    p.timeline[i].name = (c.name.isEmpty ? PathUtil.stem(of: url.path) : c.name) + " ⟲"
                }
                await resolveSources()
                schedulePreviewRefresh()
                flash(L("The clip now plays backwards."))
            } catch {
                try? FileManager.default.removeItem(at: out)
                flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true)
            }
        }
    }
}

extension EditorSession {
    /// The file the Picture tools are working on: the selected clip's video in a project, the open video otherwise.
    var activeSourceURL: URL? {
        if isProject, let c = timingClip { return sourceURLs[c.sourceID] }
        return sourceURL
    }
}
