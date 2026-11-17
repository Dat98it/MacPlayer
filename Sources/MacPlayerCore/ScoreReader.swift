import Foundation

// MARK: Reading the score on a scoreboard (0.22.1)

/// A goal seen on the scoreboard: the score read before and after, the last time the old score was read and the first time the new one
/// was (seconds). The goal itself came before `firstNew`: a live stream's scoreboard is put right by hand, often half a minute later.
public struct ScoreChange: Equatable, Sendable {
    public var from: (Int, Int)
    public var to: (Int, Int)
    public var lastOld: Double
    public var firstNew: Double
    public init(from: (Int, Int), to: (Int, Int), lastOld: Double, firstNew: Double) { self.from = from; self.to = to; self.lastOld = lastOld; self.firstNew = firstNew }
    public static func == (a: ScoreChange, b: ScoreChange) -> Bool { a.from == b.from && a.to == b.to && a.lastOld == b.lastOld && a.firstNew == b.firstNew }
    /// "0-1", "2-5".
    public var label: String { "\(to.0)-\(to.1)" }
}

/// Follows the score from the words read on the picture now and then (by the Mac's text recognition): a pair of numbers ("0 1", "2-5",
/// "1:0") that stays at one place of the picture is a score; a clock ("11:16") is not, nor is a number that changes at nearly every look.
/// A change counts as a goal only when one side goes up by one and the new score is read twice in a row (a misread is not a goal).
public struct ScoreReader: Sendable {
    private struct Track {
        var x: Double, y: Double
        var looks: [(t: Double, a: Int, b: Int)] = []
    }
    private var tracks: [Track] = []
    private var looksTaken = 0

    public init() {}

    /// A score written as one piece of text: two numbers of one or two digits, apart, or joined by "-", "–" or ":" (but "mm:ss" is a clock).
    public static func parse(_ text: String) -> (Int, Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let parts = t.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "–" || $0 == ":" }).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        // A clock: minutes and two-digit seconds after a colon.
        if t.contains(":") && parts[1].count == 2 { return nil }
        // Only characters of a score.
        guard t.allSatisfy({ $0.isNumber || " -–:".contains($0) }) else { return nil }
        return (a, b)
    }

    /// One look: the words read and where they are (middle, 0…1 of the picture), at `time` seconds.
    public mutating func add(_ texts: [(text: String, x: Double, y: Double)], at time: Double) {
        looksTaken += 1
        for w in texts {
            guard let s = Self.parse(w.text) else { continue }
            if let i = tracks.firstIndex(where: { abs($0.x - w.x) < 0.04 && abs($0.y - w.y) < 0.04 }) {
                tracks[i].looks.append((time, s.0, s.1))
            } else {
                var t = Track(x: w.x, y: w.y); t.looks = [(time, s.0, s.1)]; tracks.append(t)
            }
        }
    }

    /// The goals seen, in time order, from the place read most often as a score.
    public func changes() -> [ScoreChange] {
        // The scoreboard: the place with the most looks, if it was read often enough.
        guard let board = tracks.max(by: { $0.looks.count < $1.looks.count }), board.looks.count >= 4 else { return [] }
        var out: [ScoreChange] = []
        var score: (Int, Int)? = nil
        var lastSeen = 0.0
        let looks = board.looks.sorted { $0.t < $1.t }
        var i = 0
        while i < looks.count {
            let l = looks[i]
            guard let s = score else {
                // The first score: read twice the same.
                if i + 1 < looks.count, looks[i + 1].a == l.a, looks[i + 1].b == l.b { score = (l.a, l.b); lastSeen = l.t }
                i += 1; continue
            }
            if l.a == s.0 && l.b == s.1 { lastSeen = l.t; i += 1; continue }
            // One side up by one (or two, when a look was missed), confirmed by the next look.
            let up = (l.a - s.0, l.b - s.1)
            let isGoal = up.0 >= 0 && up.1 >= 0 && up.0 + up.1 >= 1 && up.0 + up.1 <= 2
            if isGoal, i + 1 < looks.count, looks[i + 1].a == l.a, looks[i + 1].b == l.b {
                out.append(ScoreChange(from: s, to: (l.a, l.b), lastOld: lastSeen, firstNew: l.t))
                score = (l.a, l.b); lastSeen = l.t
            }
            i += 1
        }
        // A place whose numbers change at most looks is not a score (a clock, a counter).
        if out.count > max(3, board.looks.count / 3) { return [] }
        return out
    }
}
