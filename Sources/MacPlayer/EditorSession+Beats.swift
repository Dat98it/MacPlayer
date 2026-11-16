import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Cutting to the beat of a song (0.20): find its beats, show them on the timeline, put the cuts on them.
extension EditorSession {
    /// Beats already found, by file (the same song used twice is listened to once).
    @MainActor private static var beatCache: [String: BeatGrid] = [:]

    /// The song whose beats the tools use: the selected sound when it has beats or is music, else the first music with beats.
    var beatSound: SoundClip? {
        if let s = selectedSound, s.beats != nil || s.kind == .music { return s }
        return project.soundClips.first { $0.beats != nil } ?? project.soundClips.first { $0.kind == .music }
    }

    func findBeats(_ id: UUID) {
        guard let c = resolvedSounds().first(where: { $0.id == id }), !beatsWorking.contains(id) else { return }
        if isMissing(c) { flash(L("The sound file is missing."), error: true); return }
        if let g = Self.beatCache[c.path] { setBeats(g, for: id); return }
        beatsWorking.insert(id)
        flash(L("Listening for the beat…"))
        Task {
            defer { beatsWorking.remove(id) }
            do {
                let g = try await BeatDetector.detect(url: URL(fileURLWithPath: c.path))
                Self.beatCache[c.path] = g
                setBeats(g, for: id)
            } catch {
                flash(ErrorText.localized((error as? CustomStringConvertible)?.description ?? error.localizedDescription), error: true)
            }
        }
    }

    private func setBeats(_ g: BeatGrid, for id: UUID) {
        // Beats change nothing that is seen or heard: the preview is not rebuilt.
        edit("Find beats", refreshPreview: false) { p in var all = p.soundClips; if let i = all.firstIndex(where: { $0.id == id }) { all[i].beats = g }; p.soundClips = all }
        let n = project.soundClips.first { $0.id == id }?.timelineBeats.count ?? 0
        flash(LF("%@ beats a minute: %d beats in this sound.", String(format: "%.0f", g.bpm), n))
    }

    func clearBeats(_ id: UUID) {
        edit("Remove beats", refreshPreview: false) { p in var all = p.soundClips; if let i = all.firstIndex(where: { $0.id == id }) { all[i].beats = nil }; p.soundClips = all }
    }

    /// Moves every cut of the main track (or only those of the selected clips) onto the beats.
    func fitClipsToBeats() {
        guard let song = beatSound, song.beats != nil else { flash(L("Find the beats of a song first."), error: true); return }
        let beats = BeatSync.timelineBeats(project, sound: song.id, every: beatEvery)
        let only: Set<UUID>? = selectedClipIDs.count > 1 ? selectedClipIDs : nil
        let follow = timelineFollows
        let limits = infos
        var p = project
        let n = BeatSync.fitClips(&p, beats: beats, sourceLimit: { limits[$0.sourceID]?.duration }, ripple: follow, keep: song.id, clips: only)
        guard n > 0 else { flash(L("The cuts are already on the beat.")); return }
        edit("Cut to the beat") { $0 = p }
        flash(LF("%d cuts moved onto the beat.", n))
    }

    func addBeatMarkers() {
        guard let song = beatSound, song.beats != nil else { flash(L("Find the beats of a song first."), error: true); return }
        let beats = BeatSync.timelineBeats(project, sound: song.id, every: beatEvery)
        var p = project
        let n = BeatSync.addMarkers(&p, beats: beats, end: duration)
        guard n > 0 else { flash(L("There are markers on these beats already.")); return }
        edit("Beat markers") { $0 = p }
        flash(LF("%d markers added. [ and ] jump between them.", n))
    }
}
