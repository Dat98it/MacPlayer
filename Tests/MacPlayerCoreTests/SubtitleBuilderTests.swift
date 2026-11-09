import Foundation
import Testing
@testable import MacPlayerCore

struct SubtitleBuilderTests {
    func words(_ list: [(String, Double, Double)]) -> [TimedWord] { list.map { TimedWord(text: $0.0, start: $0.1, duration: $0.2) } }

    @Test func aPauseStartsANewSubtitle() {
        let w = words([("Hello", 0, 0.4), ("there", 0.5, 0.4), ("how", 2.0, 0.3), ("are", 2.4, 0.3), ("you", 2.8, 0.3)])
        let c = SubtitleBuilder.cues(from: w)
        #expect(c.map(\.text) == ["Hello there", "how are you"])
        #expect(c[0].start == MediaTime(seconds: 0) && c[1].start == MediaTime(seconds: 2.0))
    }

    @Test func aLongRunOfWordsIsCutIntoLinesThatFit() {
        let w = words((0..<20).map { ("word\($0)", Double($0) * 0.3, 0.25) })
        let c = SubtitleBuilder.cues(from: w)
        #expect(c.count >= 3)
        #expect(c.allSatisfy { $0.text.split(separator: " ").count <= 8 && $0.text.count <= 42 }, "each line is short enough to read")
        #expect(c.flatMap { $0.text.split(separator: " ") }.map(String.init) == w.map(\.text), "no word is lost or reordered")
    }

    @Test func aSentenceEndBreaksTheLineOnceThereAreEnoughWords() {
        let w = words([("It", 0, 0.2), ("is", 0.25, 0.2), ("done.", 0.5, 0.3), ("Next", 0.85, 0.3), ("part", 1.2, 0.3), ("starts", 1.55, 0.3)])
        #expect(SubtitleBuilder.cues(from: w).map(\.text) == ["It is done.", "Next part starts"])
        let tiny = words([("Yes.", 0, 0.3), ("Right", 0.35, 0.3), ("now", 0.7, 0.3)])
        #expect(SubtitleBuilder.cues(from: tiny).count == 1, "a one-word sentence does not get a subtitle to itself")
    }

    @Test func eachSubtitleStaysLongEnoughButNeverRunsIntoTheNext() {
        let w = words([("Quick", 0, 0.2), ("one", 0.25, 0.2), ("Later", 1.2, 0.3), ("part", 1.55, 0.3)])
        let c = SubtitleBuilder.cues(from: w)
        #expect((c[0].end - c[0].start).seconds >= 0.8 - 1e-9, "a short phrase is held for at least 0.8 s")
        #expect(c[0].end <= c[1].start, "and does not run into the next one")
        #expect(c.allSatisfy { $0.end > $0.start })
        let squeezed = SubtitleBuilder.cues(from: words([("a", 0, 0.1), ("b", 0.12, 0.1), ("c", 0.85, 0.1), ("d", 0.97, 0.1), ("e", 1.09, 0.1), ("f", 1.21, 0.1)]), rules: { var r = SubtitleBuilder.Rules(); r.pause = 0.5; return r }())
        #expect(squeezed.count == 2 && squeezed[0].end <= squeezed[1].start)
    }

    @Test func theOffsetPutsTheTimesWhereTheListenedPartBeganInTheVideo() {
        let c = SubtitleBuilder.cues(from: words([("Hi", 1, 0.5), ("you", 1.6, 0.5)]), offset: 30)
        #expect(c.first?.start == MediaTime(seconds: 31))
    }

    @Test func emptyInputAndBlankWordsGiveNothing() {
        #expect(SubtitleBuilder.cues(from: []).isEmpty)
        #expect(SubtitleBuilder.cues(from: words([(" ", 0, 1), ("", 1, 1)])).isEmpty)
    }
}
