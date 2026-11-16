import Foundation

// MARK: Captions in the style of short-video apps (0.20)

/// One word of a subtitle and when it is said, in seconds from the subtitle's own start (so moving the subtitle moves its words).
public struct CaptionWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// How the words of a caption are shown.
public enum CaptionLook: String, Codable, CaseIterable, Sendable {
    /// The word being said in another colour.
    case highlight
    /// The word being said on a coloured box.
    case box
    /// The word being said in colour and a little bigger; each line pops in.
    case pop
    /// One word at a time, large, popping in.
    case oneWord
    /// Big bold lines, no word marked.
    case bold
}

/// The caption look over the subtitles (nil on `SubtitleStyle` = classic subtitles).
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var look: CaptionLook
    public var highlightHex: String
    public var uppercase: Bool
    /// Where the middle of the text is, from the top (0…1).
    public var centerY: Double
    /// Letter size as a fraction of the picture's height.
    public var sizeFraction: Double
    public var fontName: String
    public init(look: CaptionLook = .highlight, highlightHex: String = "#FFE14D", uppercase: Bool = true, centerY: Double = 0.68, sizeFraction: Double = 0.05,
                fontName: String = CaptionStyle.defaultFont) {
        self.look = look; self.highlightHex = highlightHex; self.uppercase = uppercase; self.centerY = centerY; self.sizeFraction = sizeFraction; self.fontName = fontName
    }
    /// Heavy, and has every Vietnamese letter.
    public static let defaultFont = "AvenirNext-Bold"
    /// Short lines read best: this many words at most.
    public static let wordsPerLine = 3
}

extension SubtitleCue {
    /// The words of the text with when each is said: as recognised when the text still has those words, otherwise spread over the
    /// subtitle by their length (an imported or typed subtitle).
    public var timedWords: [CaptionWord] {
        let parts = plainText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !parts.isEmpty else { return [] }
        let length = max(0.05, (end - start).seconds)
        if let w = words, w.count == parts.count {
            return zip(parts, w).map { CaptionWord(text: $0, start: min(max(0, $1.start), length), end: min(max(0, $1.end), length)) }
        }
        let weights = parts.map { Double(max(2, $0.count)) }
        let total = weights.reduce(0, +)
        var t = 0.0
        return zip(parts, weights).map { p, w in
            let d = length * w / total
            defer { t += d }
            return CaptionWord(text: p, start: t, end: t + d)
        }
    }

    /// The word being said `t` seconds into the timeline: the last one that has started (a pause keeps the word before marked).
    public func activeWord(at t: Double) -> Int? {
        let local = t - start.seconds
        let w = timedWords
        guard !w.isEmpty, local >= 0, t < end.seconds else { return nil }
        return w.lastIndex { $0.start <= local + 0.0005 } ?? 0
    }
}

extension SubtitleBuilder {
    /// Short caption lines (at most `maxWords` words, breaking at pauses and sentence ends), each keeping its words' times.
    public static func captionCues(from words: [TimedWord], offset: Double = 0, maxWords: Int = CaptionStyle.wordsPerLine) -> [SubtitleCue] {
        var rules = Rules()
        rules.maxWords = maxWords
        rules.maxCharacters = 22
        rules.pause = 0.5
        rules.minDuration = 0.3
        var lines = SubtitleBuilder.cues(from: words, offset: offset, rules: rules)
        // Put each recognised word back into the line it went to, timed from the line's start.
        let sorted = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.start < $1.start }
        var i = 0
        for c in lines.indices {
            let n = lines[c].text.split(separator: " ").count
            guard i + n <= sorted.count else { break }
            let s0 = lines[c].start.seconds
            lines[c].words = sorted[i..<(i + n)].map { CaptionWord(text: $0.text, start: max(0, $0.start + offset - s0), end: max(0, $0.end + offset - s0)) }
            i += n
        }
        return lines
    }
}

extension SubtitleDocument {
    /// Long subtitles split into short caption lines of at most `maxWords` words, each on screen while its words are said. Returns how many
    /// lines there were before and after.
    @discardableResult
    public mutating func splitIntoCaptions(maxWords: Int = CaptionStyle.wordsPerLine) -> (before: Int, after: Int) {
        let before = cues.count
        var out: [SubtitleCue] = []
        for c in cues.sorted(by: { $0.start < $1.start }) {
            let w = c.timedWords
            guard w.count > maxWords else { out.append(c); continue }
            var i = 0
            while i < w.count {
                let part = Array(w[i..<min(w.count, i + maxWords)])
                let a = part.first!.start, b = i + maxWords >= w.count ? (c.end - c.start).seconds : w[i + maxWords].start
                var n = SubtitleCue(start: c.start + MediaTime(seconds: a, timescale: 6000), end: c.start + MediaTime(seconds: b, timescale: 6000),
                                    text: part.map(\.text).joined(separator: " "))
                n.words = part.map { CaptionWord(text: $0.text, start: $0.start - a, end: $0.end - a) }
                out.append(n)
                i += maxWords
            }
        }
        cues = out
        return (before, out.count)
    }
}
