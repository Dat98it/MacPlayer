import Foundation
import Testing
@testable import MacPlayerCore

/// 0.20: captions in short lines, with the word being said marked.
struct CaptionTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 6000) }
    private func w(_ t: String, _ a: Double, _ b: Double) -> TimedWord { TimedWord(text: t, start: a, duration: b - a) }

    @Test func recognisedWordsMakeShortLinesThatKeepTheirTimes() {
        let words = [w("xin", 1.0, 1.2), w("chào", 1.25, 1.5), w("các", 1.55, 1.7), w("bạn.", 1.75, 2.0),
                     w("hôm", 3.0, 3.2), w("nay", 3.25, 3.5)]
        let cues = SubtitleBuilder.captionCues(from: words, offset: 10)
        #expect(cues.map(\.text) == ["xin chào các", "bạn.", "hôm nay"])
        #expect(abs(cues[0].start.seconds - 11) < 0.001)
        #expect(cues[0].words?.map(\.text) == ["xin", "chào", "các"])
        #expect(abs((cues[0].words?[1].start ?? 0) - 0.25) < 0.001, "times count from the line's start")
        #expect(cues[0].activeWord(at: 11.3) == 1 && cues[0].activeWord(at: 11.0) == 0 && cues[0].activeWord(at: 11.6) == 2)
        #expect(cues[0].activeWord(at: 10.9) == nil)
    }

    @Test func typedLinesAreTimedByWordLength() {
        let c = SubtitleCue(start: s(0), end: s(3), text: "một hai ba")
        let t = c.timedWords
        #expect(t.count == 3 && abs(t[0].start) < 0.001 && abs(t[2].end - 3) < 0.001)
        #expect(c.activeWord(at: 0.1) == 0 && c.activeWord(at: 2.9) == 2)
        var edited = c
        edited.words = [CaptionWord(text: "một", start: 0, end: 1)]
        #expect(edited.timedWords.count == 3, "stored words that no longer match the text are not used")
    }

    @Test func longSubtitlesSplitIntoShortLines() {
        var d = SubtitleDocument()
        d.cues = [SubtitleCue(start: s(10), end: s(16), text: "một hai ba bốn năm sáu bảy")]
        let r = d.splitIntoCaptions()
        #expect(r.before == 1 && r.after == 3)
        #expect(d.cues.map(\.text) == ["một hai ba", "bốn năm sáu", "bảy"])
        #expect(d.cues[0].start == s(10) && abs(d.cues[2].end.seconds - 16) < 0.001)
        #expect(abs(d.cues[0].end.seconds - d.cues[1].start.seconds) < 0.001, "one line ends where the next begins")
        #expect(d.cues.allSatisfy { $0.words != nil })
    }

    @Test func aCutThroughTheStartOfALineDropsTheWordsSaidThere() {
        var p = Project(name: "c", kind: .video)
        p.timeline = [TimelineClip(sourceID: UUID(), sourceStart: s(0), sourceEnd: s(20))]
        var c = SubtitleCue(start: s(5), end: s(8), text: "a b c")
        c.words = [CaptionWord(text: "a", start: 0, end: 0.9), CaptionWord(text: "b", start: 1, end: 1.9), CaptionWord(text: "c", start: 2, end: 2.9)]
        p.subtitles.cues = [c]
        TimelineRipple.remove(TimeSpan(start: s(4), end: s(6)), from: &p)
        #expect(p.subtitles.cues[0].text == "b c")
        #expect(p.subtitles.cues[0].start == s(4) && abs((p.subtitles.cues[0].words?[0].start ?? -1) - 0) < 0.001)
        #expect(abs((p.subtitles.cues[0].words?[1].start ?? -1) - 1) < 0.001)
    }

    @Test func oldStylesAndCuesStillOpen() throws {
        let style = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(SubtitleStyle()))
        #expect(style.caption == nil)
        var withCaption = SubtitleStyle(); withCaption.caption = CaptionStyle(look: .box)
        #expect(try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(withCaption)).caption?.look == .box)
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":{"value":0,"timescale":600},"end":{"value":600,"timescale":600},"text":"hi"}"#
        #expect(try JSONDecoder().decode(SubtitleCue.self, from: Data(old.utf8)).words == nil)
    }
}
