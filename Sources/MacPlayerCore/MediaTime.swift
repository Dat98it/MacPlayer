import Foundation

/// A point or length of media time as an exact fraction `value / timescale` seconds.
/// Never a Double: 29.97 fps and 1/90000 s clocks must not drift when edits are saved and reloaded.
public struct MediaTime: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let value: Int64
    public let timescale: Int32

    public static let zero = MediaTime(value: 0, timescale: 600)

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "timescale must be positive")
        self.value = value
        self.timescale = timescale
    }

    /// Rounds to the nearest tick of `timescale` (default 600, the classic QuickTime base).
    public init(seconds: Double, timescale: Int32 = 600) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public var seconds: Double { Double(value) / Double(timescale) }

    public static func < (a: MediaTime, b: MediaTime) -> Bool {
        // Cross-multiply in 128-bit-safe form via Double only when magnitudes could overflow Int64.
        let l = a.value.multipliedFullWidth(by: Int64(b.timescale))
        let r = b.value.multipliedFullWidth(by: Int64(a.timescale))
        if l.high != r.high { return l.high < r.high }
        return l.low < r.low
    }

    public static func == (a: MediaTime, b: MediaTime) -> Bool {
        let l = a.value.multipliedFullWidth(by: Int64(b.timescale))
        let r = b.value.multipliedFullWidth(by: Int64(a.timescale))
        return l.high == r.high && l.low == r.low
    }

    public func hash(into h: inout Hasher) {
        // Reduce so equal fractions hash equally.
        let g = Self.gcd(abs(value), Int64(timescale))
        h.combine(g == 0 ? 0 : value / g)
        h.combine(g == 0 ? Int64(1) : Int64(timescale) / g)
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Re-expressed on another timescale, rounding to the nearest tick.
    public func converted(to newScale: Int32) -> MediaTime {
        if newScale == timescale { return self }
        let num = Double(value) * Double(newScale) / Double(timescale)
        return MediaTime(value: Int64(num.rounded()), timescale: newScale)
    }

    public static func + (a: MediaTime, b: MediaTime) -> MediaTime {
        let s = max(a.timescale, b.timescale)
        return MediaTime(value: a.converted(to: s).value + b.converted(to: s).value, timescale: s)
    }

    public static func - (a: MediaTime, b: MediaTime) -> MediaTime {
        let s = max(a.timescale, b.timescale)
        return MediaTime(value: a.converted(to: s).value - b.converted(to: s).value, timescale: s)
    }

    /// Clamped into `range`.
    public func clamped(to range: ClosedRange<MediaTime>) -> MediaTime {
        min(max(self, range.lowerBound), range.upperBound)
    }

    /// The index of the frame this time falls in (floor), at `rate` frames per second.
    public func frameIndex(frameRate: FrameRate) -> Int64 {
        // floor(value/timescale * num/den) = floor(value*num / (timescale*den)); small epsilon-free integer maths.
        let n = value.multipliedFullWidth(by: Int64(frameRate.numerator))
        let d = Int64(timescale) * Int64(frameRate.denominator)
        let num = Int128Lite(high: n.high, low: n.low)
        return num.floorDivide(by: d)
    }

    /// Start time of frame `index`, on the frame rate's own timescale (exact).
    public static func frameStart(index: Int64, frameRate: FrameRate) -> MediaTime {
        MediaTime(value: index * Int64(frameRate.denominator), timescale: frameRate.numerator)
    }

    /// Snaps to the start of the frame containing this time.
    public func snappedToFrame(_ frameRate: FrameRate) -> MediaTime {
        Self.frameStart(index: frameIndex(frameRate: frameRate), frameRate: frameRate)
    }

    public var description: String { Timecode.format(self) }
}

/// Frame rate as a fraction: 30000/1001 is 29.97 fps exactly.
public struct FrameRate: Hashable, Codable, Sendable, CustomStringConvertible {
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32) {
        precondition(numerator > 0 && denominator > 0)
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Nearest well-known broadcast rate for a measured value (e.g. 29.97003 becomes 30000/1001).
    public init(approximately fps: Double) {
        let known: [(Double, Int32, Int32)] = [
            (24000.0 / 1001, 24000, 1001), (24, 24, 1), (25, 25, 1), (30000.0 / 1001, 30000, 1001), (30, 30, 1),
            (48, 48, 1), (50, 50, 1), (60000.0 / 1001, 60000, 1001), (60, 60, 1), (120, 120, 1),
        ]
        if let k = known.first(where: { abs($0.0 - fps) < 0.01 }) {
            self.init(numerator: k.1, denominator: k.2)
        } else {
            self.init(numerator: Int32(max(1, (fps * 1000).rounded())), denominator: 1000)
        }
    }

    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }
    public var frameDuration: MediaTime { MediaTime(value: Int64(denominator), timescale: numerator) }
    public var description: String { String(format: "%.3f fps", framesPerSecond) }
}

/// Just enough 128-bit arithmetic for exact frame indices.
struct Int128Lite {
    var high: Int64
    var low: UInt64

    func floorDivide(by d: Int64) -> Int64 {
        precondition(d > 0)
        // Values here fit comfortably in Int64 after division (hours of media), so use dividingFullWidth.
        let q = d.dividingFullWidth((high: high, low: low))
        // dividingFullWidth truncates toward zero; floor for negatives.
        if q.remainder < 0 { return q.quotient - 1 }
        return q.quotient
    }
}

/// Timecode text: `H:MM:SS.mmm`, with an optional frame-accurate `HH:MM:SS:FF` form.
public enum Timecode {
    public static func format(_ t: MediaTime) -> String {
        let neg = t.value < 0
        let total = abs(t.seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int(((total - Double(Int(total))) * 1000).rounded(.down))
        let body = h > 0
            ? String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
            : String(format: "%02d:%02d.%03d", m, s, ms)
        return neg ? "-" + body : body
    }

    public static func format(_ t: MediaTime, frameRate: FrameRate) -> String {
        let idx = t.frameIndex(frameRate: frameRate)
        let fps = max(1, Int64((frameRate.framesPerSecond).rounded()))      // never 0 (a rate under half a frame a second)
        let f = idx % fps
        let totalSec = idx / fps
        return String(format: "%02d:%02d:%02d:%02d", totalSec / 3600, (totalSec % 3600) / 60, totalSec % 60, f)
    }

    /// Parses `S`, `S.mmm`, `M:SS`, `M:SS.mmm`, `H:MM:SS(.mmm)`, and `H:MM:SS:FF` when a frame rate is given.
    public static func parse(_ text: String, frameRate: FrameRate? = nil) -> MediaTime? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 4 else { return nil }
        func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
        if parts.count == 4 {
            guard let fr = frameRate, let h = Int64(parts[0]), let m = Int64(parts[1]), let s = Int64(parts[2]), let f = Int64(parts[3]),
                  h >= 0, (0..<60).contains(m), (0..<60).contains(s), f >= 0 else { return nil }
            let fps = max(1, Int64(fr.framesPerSecond.rounded()))
            guard f < fps else { return nil }
            return MediaTime.frameStart(index: (h * 3600 + m * 60 + s) * fps + f, frameRate: fr)
        }
        var seconds = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = num(p), v >= 0 else { return nil }
            if i > 0, v >= 60 { return nil } // minutes and seconds fields stop at 59
            if i < parts.count - 1, v.rounded() != v { return nil }
            seconds = seconds * 60 + v
        }
        return MediaTime(seconds: seconds, timescale: 1000)
    }
}

/// A half-open span of media time `[start, end)`.
public struct TimeSpan: Hashable, Codable, Sendable {
    public var start: MediaTime
    public var end: MediaTime

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = end
    }

    public var duration: MediaTime { end - start }
    public var isEmpty: Bool { end <= start }

    public func contains(_ t: MediaTime) -> Bool { t >= start && t < end }
    public func overlaps(_ o: TimeSpan) -> Bool { start < o.end && o.start < end }

    public func union(_ o: TimeSpan) -> TimeSpan { TimeSpan(start: min(start, o.start), end: max(end, o.end)) }
}
