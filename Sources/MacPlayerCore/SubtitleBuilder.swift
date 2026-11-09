import Foundation

/// One recognised word and when it was said (seconds from the start of what was listened to).
public struct TimedWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var duration: Double
    public init(text: String, start: Double, duration: Double) { self.text = text; self.start = start; self.duration = duration }
    public var end: Double { start + duration }
}

/// Turns a stream of recognised words into subtitles people can read: short lines that break at pauses and at the end of sentences,
/// stay on screen long enough, and do not run into each other.
public enum SubtitleBuilder {
    public struct Rules: Sendable {
        /// A pause this long (seconds) starts a new subtitle.
        public var pause = 0.7
        public var maxWords = 8
        public var maxCharacters = 42
        public var minDuration = 0.8
        /// Gap kept between one subtitle and the next.
        public var gap = 0.04
        public init() {}
    }

    private static func endsSentence(_ w: String) -> Bool { w.last.map { ".!?…。！？".contains($0) } ?? false }

    /// `offset` is added to every time (where in the video the listened-to part began).
    public static func cues(from words: [TimedWord], offset: Double = 0, rules: Rules = Rules()) -> [SubtitleCue] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.start < $1.start }
        var groups: [[TimedWord]] = []
        var current: [TimedWord] = []
        func characters(_ g: [TimedWord]) -> Int { g.map(\.text).joined(separator: " ").count }
        for w in words {
            if let last = current.last {
                let paused = w.start - last.end > rules.pause
                let full = current.count >= rules.maxWords || characters(current + [w]) > rules.maxCharacters
                let sentence = endsSentence(last.text) && current.count >= 3
                if paused || full || sentence { groups.append(current); current = [] }
            }
            current.append(w)
        }
        if !current.isEmpty { groups.append(current) }

        var out: [SubtitleCue] = []
        for (i, g) in groups.enumerated() {
            let start = g.first!.start + offset
            var end = g.last!.end + offset
            // Stay on screen long enough to read, but never into the next subtitle.
            end = max(end, start + rules.minDuration)
            if i + 1 < groups.count { end = min(end, groups[i + 1].first!.start + offset - rules.gap) }
            end = max(end, start + 0.2)
            out.append(SubtitleCue(start: MediaTime(seconds: start), end: MediaTime(seconds: end), text: g.map(\.text).joined(separator: " ")))
        }
        return out
    }
}
