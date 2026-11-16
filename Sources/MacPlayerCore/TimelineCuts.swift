import Foundation

// MARK: Quick cuts on the main track, and what lies over it following along (0.19)

/// Keeps texts, picture/video layers, sounds, markers and subtitles in step with the main track when the main track gets shorter or longer.
/// The main track closes its own gaps (clips play one after the other); without this, everything over it stayed where it was and ended up
/// over other pictures.
public enum TimelineRipple {
    /// Shorter than this, an item is treated as gone from the removed part (and kept, at the cut, with its own length).
    static let minLength = MediaTime(value: 1, timescale: 30)

    /// The main track lost `span` (timeline time). Things after it move earlier by its length. A thing that runs across it gets shorter and
    /// keeps playing on (a song does not jump). A thing that starts inside it starts at the cut, with its first part (the one over the
    /// removed pictures) left out. A text, layer or sound wholly inside it moves to the cut with its own length: nothing the person made is
    /// thrown away. Subtitle lines wholly inside it are removed: they are the words of the pictures that went.
    public static func remove(_ span: TimeSpan, from p: inout Project) {
        let a = span.start, b = span.end
        guard b > a else { return }
        let len = b - a
        func map(_ t: MediaTime) -> MediaTime { t <= a ? t : (t >= b ? t - len : a) }
        /// New start and end, and how much of the item's beginning was cut off. Nil: unchanged.
        func place(_ s: MediaTime, _ e: MediaTime) -> (start: MediaTime, end: MediaTime, headCut: MediaTime)? {
            if e <= a { return nil }
            if s >= b { return (s - len, e - len, .zero) }
            let ns = map(s), ne = map(e)
            if ne - ns < minLength { return (a, a + (e - s), .zero) }             // wholly inside: kept, at the cut
            return (ns, ne, s >= a ? b - s : .zero)
        }

        for i in p.overlays.indices {
            let o = p.overlays[i]
            guard let n = place(o.start, o.end) else { continue }
            p.overlays[i].start = n.start; p.overlays[i].end = n.end
            if n.headCut > .zero, let ks = o.keyframes { p.overlays[i].keyframes = ks.map { var k = $0; k.time -= n.headCut.seconds; return k } }
        }
        for i in p.overlayClips.indices {
            let c = p.overlayClips[i]
            guard let n = place(c.start, c.end) else { continue }
            let newLength = n.end - n.start
            p.overlayClips[i].start = n.start; p.overlayClips[i].duration = newLength
            if case .video(let sid, let ss, _) = c.kind {
                let from = ss + n.headCut
                p.overlayClips[i].kind = .video(sourceID: sid, sourceStart: from, sourceEnd: from + newLength)
            }
            if n.headCut > .zero { p.overlayClips[i].keyframes = c.keyframes.map { var k = $0; k.time = k.time - n.headCut; return k } }
        }
        var sounds = p.soundClips
        for i in sounds.indices {
            let s = sounds[i]
            guard let n = place(s.start, s.end) else { continue }
            sounds[i].start = n.start; sounds[i].duration = n.end - n.start
            if n.headCut > .zero {
                sounds[i].sourceStart = s.sourceStart + n.headCut
                if let curve = s.volumeCurve { sounds[i].volumeCurve = VolumeCurve.shifted(curve, by: n.headCut.seconds) }
            }
        }
        p.soundClips = sounds
        for i in p.markers.indices { p.markers[i].time = map(p.markers[i].time) }
        p.subtitles.cues = p.subtitles.cues.compactMap { c in
            if c.end <= a { return c }
            var n = c; n.start = map(c.start); n.end = map(c.end)
            return n.end - n.start < minLength ? nil : n
        }
    }

    /// The main track gained `length` at `t` (a clip made longer): things that start at or after `t` move later by that much.
    public static func insert(at t: MediaTime, length: MediaTime, into p: inout Project) {
        guard length > .zero else { return }
        for i in p.overlays.indices where p.overlays[i].start >= t { p.overlays[i].start = p.overlays[i].start + length; p.overlays[i].end = p.overlays[i].end + length }
        for i in p.overlayClips.indices where p.overlayClips[i].start >= t { p.overlayClips[i].start = p.overlayClips[i].start + length }
        var sounds = p.soundClips
        for i in sounds.indices where sounds[i].start >= t { sounds[i].start = sounds[i].start + length }
        p.soundClips = sounds
        for i in p.markers.indices where p.markers[i].time >= t { p.markers[i].time = p.markers[i].time + length }
        for i in p.subtitles.cues.indices where p.subtitles.cues[i].start >= t { p.subtitles.cues[i].start = p.subtitles.cues[i].start + length; p.subtitles.cues[i].end = p.subtitles.cues[i].end + length }
    }

    /// After clip `id` was trimmed (its start or end in the source moved), moves what lies over the timeline by the change. `before` is the
    /// timeline as it was. The left edge changes the clip's beginning; the right edge its end.
    public static func followTrim(of id: UUID, leftEdge: Bool, before: [TimelineClip], in p: inout Project) {
        guard let old = before.first(where: { $0.id == id }), let new = p.timeline.first(where: { $0.id == id }),
              let start = TimelineEditor.starts(before)[id] else { return }
        let d = new.duration - old.duration
        if d == .zero { return }
        if d < .zero {
            let cut = .zero - d
            remove(leftEdge ? TimeSpan(start: start, end: start + cut) : TimeSpan(start: start + new.duration, end: start + old.duration), from: &p)
        } else {
            insert(at: leftEdge ? start : start + old.duration, length: d, into: &p)
        }
    }
}

public enum TimelineCuts {
    /// Which part of the clip under the playhead goes.
    public enum Side: Sendable { case beforePlayhead, afterPlayhead }

    /// Removes the part of clip `id` before or after `sourceTime` (a time in its source: the frame shown at the playhead). Returns the part of
    /// the timeline that went, or nil when the playhead is (within a frame) at the clip's edge — nothing to remove.
    @discardableResult
    public static func trim(_ p: inout Project, clip id: UUID, at sourceTime: MediaTime, removing side: Side, ripple: Bool) -> TimeSpan? {
        guard let c = p.timeline.first(where: { $0.id == id }), let start = TimelineEditor.starts(p.timeline)[id] else { return nil }
        let frame = MediaTime(value: 1, timescale: 30)
        guard sourceTime - c.sourceStart >= frame, c.sourceEnd - sourceTime >= frame else { return nil }
        let before = p.timeline
        switch side {
        case .beforePlayhead: TimelineEditor.trim(&p.timeline, clipID: id, start: sourceTime, sourceDuration: c.sourceEnd)
        case .afterPlayhead: TimelineEditor.trim(&p.timeline, clipID: id, end: sourceTime, sourceDuration: c.sourceEnd)
        }
        guard let n = p.timeline.first(where: { $0.id == id }), n.duration < c.duration else { return nil }
        let cut = c.duration - n.duration
        let span = side == .beforePlayhead ? TimeSpan(start: start, end: start + cut) : TimeSpan(start: start + n.duration, end: start + c.duration)
        if ripple { TimelineRipple.followTrim(of: id, leftEdge: side == .beforePlayhead, before: before, in: &p) }
        return span
    }

    /// Deletes clips; with `ripple`, what lies over each of them goes along with the timeline closing up (the latest first, so earlier
    /// places are not moved before they are used).
    public static func delete(_ p: inout Project, clips ids: Set<UUID>, ripple: Bool) {
        let starts = TimelineEditor.starts(p.timeline)
        let spans = p.timeline.filter { ids.contains($0.id) }.compactMap { c in starts[c.id].map { TimeSpan(start: $0, end: $0 + c.duration) } }
        TimelineEditor.rippleDelete(&p.timeline, ids: ids)
        guard ripple else { return }
        for s in spans.sorted(by: { $0.start > $1.start }) { TimelineRipple.remove(s, from: &p) }
    }

    /// The clips from the one already chosen to `id`, in timeline order (⇧-click).
    public static func range(in clips: [TimelineClip], from anchor: UUID, to id: UUID) -> [UUID] {
        guard let a = clips.firstIndex(where: { $0.id == anchor }), let b = clips.firstIndex(where: { $0.id == id }) else { return [id] }
        return clips[min(a, b)...max(a, b)].map(\.id)
    }
}
