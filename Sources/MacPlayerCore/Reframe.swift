import Foundation

// MARK: The frame following people (0.21)

/// Where the middle of the frame is on the picture at one moment of the source: `x`, `y` are 0…1 of the edited picture (after crop and
/// turn), from the top-left. Times are seconds of the source, so cutting, splitting or changing the speed of the clip keeps them right.
public struct ReframeKey: Codable, Equatable, Sendable {
    public var time: Double
    public var x: Double
    public var y: Double
    public init(time: Double, x: Double, y: Double) { self.time = time; self.x = x; self.y = y }
}

/// One look at a frame: where the people are (their area-weighted middle), or nil when nobody was found.
public struct PersonSample: Equatable, Sendable {
    public var time: Double
    public var center: (x: Double, y: Double)?
    public init(time: Double, center: (x: Double, y: Double)?) { self.time = time; self.center = center }
    public static func == (a: PersonSample, b: PersonSample) -> Bool { a.time == b.time && a.center?.x == b.center?.x && a.center?.y == b.center?.y }
}

public enum Reframe {
    /// The middle of the frame at source time `t` (between keys it moves in a straight line; before the first and after the last it holds).
    public static func center(_ keys: [ReframeKey], at t: Double) -> (x: Double, y: Double)? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if t <= first.time { return (first.x, first.y) }
        if t >= last.time { return (last.x, last.y) }
        var lo = 0, hi = keys.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if keys[m].time <= t { lo = m } else { hi = m } }
        let a = keys[lo], b = keys[hi], u = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
        return (a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
    }

    /// A calm camera path from where the people were seen: gaps are bridged, the target is averaged over about a second, the frame only
    /// moves when the people leave its middle part (`deadZone`, as a fraction of the picture), never faster than `maxSpeed` picture
    /// widths a second, and the keys are thinned out to those that bend the path.
    public static func path(_ samples: [PersonSample], deadZone: Double = 0.06, maxSpeed: Double = 0.35, smoothing: Double = 1.0) -> [ReframeKey] {
        let s = samples.sorted { $0.time < $1.time }
        guard !s.isEmpty else { return [] }
        // Bridge the frames where nobody was found: hold the last place (the first one found, before anybody is seen).
        let firstSeen = s.first { $0.center != nil }?.center ?? (0.5, 0.5)
        var held = firstSeen
        let raw: [(t: Double, x: Double, y: Double)] = s.map { p in if let c = p.center { held = c }; return (p.time, held.x, held.y) }
        // Average over `smoothing` seconds around each moment.
        var avg: [(t: Double, x: Double, y: Double)] = []
        var a = 0, b = 0, sx = 0.0, sy = 0.0
        for i in raw.indices {
            while b < raw.count && raw[b].t <= raw[i].t + smoothing / 2 { sx += raw[b].x; sy += raw[b].y; b += 1 }
            while raw[a].t < raw[i].t - smoothing / 2 { sx -= raw[a].x; sy -= raw[a].y; a += 1 }
            let n = Double(b - a)
            avg.append((raw[i].t, sx / n, sy / n))
        }
        // Follow with a dead zone and a speed limit.
        var cam = (x: avg[0].x, y: avg[0].y)
        var out: [ReframeKey] = [ReframeKey(time: avg[0].t, x: cam.x, y: cam.y)]
        for i in avg.indices.dropFirst() {
            let dt = max(0, avg[i].t - avg[i - 1].t), step = maxSpeed * dt
            func follow(_ c: Double, _ target: Double) -> Double {
                let d = target - c
                guard abs(d) > deadZone else { return c }
                let want = d - (d > 0 ? deadZone : -deadZone)
                return c + min(max(want, -step), step)
            }
            cam = (follow(cam.x, avg[i].x), follow(cam.y, avg[i].y))
            out.append(ReframeKey(time: avg[i].t, x: cam.x, y: cam.y))
        }
        return simplify(out, tolerance: 0.004)
    }

    /// Drops keys that lie (within `tolerance`) on the straight line between their neighbours kept.
    static func simplify(_ k: [ReframeKey], tolerance: Double) -> [ReframeKey] {
        guard k.count > 2 else { return k }
        var keep = [k[0]]
        var anchor = 0
        for i in 1..<(k.count - 1) {
            let a = k[anchor], c = k[i + 1]
            // Would the line from the last key kept to the next one pass every key in between closely enough?
            var ok = true
            for j in (anchor + 1)...i {
                guard let p = center([a, c], at: k[j].time) else { continue }
                if abs(p.x - k[j].x) > tolerance || abs(p.y - k[j].y) > tolerance { ok = false; break }
            }
            if !ok { keep.append(k[i]); anchor = i }
        }
        keep.append(k[k.count - 1])
        return keep
    }

    /// Where a point of the picture as it comes from the file (0…1, top-left) lies on the edited picture, after the crop and the quarter
    /// turns; nil when the crop cuts it away.
    public static func edited(_ p: (x: Double, y: Double), crop: CropRect, rotation: Int) -> (x: Double, y: Double)? {
        var x = (p.x - crop.x) / max(crop.width, 1e-6), y = (p.y - crop.y) / max(crop.height, 1e-6)
        guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else { return nil }
        x = min(max(x, 0), 1); y = min(max(y, 0), 1)
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (1 - y, x)
        case 180: return (1 - x, 1 - y)
        case 270: return (y, 1 - x)
        default: return (x, y)
        }
    }
}
