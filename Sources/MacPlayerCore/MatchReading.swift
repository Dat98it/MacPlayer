import Foundation

/// Recognises an actual line-up graphic, rather than mistaking the walk-out/handshakes for the announced team sheets.
public enum LineupReader {
    public static func isTable(_ texts: [String]) -> Bool {
        let words = texts.map {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .uppercased().replacingOccurrences(of: "Đ", with: "D")
        }
        let title = words.joined(separator: " ")
        let tokens = Set(title.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let starters = title.contains("CHINH THUC") || title.contains("STARTING") || title.contains("STARTERS")
        let bench = title.contains("DU BI") || tokens.contains("SUBSTITUTES") || tokens.contains("SUBS")
        let lineup = title.contains("DOI HINH") || title.contains("LINE-UP") || title.contains("LINE UP") || title.contains("LINEUP")
        let numbers = words.filter { Int($0.trimmingCharacters(in: .whitespaces)).map { (1...99).contains($0) } ?? false }.count
        return (starters && bench) || ((starters || lineup) && numbers >= 5)
    }
}

// MARK: The match clock and words on the picture (0.22.2)

/// A stretch of play read from the match clock on a scoreboard: when the clock started running (kick-off) and when it stopped
/// (half-time, full time). Seconds of the video.
public struct MatchPeriod: Equatable, Sendable {
    public var kickoff: Double
    public var end: Double
    /// The kick-off is in the video: the clock was seen standing before it, or had counted under a minute at the first look. A video
    /// that joins the match later (a stream cut short, a recording started late) has a period whose start was never seen.
    public var kickoffSeen: Bool
    public init(kickoff: Double, end: Double, kickoffSeen: Bool = true) { self.kickoff = kickoff; self.end = end; self.kickoffSeen = kickoffSeen }
}

/// Follows the match clock ("12:34") read now and then from the picture. Looks where it moves on as the video does are a period of play;
/// the clock standing still (at 00:00 before kick-off, at half-time, at the end) is not. A clock is told from a score by its two-digit
/// seconds after a colon.
public struct ClockReader: Sendable {
    private var looks: [(t: Double, s: Int, x: Double, y: Double)] = []
    public init() {}

    public static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let p = t.split(separator: ":").map(String.init)
        guard p.count == 2, (1...3).contains(p[0].count), p[1].count == 2, p.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let m = Int(p[0]), let s = Int(p[1]), s < 60, m < 200 else { return nil }
        return m * 60 + s
    }

    public mutating func add(_ texts: [(text: String, x: Double, y: Double)], at time: Double) {
        for w in texts { if let s = Self.parse(w.text) { looks.append((time, s, w.x, w.y)) } }
    }

    /// The periods of play, in time order. A period needs the clock running over at least three looks.
    public func periods() -> [MatchPeriod] {
        // The clock is at the place read most often.
        var places: [(x: Double, y: Double, n: Int)] = []
        for l in looks {
            if let i = places.firstIndex(where: { abs($0.x - l.x) < 0.04 && abs($0.y - l.y) < 0.04 }) { places[i].n += 1 } else { places.append((l.x, l.y, 1)) }
        }
        guard let at = places.max(by: { $0.n < $1.n }) else { return [] }
        let clock = looks.filter { abs($0.x - at.x) < 0.04 && abs($0.y - at.y) < 0.04 }.sorted { $0.t < $1.t }
        guard clock.count >= 3 else { return [] }
        var out: [MatchPeriod] = []
        // Where each period's clock was read first and last (time, clock), to join pieces of one period (below).
        var reads: [(t0: Double, s0: Int, t1: Double, s1: Int)] = []
        var runStart: Int? = nil
        var lastRunning = 0
        func runs(_ a: Int, _ b: Int) -> Bool {
            let dt = clock[b].t - clock[a].t, ds = Double(clock[b].s - clock[a].s)
            return dt > 0 && ds > 0 && abs(ds - dt) <= max(2, dt * 0.05)
        }
        func close() {
            guard let a = runStart, lastRunning - a >= 2 else { runStart = nil; return }
            // Kick-off: if the look before showed the clock standing at a lower value (00:00, 35:00), it started from there: as many
            // seconds before the first running look as it had counted. With no such look, only a clock that had counted under a minute
            // tells when it started (from 00:00); a later one means the video joined the period after its kick-off.
            var kickoff = clock[a].t
            var seen = false
            if a > 0 {
                let p = clock[a - 1], counted = Double(clock[a].s - p.s)
                if counted >= 0 && counted <= clock[a].t - p.t + 1 { kickoff = clock[a].t - counted; seen = true }
            }
            // A clock that starts a period at a round value (00:00, or 30:00, 35:00, 45:00 for a second half) and had counted little:
            // started from there. At the very first look of the video only a clock barely started counts (a video that joins the
            // match a little after a round minute must not get a kick-off).
            let sinceRound = clock[a].s % 300
            if !seen && clock[a].s <= 60 { kickoff = clock[a].t - Double(clock[a].s); seen = true }
            if !seen && (a > 0 ? sinceRound <= 60 : (clock[a].s >= 1200 && sinceRound <= 15)) { kickoff = clock[a].t - Double(sinceRound); seen = true }
            // End: the last look that still ran, plus up to the next look if the clock stood still there.
            var end = clock[lastRunning].t
            if lastRunning + 1 < clock.count, clock[lastRunning + 1].s >= clock[lastRunning].s {
                end += Double(clock[lastRunning + 1].s - clock[lastRunning].s)
            }
            out.append(MatchPeriod(kickoff: kickoff, end: end, kickoffSeen: seen))
            reads.append((clock[a].t, clock[a].s, clock[lastRunning].t, clock[lastRunning].s))
            runStart = nil
        }
        // Each look against the next one that differs from a misread: up to two looks are skipped.
        var i = 0
        while i < clock.count - 1 {
            var j = i + 1
            while j < min(clock.count, i + 4) && !runs(i, j) { j += 1 }
            if j < min(clock.count, i + 4), runs(i, j) {
                if runStart == nil { runStart = i }
                lastRunning = j
                i = j
            } else {
                close()
                i += 1
            }
        }
        close()
        // One period read in pieces (0.22.9): while a replay or a graphic hides the scoreboard, or a few looks are misread, the clock
        // goes on. A piece whose clock carries on from the one before (it counted as much as the video ran, give or take 10 s) is
        // the same period, not a new kick-off and a whistle in between (a 35-minute half was cut in two at 1:45).
        var merged: [MatchPeriod] = []
        var last: (t1: Double, s1: Int)? = nil
        for (k, p) in out.enumerated() {
            let r = reads[k]
            if let l = last, var prev = merged.popLast() {
                let ran = r.t0 - l.t1, counted = Double(r.s0 - l.s1)
                if counted >= 0 && abs(counted - ran) <= max(10, ran * 0.05) {
                    prev.end = p.end
                    merged.append(prev)
                    last = (r.t1, r.s1)
                    continue
                }
                merged.append(prev)
            }
            merged.append(p)
            last = (r.t1, r.s1)
        }
        return merged
    }
}

/// What the words on the picture may tell: a card shown, a VAR check, a substitution (broadcast graphics write them).
public enum MatchWord: String, Codable, Sendable, CaseIterable {
    case yellowCard, redCard, check, substitution

    /// Words that name it, in capitals without accents (Vietnamese and English).
    var words: [String] {
        switch self {
        case .yellowCard: return ["THE VANG", "YELLOW CARD", "YELLOW"]
        case .redCard: return ["THE DO", "RED CARD"]
        case .check: return ["VAR", "CHECK VAR", "KIEM TRA VAR"]
        case .substitution: return ["THAY NGUOI", "SUBSTITUTION", "SUBSTITUTIONS"]
        }
    }

    /// The kind named in a piece of text, if any.
    public static func find(in text: String) -> MatchWord? {
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi")).uppercased()
            .replacingOccurrences(of: "Đ", with: "D")
        let tokens = plain.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        for k in [MatchWord.redCard, .yellowCard, .check, .substitution] {
            for w in k.words where (" " + tokens + " ").contains(" " + w + " ") { return k }
        }
        return nil
    }
}

/// Collects the words that tell of a card or a VAR check: one event per kind and minute (a graphic stays up for several looks).
public struct WordSpotter: Sendable {
    public private(set) var events: [(kind: MatchWord, time: Double)] = []
    public init() {}
    public mutating func add(_ texts: [(text: String, x: Double, y: Double)], at time: Double) {
        for w in texts {
            guard let k = MatchWord.find(in: w.text) else { continue }
            if events.contains(where: { $0.kind == k && time - $0.time < 60 }) { continue }
            events.append((k, time))
        }
    }
}
