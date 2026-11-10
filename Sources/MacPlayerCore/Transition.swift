import Foundation

public enum TransitionKind: String, Codable, CaseIterable, Sendable {
    case dissolve, dipBlack, dipWhite, slideLeft, slideRight, slideUp, slideDown, wipeRight, zoomIn
    case wipeLeft, wipeUp, wipeDown, circleOpen, blur, spin, flash, pixelate
}

/// How a clip arrives: a transition from the clip before it, centred on the cut between them. It needs a little footage on both sides
/// of the cut, so it is shortened when a clip has none to spare at that edge.
public struct ClipTransition: Codable, Equatable, Sendable {
    public var kind: TransitionKind
    /// Seconds, across the cut.
    public var duration: Double
    public init(kind: TransitionKind = .dissolve, duration: Double = 0.8) { self.kind = kind; self.duration = duration }

    public static let shortest = 0.2, longest = 3.0
    public var clampedDuration: Double { min(max(duration, Self.shortest), Self.longest) }
}

extension ClipTransition {
    /// How long the transition into `cur` really lasts, given the footage the two clips have to spare around the cut (seconds on the
    /// timeline): the outgoing clip needs some after its end, the incoming one some before its start, and neither can give up more
    /// than 45% of its length. 0 means there is not enough for a transition at all.
    public func effectiveDuration(prev: TimelineClip, prevSourceDuration: Double, cur: TimelineClip) -> Double {
        let sp = max(VideoLook.minimumSpeed, prev.look.speed), sc = max(VideoLook.minimumSpeed, cur.look.speed)
        let spareAfter = max(0, prevSourceDuration - prev.sourceEnd.seconds) / sp
        let spareBefore = max(0, cur.sourceStart.seconds) / sc
        let half = min(clampedDuration / 2, spareAfter, spareBefore, 0.45 * prev.duration.seconds, 0.45 * cur.duration.seconds)
        return half >= 0.08 ? half * 2 : 0
    }
}
