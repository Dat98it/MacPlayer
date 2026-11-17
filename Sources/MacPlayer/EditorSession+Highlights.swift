import AVFoundation
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Cutting a highlight from a sports video (0.22): every clip (or the selected ones) is looked at on this Mac; the parts of the match
/// and the best action are chosen with the length worked out from the video itself (0.22.3: nothing to set), shown in a short list
/// with a few suggestions more; the person looks them over, then keeps only those in one undo step.
extension EditorSession {
    /// The one choice left to the person (0.22.3): goals and replayed moments go on with the broadcast's own replay after them.
    struct HighlightSettings: Equatable {
        var withReplays = true
    }

    func findHighlights(_ settings: HighlightSettings, only: Set<UUID>? = nil) {
        guard isProject, highlightProgress == nil, !project.timeline.isEmpty else { return }
        let clips = project.timeline.filter { only?.contains($0.id) ?? true }
        highlightProgress = 0
        highlights = []
        flash(L("Looking for the highlight…"))
        highlightTask = Task {
            var measured: [UUID: HighlightSignals] = [:]
            for (n, c) in clips.enumerated() {
                defer { highlightProgress = Double(n + 1) / Double(max(1, clips.count)) }
                guard let url = sourceURLs[c.sourceID], !StillClip.isMade(url), infos[c.sourceID]?.primaryVideo != nil else { continue }
                let base = Double(n) / Double(clips.count), share = 1 / Double(clips.count)
                do {
                    measured[c.id] = try await HighlightAnalyzer.signals(url: url, span: c.sourceSpan, progress: { p in
                        Task { @MainActor [weak self] in self?.highlightProgress = base + p * share }
                    })
                } catch is CancellationError {
                    highlightProgress = nil; highlightTask = nil; flash(L("Stopped.")); return
                } catch { continue }
            }
            highlightSignals = measured
            highlightClips = Set(measured.keys)
            highlightProgress = nil
            highlightTask = nil
            rebuildHighlights(settings)
            let chosen = highlights.filter(\.chosen)
            let total = Format.duration(MediaTime(seconds: chosen.reduce(0) { $0 + $1.length }))
            flash(chosen.isEmpty ? L("No moment stood out. Try clips with more action.")
                  : LF("Highlight ready: %d moments, %@. Look it over, then make it.", chosen.count, total))
        }
    }

    func cancelHighlights() { highlightTask?.cancel() }

    /// The list from what was measured (again after the replay choice changes): chosen by itself, then shortened to the chosen
    /// moments and a few suggestions. What was checked by hand is lost, as the moments themselves may change.
    func rebuildHighlights(_ settings: HighlightSettings) {
        let starts = TimelineEditor.starts(project.timeline)
        var all: [HighlightFound] = []
        var seconds = 0.0
        for c in project.timeline {
            guard let sig = highlightSignals[c.id], let start = starts[c.id] else { continue }
            all += HighlightFinder.found(in: c, clipStart: start, signals: sig, withReplays: settings.withReplays)
            seconds += c.duration.seconds
        }
        all = HighlightFinder.normalize(all)
        HighlightFinder.autoChoose(&all, seconds: seconds)
        highlights = HighlightFinder.shortlist(all)
    }

    /// Keeps only the checked moments (one undo step); with `toBeat`, the cuts then go onto the beats of the song whose beats were found.
    func makeHighlight(toBeat: Bool) {
        let chosen = highlights.filter(\.chosen)
        guard !chosen.isEmpty else { return }
        var p = project
        // What was measured, by source (the clips are split by the cut and get new ids).
        var measured: [UUID: [HighlightSignals]] = [:]
        for c in p.timeline { if let sig = highlightSignals[c.id] { measured[c.sourceID, default: []].append(sig) } }
        let n = TimelineCuts.keepHighlights(&p, chosen, clips: highlightClips, ripple: timelineFollows)
        // Each moment's sound evened out to one level (a match jumps from a booming loudspeaker to a quiet field, and loud parts crackle
        // when written again), with a short fade at each join so the cuts do not click.
        for i in p.timeline.indices {
            let c = p.timeline[i]
            guard let sigs = measured[c.sourceID], let sig = sigs.first(where: { $0.start <= c.sourceStart.seconds + 0.01 && $0.time($0.count - 1) >= c.sourceEnd.seconds - 1 }) else { continue }
            if let g = HighlightFinder.evenGain(sig, from: c.sourceStart.seconds, to: c.sourceEnd.seconds) { p.timeline[i].audio.gainDB = (g * 10).rounded() / 10 }
            p.timeline[i].audio.fadeIn = max(p.timeline[i].audio.fadeIn, 0.12)
            p.timeline[i].audio.fadeOut = max(p.timeline[i].audio.fadeOut, 0.12)
        }
        var onBeat = 0
        if toBeat, let song = beatSound, song.beats != nil {
            let beats = BeatSync.timelineBeats(p, sound: song.id, every: beatEvery)
            let limits = infos
            onBeat = BeatSync.fitClips(&p, beats: beats, sourceLimit: { limits[$0.sourceID]?.duration }, ripple: timelineFollows, keep: song.id, clips: nil)
        }
        edit("Make highlight") { $0 = p }
        highlights = []
        highlightSignals = [:]
        let length = Format.duration(MediaTime(seconds: p.timeline.reduce(0) { $0 + $1.duration.seconds }))
        flash(onBeat > 0 ? LF("Highlight made: %d moments, %@, cut to the beat. Undo brings the whole video back.", n, length)
                         : LF("Highlight made: %d moments, %@. Undo brings the whole video back.", n, length))
        Task { await player.seek(to: .zero) }
    }

    /// Puts a marker at the start of each checked moment instead of cutting (to cut by hand).
    func markHighlights() {
        let chosen = highlights.filter(\.chosen)
        guard !chosen.isEmpty else { return }
        edit("Mark highlights") { p in
            for (i, h) in chosen.enumerated() where !p.markers.contains(where: { abs(($0.time - h.timeline.start).seconds) < 0.05 }) {
                p.markers.append(Marker(time: h.timeline.start, name: LF("Moment %d", i + 1), color: .green))
            }
            p.markers.sort { $0.time < $1.time }
        }
        flash(LF("%d markers added. [ and ] jump between them.", chosen.count))
    }

    func previewHighlight(_ h: HighlightFound) {
        Task {
            await player.seek(to: h.timeline.start)
            player.play()
        }
    }
}
