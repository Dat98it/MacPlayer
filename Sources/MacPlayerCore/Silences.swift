import Foundation

// MARK: Cutting out the silences (0.21)

/// A quiet stretch found in a clip: where it is in the source and on the timeline, and whether it is to be cut.
public struct SilenceFound: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var clipID: UUID
    public var source: TimeSpan
    public var timeline: TimeSpan
    public var chosen = true
    public init(clipID: UUID, source: TimeSpan, timeline: TimeSpan) { self.clipID = clipID; self.source = source; self.timeline = timeline }
}

public enum SilenceFinder {
    /// Quiet stretches in the loudness of consecutive frames of `frameSeconds` (seconds from the first frame). Quiet is measured against
    /// the sound itself: below `sensitivity` of the way from its quiet floor to its loud level (in dB), so a soft voice and a loud one
    /// work the same. Only stretches of at least `minLength` count, and `pad` is kept at each side so words are not clipped.
    public static func silences(rms: [Float], frameSeconds: Double, minLength: Double = 0.7, pad: Double = 0.15, sensitivity: Double = 0.25) -> [(start: Double, end: Double)] {
        guard rms.count > 4 else { return [] }
        let db = rms.map { 20 * log10(max(Double($0), 1e-6)) }
        let sorted = db.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let floor = pct(0.1), loud = pct(0.95)
        // A sound that is about as loud everywhere (music, steady noise) has no silences to find.
        guard loud - floor > 12 else { return [] }
        let threshold = floor + (loud - floor) * min(max(sensitivity, 0.05), 0.6)
        var out: [(Double, Double)] = []
        var i = 0
        while i < db.count {
            guard db[i] < threshold else { i += 1; continue }
            var j = i
            while j < db.count && db[j] < threshold { j += 1 }
            let a = Double(i) * frameSeconds, b = Double(j) * frameSeconds
            if b - a >= minLength {
                // At the very start or end of the sound there is nothing to keep a gap from.
                let s = i == 0 ? a : a + pad, e = j == db.count ? b : b - pad
                if e - s >= 0.2 { out.append((s, e)) }
            }
            i = j
        }
        return out
    }

    /// The silences of clip `c` (from its loudness over its source span) as found items, placed on the timeline at `clipStart`.
    public static func found(in c: TimelineClip, clipStart: MediaTime, rms: [Float], frameSeconds: Double, minLength: Double, sensitivity: Double) -> [SilenceFound] {
        let k = max(VideoLook.minimumSpeed, c.look.speed)
        return silences(rms: rms, frameSeconds: frameSeconds, minLength: minLength, sensitivity: sensitivity).compactMap { s in
            let a = c.sourceStart + MediaTime(seconds: s.start, timescale: 6000), b = min(c.sourceEnd, c.sourceStart + MediaTime(seconds: s.end, timescale: 6000))
            guard b > a else { return nil }
            let ta = clipStart + MediaTime(seconds: (a - c.sourceStart).seconds / k, timescale: 6000), tb = clipStart + MediaTime(seconds: (b - c.sourceStart).seconds / k, timescale: 6000)
            return SilenceFound(clipID: c.id, source: TimeSpan(start: a, end: b), timeline: TimeSpan(start: ta, end: tb))
        }
    }
}

extension TimelineCuts {
    /// Cuts the chosen silences out of their clips (each clip is split around it and the quiet piece removed); later ones first, so the
    /// places of earlier ones stay right. With `ripple`, what lies over the timeline follows. Returns how many were cut.
    @discardableResult
    public static func removeSilences(_ p: inout Project, _ found: [SilenceFound], ripple: Bool) -> Int {
        var cut = 0
        for s in found.filter(\.chosen).sorted(by: { $0.timeline.start > $1.timeline.start }) {
            guard let c = p.timeline.first(where: { $0.id == s.clipID }), s.source.start < c.sourceEnd, s.source.end > c.sourceStart else { continue }
            let a = max(s.source.start, c.sourceStart), b = min(s.source.end, c.sourceEnd)
            var piece = c.id
            if a > c.sourceStart {
                guard TimelineEditor.split(&p.timeline, clipID: c.id, atSourceTime: a), let i = p.timeline.firstIndex(where: { $0.id == c.id }) else { continue }
                piece = p.timeline[i + 1].id
            }
            if b < c.sourceEnd, TimelineEditor.split(&p.timeline, clipID: piece, atSourceTime: b), let i = p.timeline.firstIndex(where: { $0.id == piece }) {
                p.timeline[i + 1].name = c.name          // what stays keeps the clip's own name, not "… 2 2"
            }
            delete(&p, clips: [piece], ripple: ripple)
            cut += 1
        }
        return cut
    }
}
