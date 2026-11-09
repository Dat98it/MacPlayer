import Foundation

/// A point in a zoom and move animation of the main picture: how big it is and which part of it is in the middle of the frame.
public struct MotionKeyframe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Seconds from the start of the clip, on the timeline.
    public var time: Double
    /// 1 = the picture as placed, 2 = twice as big.
    public var scale: Double
    /// The part of the picture that is in the middle of the frame, 0...1 across (0.5 = the middle).
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), time: Double, scale: Double = 1, x: Double = 0.5, y: Double = 0.5) {
        self.id = id; self.time = time; self.scale = scale; self.x = x; self.y = y
    }
}

public struct MotionState: Equatable, Sendable {
    public var scale: Double, x: Double, y: Double
    public init(scale: Double, x: Double, y: Double) { self.scale = scale; self.x = x; self.y = y }
    public static let still = MotionState(scale: 1, x: 0.5, y: 0.5)

    /// Keeps the view inside the picture: at 2x only half of it is visible, so its middle can only be between 0.25 and 0.75.
    public func clamped() -> MotionState {
        let s = min(max(scale, 1), 8), half = 0.5 / s
        return MotionState(scale: s, x: min(max(x, half), 1 - half), y: min(max(y, half), 1 - half))
    }
}

public enum Motion {
    /// The state at `t` (seconds from the clip's start). Before the first keyframe and after the last it holds; between two it
    /// changes in a straight line, like a layer's keyframes, so a clip cut part way through keeps exactly the motion it had. No keyframes: nil.
    public static func state(_ keyframes: [MotionKeyframe], at t: Double) -> MotionState? {
        let k = keyframes.sorted { $0.time < $1.time }
        guard let first = k.first, let last = k.last else { return nil }
        func s(_ f: MotionKeyframe) -> MotionState { MotionState(scale: f.scale, x: f.x, y: f.y) }
        if t <= first.time { return s(first).clamped() }
        if t >= last.time { return s(last).clamped() }
        guard let i = k.indices.dropLast().first(where: { t < k[$0 + 1].time }) else { return s(last).clamped() }
        let a = k[i], b = k[i + 1]
        let span = b.time - a.time
        let u = span > 0 ? (t - a.time) / span : 1
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        return MotionState(scale: mix(a.scale, b.scale), x: mix(a.x, b.x), y: mix(a.y, b.y)).clamped()
    }

    public enum Preset: String, CaseIterable, Sendable { case zoomIn, zoomOut, panRight, panLeft, zoomInPan, punchIn }

    /// A ready-made animation over a clip of `duration` seconds.
    public static func keyframes(for preset: Preset, duration: Double) -> [MotionKeyframe] {
        let d = max(0.1, duration)
        switch preset {
        case .zoomIn: return [MotionKeyframe(time: 0, scale: 1), MotionKeyframe(time: d, scale: 1.35)]
        case .zoomOut: return [MotionKeyframe(time: 0, scale: 1.35), MotionKeyframe(time: d, scale: 1)]
        case .panRight: return [MotionKeyframe(time: 0, scale: 1.3, x: 0.0), MotionKeyframe(time: d, scale: 1.3, x: 1.0)]
        case .panLeft: return [MotionKeyframe(time: 0, scale: 1.3, x: 1.0), MotionKeyframe(time: d, scale: 1.3, x: 0.0)]
        case .zoomInPan: return [MotionKeyframe(time: 0, scale: 1, x: 0.5), MotionKeyframe(time: d, scale: 1.5, x: 0.7, y: 0.45)]
        case .punchIn: return [MotionKeyframe(time: 0, scale: 1), MotionKeyframe(time: min(0.25, d / 2), scale: 1.25), MotionKeyframe(time: d, scale: 1.25)]
        }
    }

    /// Moves every keyframe by `delta` seconds. Keyframes that land before the start are dropped; the animation's value at the new
    /// start is kept as a keyframe at 0, so what the picture does from there on is unchanged.
    public static func shifted(_ keyframes: [MotionKeyframe], by delta: Double) -> [MotionKeyframe] {
        guard !keyframes.isEmpty else { return [] }
        var out = keyframes.map { var k = $0; k.time += delta; return k }.filter { $0.time > 1e-9 }
        if keyframes.contains(where: { $0.time + delta <= 1e-9 }), let start = state(keyframes, at: -delta) {
            out.insert(MotionKeyframe(time: 0, scale: start.scale, x: start.x, y: start.y), at: 0)
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Adds a keyframe at `t`, or updates the one already within a frame of it.
    public static func setting(_ keyframes: [MotionKeyframe], at t: Double, to state: MotionState) -> [MotionKeyframe] {
        var k = keyframes
        let c = state.clamped()
        if let i = k.firstIndex(where: { abs($0.time - t) < 0.02 }) { k[i].scale = c.scale; k[i].x = c.x; k[i].y = c.y }
        else { k.append(MotionKeyframe(time: max(0, t), scale: c.scale, x: c.x, y: c.y)) }
        return k.sorted { $0.time < $1.time }
    }
}
