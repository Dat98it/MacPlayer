import Foundation

/// The part of the timeline the strip shows: from `start`, `length` seconds wide. Pure, so its rules are tested.
///
/// A project starts empty and grows as videos are added; the strip must follow: when it was showing everything (or nothing yet),
/// it shows everything again. Before 0.8.1 it kept the width it had when the project was empty (almost nothing), so the strip
/// showed a few frames, scrolled on every frame while playing and looked as if it flickered and stood still.
public struct TimelineViewport: Equatable, Sendable {
    /// The narrowest view, in seconds (also what an empty timeline shows).
    public static let minimumLength = 0.5

    public private(set) var start: Double = 0
    public private(set) var length: Double = 10
    /// The length of the timeline the last time the view was fitted or followed.
    public private(set) var total: Double = 0

    public init() {}

    /// Shows the whole timeline.
    public mutating func fitAll(total t: Double) {
        total = max(0, t)
        start = 0
        length = max(Self.minimumLength, total)
    }

    /// The timeline's length changed (videos added, clips removed or trimmed). A view that showed everything keeps showing
    /// everything; a view zoomed in on a part stays where it was, kept inside the new length.
    public mutating func totalChanged(to t: Double) {
        let new = max(0, t)
        guard abs(new - total) > 0.0005 else { return }
        let showedAll = total < 0.01 || (start <= 0.0005 && length >= total - 0.0005)
        if showedAll { fitAll(total: new); return }
        total = new
        length = min(max(Self.minimumLength, length), max(Self.minimumLength, total))
        start = min(max(0, start), max(0, total - length))
    }

    /// Zooms by `factor` around the time `anchor` (which stays under the same point of the strip, at `fraction` of its width).
    public mutating func zoom(by factor: Double, anchor: Double, fraction: Double) {
        length = min(max(Self.minimumLength, total), max(Self.minimumLength, length * factor))
        start = min(max(0, anchor - fraction * length), max(0, total - length))
    }

    /// Moves the view by `seconds` (scrolling), kept inside the timeline.
    public mutating func scroll(by seconds: Double) {
        start = min(max(0, start + seconds), max(0, total - length))
    }

    /// While playing: when the playhead leaves the view, the view jumps so the playhead is near its left edge again.
    public mutating func follow(playhead t: Double) {
        if t > start + length * 0.95 || t < start { start = min(max(0, t - length * 0.1), max(0, total - length)) }
    }
}
