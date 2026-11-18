import Foundation

// MARK: Reading the score on a scoreboard (0.22.1)

/// A goal seen on the scoreboard: the score read before and after, the last time the old score was read and the first time the new one
/// was (seconds). The goal itself came before `firstNew`: a live stream's scoreboard is put right by hand, often half a minute later.
public struct ScoreChange: Equatable, Sendable {
    public var from: (Int, Int)
    public var to: (Int, Int)
    public var lastOld: Double
    public var firstNew: Double
    /// The team that scored, when the score could only be seen to change, not read (0.22.9).
    public var team: String?
    /// The score is known (read, or counted from a 0-0 kick-off); else only who scored is.
    public var counted = true
    public init(from: (Int, Int), to: (Int, Int), lastOld: Double, firstNew: Double, team: String? = nil, counted: Bool = true) {
        self.from = from; self.to = to; self.lastOld = lastOld; self.firstNew = firstNew; self.team = team; self.counted = counted
    }
    public static func == (a: ScoreChange, b: ScoreChange) -> Bool { a.from == b.from && a.to == b.to && a.lastOld == b.lastOld && a.firstNew == b.firstNew && a.team == b.team }
    /// "0-1", "2-5"; the scoring team when the score is not known.
    public var label: String { counted || team == nil ? "\(to.0)-\(to.1)" : team! }
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


// MARK: Seeing the score change when its digits cannot be read (0.22.9)

/// Where a word or a part of the picture is: 0…1 of the picture, from the top-left (Core keeps to Foundation, without CoreGraphics).
public struct TextFrame: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// Some scoreboards put each digit alone in a box of its own (dark on white), which text recognition leaves out, while it reads the
/// team names on both sides. The boxes are the gap between the names: each half of it is watched (a small picture of it at every
/// look); a half that changes and keeps its new look is a goal for the team on that side.
public struct BoardWatch: Sendable {
    /// One look at a candidate scoreboard: the two names and the pictures of the left and right halves of the gap between them.
    private struct Look { var t: Double; var left: String; var right: String; var gap: [UInt8] }
    /// The gap is pictured `cols` across and `rows` down.
    public static let cols = 48, rows = 12
    private var looks: [Look] = []
    /// Where each pair's gap was found first: every later look takes its pictures at exactly that place (the words' frames move a
    /// little from one look to the next, and pictures taken a few pixels apart looked like a changed score: 9 goals for 4).
    private var anchors: [String: (gap: TextFrame, seen: Int)] = [:]
    /// The first sightings of each pair, before its place is settled (the middle of five: a board seen first while it slides in
    /// is not where it stays).
    private var firstSeen: [String: [TextFrame]] = [:]

    public init() {}

    /// One look: the words read with their boxes (0…1, top-left origin), and a way to take a small picture (`picture(rect)`, any
    /// fixed number of brightness values) of a part of the frame.
    public mutating func add(_ words: [(text: String, box: TextFrame)], at time: Double, picture: (TextFrame, Int, Int) -> [UInt8]) {
        func isName(_ s: String) -> Bool { s.filter(\.isLetter).count >= 2 && s.count <= 16 }
        let names = words.filter { isName($0.text) }
        for l in names {
            for r in names where r.box.minX > l.box.maxX {
                let h = max(l.box.height, r.box.height)
                guard abs(l.box.midY - r.box.midY) < h * 0.3, min(l.box.height, r.box.height) > h * 0.6 else { continue }
                let gap = r.box.minX - l.box.maxX
                guard gap > h * 0.8, gap < h * 6 else { continue }
                // Nothing else written in the gap but digits (a score read as text is fine).
                func between(_ w: (text: String, box: TextFrame)) -> Bool { w.box.midX > l.box.maxX && w.box.midX < r.box.minX && abs(w.box.midY - l.box.midY) < h }
                func scoreLike(_ text: String) -> Bool { text.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" || $0 == ":" } }
                guard words.filter(between).allSatisfy({ scoreLike($0.text) }) else { continue }
                let y = min(l.box.minY, r.box.minY), height = max(l.box.maxY, r.box.maxY) - y
                let here = TextFrame(x: l.box.maxX, y: y, width: gap, height: height)
                let key = l.text + "|" + r.text
                // The board where it was first seen; a look that finds it elsewhere (moved, half hidden) is left out.
                guard let anchor = anchors[key] else {
                    firstSeen[key, default: []].append(here)
                    let f = firstSeen[key]!
                    if f.count >= 5 {
                        func mid(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
                        anchors[key] = (TextFrame(x: mid(f.map(\.x)), y: mid(f.map(\.y)), width: mid(f.map(\.width)), height: mid(f.map(\.height))), 1)
                    }
                    continue
                }
                let g = anchor.gap
                guard abs(here.midX - g.midX) < g.height * 0.6, abs(here.midY - g.midY) < g.height * 0.4,
                      abs(here.width - g.width) < g.height * 0.8 else { continue }
                anchors[key]!.seen += 1
                looks.append(Look(t: time, left: l.text, right: r.text, gap: picture(g, Self.cols, Self.rows)))
            }
        }
    }

    /// Where the score boxes were found (for measuring).
    public var boardFrame: TextFrame? { teams.flatMap { anchors[$0.left + "|" + $0.right]?.gap } }

    /// The names of the scoreboard (the pair seen most often), if seen often enough.
    public var teams: (left: String, right: String)? {
        var count: [String: Int] = [:]
        for l in looks { count[l.left + "|" + l.right, default: 0] += 1 }
        guard let best = count.max(by: { $0.value < $1.value }), best.value >= 6 else { return nil }
        let p = best.key.split(separator: "|", maxSplits: 1).map(String.init)
        return p.count == 2 ? (p[0], p[1]) : nil
    }

    /// Goals seen: a half of the gap that took a new look kept for two looks in a row. With `fromNil`, counted from 0-0 (the video
    /// shows the kick-off); else each goal carries the name of the team that scored.
    /// For measuring: each look of the left score that differs from the one held.
    nonisolated(unsafe) public static var trace: ((String) -> Void)?

    /// For measuring: which columns held strokes and where they were split, at the last `goals`.
    nonisolated(unsafe) public static var lastLayoutText = ""
    private var lastLayout: String { get { Self.lastLayoutText } nonmutating set { Self.lastLayoutText = newValue } }

    public func goals(fromNil: Bool) -> [ScoreChange] {
        guard let t = teams else { return [] }
        let board = looks.filter { $0.left == t.left && $0.right == t.right && $0.gap.count == Self.cols * Self.rows }.sorted { $0.t < $1.t }
        guard board.count >= 6 else { return [] }
        // The digits are where the gap has strokes: columns whose brightness changes a lot from top to bottom (on most looks); the
        // name boxes' fill and the plain boxes around the digits do not. The stroked columns make two groups: the two scores.
        let C = Self.cols, R = Self.rows
        var stroke = [Double](repeating: 0, count: C)
        for l in board {
            for c in 0..<C {
                let col = (0..<R).map { Int(l.gap[$0 * C + c]) }
                var v = 0; for r in 1..<R { v += abs(col[r] - col[r - 1]) }
                stroke[c] += Double(v) / Double(board.count)
            }
        }
        let cut = (stroke.sorted()[C * 3 / 4] + stroke.sorted()[C / 4]) / 2
        let marked = (0..<C).filter { stroke[$0] > cut }
        guard marked.count >= 2 else { return [] }
        // The stroked columns in runs (a plain column or two inside a digit, like the hollow of a 0, does not break a run); the two
        // widest runs are the two scores, left and right. A lone stroked column (the edge of a name's box) is left out.
        var runs: [[Int]] = []
        for c in marked { if let l = runs.last?.last, c - l <= 3 { runs[runs.count - 1].append(c) } else { runs.append([c]) } }
        guard runs.count >= 2 else { return [] }
        let two = runs.sorted { $0.count > $1.count }.prefix(2).sorted { $0[0] < $1[0] }
        let sides = [two[0], two[1]]
        lastLayout = "marked \(marked) sides \(sides)"
        guard sides.allSatisfy({ !$0.isEmpty }) else { return [] }
        func part(_ l: Look, _ side: Int) -> [UInt8] { (0..<R).flatMap { r in sides[side].map { l.gap[r * C + $0] } } }
        func differ(_ x: [UInt8], _ y: [UInt8]) -> Bool {
            guard x.count == y.count, !x.isEmpty else { return false }
            // Each picture as strokes and ground: darker or lighter than halfway between its dark and its light (the 10th and
            // 90th percentiles), so a change of light on the whole board is not a change, and a thin 1 keeps its ground (halving
            // at the median gave a thin digit half of the ground as "stroke": two looks at the same 1 differed).
            func bits(_ v: [UInt8]) -> [Bool] {
                let o = v.map(Int.init).sorted(), lo = o[o.count / 10], hi = o[o.count * 9 / 10]
                guard hi - lo > 24 else { return v.map { _ in false } }
                let m = (lo + hi) / 2
                return v.map { Int($0) < m }
            }
            let a = bits(x), b = bits(y)
            return Double(zip(a, b).filter { $0 != $1 }.count) / Double(a.count) > 0.08
        }
        var events: [(t: Double, last: Double, side: Int)] = []
        for side in 0..<2 {
            func pic(_ l: Look) -> [UInt8] { part(l, side) }
            var stable: [UInt8]? = nil, lastSeen = 0.0
            var i = 0
            while i < board.count {
                let p = pic(board[i])
                guard let st = stable else {
                    if i + 1 < board.count, !differ(p, pic(board[i + 1])) { stable = p; lastSeen = board[i].t }
                    i += 1; continue
                }
                if !differ(p, st) { lastSeen = board[i].t; i += 1; continue }
                if let tr = Self.trace, side == 0 { tr(String(format: "side0 %.0f differs; next4 same %d", board[i].t, (1...4).filter { i + $0 < board.count && !differ(p, pic(board[i + $0])) }.count)) }
                // A new look that stays, and the old look not back within five minutes (a score does not go down; a graphic passing
                // over the board, a flash or a misplaced look does go back): the score changed.
                // Kept: seen again in 3 of the next 4 looks (one look may fall on a "GOAL" graphic over the board). Back: the old
                // look seen twice in a row (one look alike by chance is not the score going back).
                let kept = i + 4 < board.count && (1...4).filter({ !differ(p, pic(board[i + $0])) }).count >= 3
                let later = Array(board[(i + 1)...].prefix { $0.t - board[i].t < 300 })
                let back = later.indices.dropLast().contains { !differ(pic(later[$0]), st) && !differ(pic(later[$0 + 1]), st) }
                if kept && !back {
                    events.append((board[i].t, lastSeen, side)); stable = p; lastSeen = board[i].t
                }
                i += 1
            }
        }
        var score = (0, 0)
        return events.sorted { $0.t < $1.t }.map { e in
            let from = score
            if e.side == 0 { score.0 += 1 } else { score.1 += 1 }
            return ScoreChange(from: from, to: score, lastOld: e.last, firstNew: e.t, team: e.side == 0 ? t.left : t.right, counted: fromNil)
        }
    }
}
