import AVFoundation
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Copying a look to other clips or texts, and cutting out silences (0.21).
extension EditorSession {
    // MARK: Copy and paste a style

    /// What was copied last, shared by every window (a style can go from one project to another).
    @MainActor static var copiedClipStyle: ClipStyle?
    @MainActor static var copiedTextStyle: TextStyle?

    /// The text or shape the style is copied from: the one selected on the picture or the timeline.
    var styleText: TextOverlay? {
        let id = selectedTextID ?? (canvasSelection.count == 1 ? canvasSelection.first : nil)
        return project.overlays.first { $0.id == id }
    }

    /// ⌥⇧⌘C: the selected text's style, else the clip being edited.
    func copyStyle() {
        if let o = styleText {
            Self.copiedTextStyle = TextStyle(o)
            flash(o.isShape ? L("Shape style copied. Select other shapes and paste it (⌥⇧⌘V).") : L("Text style copied. Select other texts and paste it (⌥⇧⌘V)."))
        } else if let c = project.timeline.first(where: { $0.id == project.activeClipID }) ?? project.timeline.first {
            Self.copiedClipStyle = ClipStyle(c.look)
            pasteParts = Self.copiedClipStyle!.changedParts.isEmpty ? Set(ClipStyle.Part.allCases) : Self.copiedClipStyle!.changedParts
            flash(LF("The style of “%@” was copied. Select clips and paste it (⌥⇧⌘V).", c.name.isEmpty ? L("Clip") : c.name))
        } else { flash(L("Select a clip or a text to copy its style.")) }
        objectWillChange.send()
    }

    /// The clips a pasted style goes to: those selected (several with ⌘/⇧-click), else the one being edited.
    var pasteTargets: Set<UUID> {
        if selectedClipIDs.count > 1 { return selectedClipIDs }
        return project.activeClipID.map { [$0] } ?? []
    }

    /// ⌥⇧⌘V: on the selected texts when a text style was copied and texts are selected; otherwise the clip style on the selected clips.
    func pasteStyle(toAll: Bool = false) {
        let texts = Set(project.overlays.map(\.id)).intersection(canvasSelection.union(selectedTextID.map { [$0] } ?? []))
        if let t = Self.copiedTextStyle, toAll || !texts.isEmpty || Self.copiedClipStyle == nil {
            let ids = toAll ? Set(project.overlays.filter { ($0.shape == nil) == (t.source.shape == nil) }.map(\.id)) : texts
            guard !ids.isEmpty else { flash(L("Select the texts to paste the style on.")); return }
            var p = project
            let n = t.paste(to: ids, in: &p)
            guard n > 0 else { flash(L("They already have this style.")); return }
            edit("Paste style") { $0 = p }
            flash(LF("Style pasted on %d texts.", n))
            return
        }
        guard let s = Self.copiedClipStyle else { flash(L("Copy a style first (⌥⇧⌘C).")); return }
        let ids = toAll ? Set(project.timeline.map(\.id)) : pasteTargets
        guard !ids.isEmpty, !pasteParts.isEmpty else { flash(L("Choose what to paste and the clips to paste it on.")); return }
        var p = project
        let n = s.paste(pasteParts, to: ids, in: &p, ripple: timelineFollows)
        guard n > 0 else { flash(L("They already have this style.")); return }
        edit("Paste style") { $0 = p }
        flash(LF("Style pasted on %d clips.", n))
    }

    var canPasteStyle: Bool { Self.copiedClipStyle != nil || Self.copiedTextStyle != nil }

    // MARK: Silences

    /// Measures every clip's sound (or only `only`) and lists its quiet stretches to look over before cutting.
    func findSilences(minLength: Double, sensitivity: Double, only: Set<UUID>? = nil) {
        guard isProject, silenceProgress == nil else { return }
        let clips = project.timeline.filter { only?.contains($0.id) ?? true }
        let starts = TimelineEditor.starts(project.timeline)
        silenceProgress = 0
        silences = []
        Task {
            var all: [SilenceFound] = []
            for (n, c) in clips.enumerated() {
                defer { silenceProgress = Double(n + 1) / Double(max(1, clips.count)) }
                guard let url = sourceURLs[c.sourceID], infos[c.sourceID]?.hasAudio == true, let start = starts[c.id] else { continue }
                let asset = AVURLAsset(url: url)
                let frame = 0.05
                guard let r = try? await AudioAnalysis.rms(asset: asset, range: CMTimeRange(start: c.sourceStart.cmTime, duration: (c.sourceEnd - c.sourceStart).cmTime), frameSeconds: frame) else { continue }
                all += SilenceFinder.found(in: c, clipStart: start, rms: r.frames, frameSeconds: frame, minLength: minLength, sensitivity: sensitivity)
            }
            silences = all
            silenceProgress = nil
            let total = all.reduce(0) { $0 + ($1.timeline.end - $1.timeline.start).seconds }
            flash(all.isEmpty ? L("No silences were found.") : LF("%d silences found, %@ in all. Check them, then cut.", all.count, Format.duration(MediaTime(seconds: total))))
        }
    }

    func cutSilences() {
        let chosen = silences.filter(\.chosen)
        guard !chosen.isEmpty else { return }
        var p = project
        let n = TimelineCuts.removeSilences(&p, chosen, ripple: timelineFollows)
        edit("Cut silences") { $0 = p }
        silences = []
        flash(LF("%d silences cut. Undo puts them back.", n))
    }

    /// Plays a stretch from a little before it, to hear what would go.
    func previewSilence(_ s: SilenceFound) {
        Task {
            await player.seek(to: max(.zero, s.timeline.start - MediaTime(seconds: 0.8)))
            player.play()
        }
    }
}
