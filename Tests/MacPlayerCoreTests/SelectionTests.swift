import Foundation
import Testing
@testable import MacPlayerCore

private func t(_ s: Double) -> MediaTime { MediaTime(seconds: s, timescale: 1000) }
private let fps30 = FrameRate(numerator: 30, denominator: 1)

@Suite struct MediaTimeTests {
    @Test func rationalComparisonIsExactAcrossTimescales() {
        #expect(MediaTime(value: 1001, timescale: 30000) == MediaTime(value: 2002, timescale: 60000))
        #expect(MediaTime(value: 1, timescale: 3) < MediaTime(value: 334, timescale: 1000))
        #expect(Set([MediaTime(value: 1, timescale: 2), MediaTime(value: 2, timescale: 4)]).count == 1)
    }

    @Test func frameIndexIsExactAt2997() {
        let fr = FrameRate(numerator: 30000, denominator: 1001)
        for n in [0, 1, 29, 30, 1000, 107_892] {
            #expect(MediaTime.frameStart(index: Int64(n), frameRate: fr).frameIndex(frameRate: fr) == Int64(n))
        }
        // Just before a frame boundary is still the previous frame.
        let almost = MediaTime(value: 1001 * 5 - 1, timescale: 30000)
        #expect(almost.frameIndex(frameRate: fr) == 4)
    }

    @Test func frameRateRecognisesBroadcastRates() {
        #expect(FrameRate(approximately: 29.97003) == FrameRate(numerator: 30000, denominator: 1001))
        #expect(FrameRate(approximately: 23.976) == FrameRate(numerator: 24000, denominator: 1001))
        #expect(FrameRate(approximately: 60) == FrameRate(numerator: 60, denominator: 1))
    }

    @Test func timecodeFormatsAndParsesBackAndForth() {
        #expect(Timecode.format(t(75.5)) == "01:15.500")
        #expect(Timecode.format(t(3725.25)) == "1:02:05.250")
        #expect(Timecode.parse("1:15.5")?.seconds == 75.5)
        #expect(Timecode.parse("1:02:05.250")?.seconds == 3725.25)
        #expect(Timecode.parse("90")?.seconds == 90)
        #expect(Timecode.parse("00:00:02:15", frameRate: fps30)?.seconds == 2.5)
        #expect(Timecode.parse("00:00:02:30", frameRate: fps30) == nil, "frame 30 does not exist at 30 fps")
        #expect(Timecode.parse("abc") == nil && Timecode.parse("") == nil && Timecode.parse("1:75") == nil && Timecode.parse("-5") == nil)
        #expect(Timecode.format(t(2.5), frameRate: fps30) == "00:00:02:15")
    }

    @Test func guardedCutKeepsExactlyTheNamedFrames() {
        let fr = FrameRate(numerator: 30000, denominator: 1001)
        let span = TimeSpan(start: .frameStart(index: 75, frameRate: fr), end: .frameStart(index: 150, frameRate: fr))
        let g = CutPlanning.guarded(span, frameRate: fr, duration: MediaTime(seconds: 10, timescale: 600))
        // Boundaries sit mid-frame: frame 75 starts before g.start, frame 150 starts after g.end.
        #expect(g.start > span.start && g.start < MediaTime.frameStart(index: 76, frameRate: fr))
        #expect(g.end < span.end && g.end > MediaTime.frameStart(index: 149, frameRate: fr))
    }

    @Test func guardedCutToTheEndKeepsTheLastFrame() {
        let d = MediaTime(seconds: 10, timescale: 600)
        let g = CutPlanning.guarded(TimeSpan(start: t(8), end: d), frameRate: fps30, duration: d)
        #expect(g.end == d)
    }
}

@Suite struct SelectionTests {
    @Test func addKeepsOrderNamesAndRejectsEmpty() {
        var l = SelectionList()
        #expect(l.add(start: t(10), end: t(10)) == nil)
        l.add(start: t(20), end: t(30))
        l.add(start: t(5), end: t(8))
        #expect(l.items.map(\.name) == ["Clip 2", "Clip 1"], "default names count up in creation order")
        #expect(l.items.map(\.start.seconds) == [5, 20], "ordered by start time")
    }

    @Test func backwardsInOutAreSwappedAndClampedToDuration() {
        var l = SelectionList()
        let s = l.add(start: t(30), end: t(10), duration: t(25))
        #expect(s?.start.seconds == 10 && s?.end.seconds == 25)
    }

    @Test func renameIgnoresBlankNames() {
        var l = SelectionList()
        let s = l.add(start: t(0), end: t(5), name: "Intro")!
        l.rename(s.id, to: "   ")
        #expect(l.items[0].name == "Intro")
        l.rename(s.id, to: " Mở đầu ")
        #expect(l.items[0].name == "Mở đầu")
    }

    @Test func duplicateAndRemove() {
        var l = SelectionList()
        let s = l.add(start: t(0), end: t(5), name: "A")!
        let c = l.duplicate(s.id)!
        #expect(l.items.count == 2 && c.id != s.id && c.name == "A copy")
        l.remove([s.id])
        #expect(l.items.map(\.id) == [c.id])
    }

    @Test func overlapsAreDetectedAndPolicyIsExplicit() {
        var l = SelectionList()
        l.add(start: t(0), end: t(10), name: "A"); l.add(start: t(8), end: t(20), name: "B"); l.add(start: t(30), end: t(40), name: "C")
        #expect(l.hasOverlaps && l.overlappingPairs().count == 1)
        #expect(l.overlapPolicy == .keepSeparate)
        #expect(l.effective().count == 3, "kept separate unless the user chooses to merge")
        l.overlapPolicy = .merge
        let merged = l.effective()
        #expect(merged.count == 2 && merged[0].start.seconds == 0 && merged[0].end.seconds == 20 && merged[0].name == "A")
    }

    @Test func touchingSelectionsAreNotOverlaps() {
        var l = SelectionList()
        l.add(start: t(0), end: t(10)); l.add(start: t(10), end: t(20))
        #expect(!l.hasOverlaps)
        l.overlapPolicy = .merge
        #expect(l.effective().count == 2, "back-to-back clips stay two clips")
    }

    @Test func reorderForExportOrder() {
        var l = SelectionList()
        for (i, n) in ["A", "B", "C"].enumerated() { l.add(start: t(Double(i) * 10), end: t(Double(i) * 10 + 5), name: n) }
        l.move(fromOffsets: [2], toOffset: 0)
        #expect(l.items.map(\.name) == ["C", "A", "B"])
    }

    @Test func csvQuotesCommasQuotesAndNewlines() {
        var l = SelectionList()
        l.add(start: t(0), end: t(2.5), name: "He said \"hi\", then left")
        let csv = ListExport.csv(selections: l.items, frameRate: fps30)
        #expect(csv.contains("\"He said \"\"hi\"\", then left\""))
        #expect(csv.hasPrefix("index,name,start,end,duration\n1,"))
    }

    @Test func jsonRoundTripKeepsVietnameseAndTiming() throws {
        var l = SelectionList()
        l.add(start: MediaTime(value: 1001 * 75, timescale: 30000), end: MediaTime(value: 1001 * 150, timescale: 30000), name: "Phần 1: Giới thiệu")
        let m = Marker(time: t(12.5), name: "Câu hỏi", color: .green, note: "ghi chú")
        let data = try ListExport.json(selections: l.items, markers: [m])
        let back = try ListExport.parseJSON(data)
        #expect(back.selections == l.items && back.markers == [m])
    }
}

@Suite struct BatchPlanTests {
    private func fs() -> FakeFileSystem { let f = FakeFileSystem(); f.directories.insert("/Out"); f.put("/In/lecture.mp4", "x"); return f }
    private func sels(_ names: [String]) -> [ClipSelection] {
        names.enumerated().map { ClipSelection(name: $1, start: t(Double($0) * 10), end: t(Double($0) * 10 + 5)) }
    }

    @Test func namesUseTemplateAndAreZeroPadded() {
        let plan = BatchPlan.make(selections: sels(["Intro", "Q&A"]), sourcePath: "/In/lecture.mp4", folder: "/Out", fileExtension: "mp4",
                                  template: .default, fs: fs(), estimatedBytesPerSecond: 100)
        #expect(plan.outputs.map(\.name) == ["lecture - 01 - Intro", "lecture - 02 - Q&A"])
        #expect(plan.outputs.map(\.path) == ["/Out/lecture - 01 - Intro.mp4", "/Out/lecture - 02 - Q&A.mp4"])
        #expect(plan.canRun)
    }

    @Test func duplicateNamesInOneBatchGetNumbers() {
        let plan = BatchPlan.make(selections: sels(["Same", "same"]), sourcePath: "/In/l.mp4", folder: "/Out", fileExtension: "mp4",
                                  template: NamingTemplate(pattern: "{name}"), fs: fs(), estimatedBytesPerSecond: 1)
        #expect(plan.outputs.map(\.name) == ["Same", "same 2"], "case-insensitive: APFS would collide them")
        #expect(plan.renamedForConflict == ["same 2"])
    }

    @Test func existingFilesAreNeverOverwritten() {
        let f = fs(); f.put("/Out/Intro.mp4", "precious")
        let plan = BatchPlan.make(selections: sels(["Intro"]), sourcePath: "/In/l.mp4", folder: "/Out", fileExtension: "mp4",
                                  template: NamingTemplate(pattern: "{name}"), fs: f, estimatedBytesPerSecond: 1)
        #expect(plan.outputs[0].path == "/Out/Intro 2.mp4")
    }

    @Test func unsafeCharactersAndLongNamesAreCleaned() {
        #expect(NamingTemplate.sanitize("a/b:c*d?e") == "a b c d e")
        #expect(NamingTemplate.sanitize("  ..hidden.. ") == "hidden")
        let long = String(repeating: "ệ", count: 300)
        #expect(NamingTemplate.sanitize(long).utf8.count <= 200)
        #expect(NamingTemplate(pattern: "{name}").render(source: "s", name: "///", index: 1, total: 1, start: .zero, date: Date()) == "s", "empty result falls back to the source name")
    }

    @Test func timecodeAndDateTokens() {
        let n = NamingTemplate(pattern: "{source}_{timecode}_{date}")
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let out = n.render(source: "talk", name: "x", index: 1, total: 1, start: MediaTime(seconds: 3725), date: d)
        #expect(out.hasPrefix("talk_01-02-05_2023-11-1"))
    }

    @Test func problemsAreReportedBeforeAnythingRuns() {
        let f = fs()
        let missing = BatchPlan.make(selections: sels(["A"]), sourcePath: "/In/l.mp4", folder: "/Nope", fileExtension: "mp4", template: .default, fs: f, estimatedBytesPerSecond: 1)
        #expect(missing.issues.map(\.kind) == [.folderMissing] && !missing.canRun)
        f.unwritable.insert("/Out")
        let ro = BatchPlan.make(selections: sels(["A"]), sourcePath: "/In/l.mp4", folder: "/Out", fileExtension: "mp4", template: .default, fs: f, estimatedBytesPerSecond: 1)
        #expect(ro.issues.map(\.kind) == [.folderNotWritable])
        f.unwritable = []; f.free = 100
        let full = BatchPlan.make(selections: sels(["A", "B"]), sourcePath: "/In/l.mp4", folder: "/Out", fileExtension: "mp4", template: .default, fs: f, estimatedBytesPerSecond: 1000)
        if case .notEnoughSpace = full.issues.first?.kind {} else { Issue.record("expected notEnoughSpace") }
        let empty = BatchPlan.make(selections: [], sourcePath: "/In/l.mp4", folder: "/Out", fileExtension: "mp4", template: .default, fs: f, estimatedBytesPerSecond: 1)
        #expect(empty.issues.map(\.kind) == [.emptySelection])
    }

    @Test func outputCannotLandOnTheSource() {
        let f = fs(); f.directories.insert("/In")
        let plan = BatchPlan.make(selections: sels(["x"]), sourcePath: "/In/lecture.mp4", folder: "/In", fileExtension: "mp4",
                                  template: NamingTemplate(pattern: "lecture"), fs: f, estimatedBytesPerSecond: 1)
        // "lecture.mp4" exists, so the plan picks "lecture 2.mp4": the source is safe either way.
        #expect(plan.outputs[0].path == "/In/lecture 2.mp4" && plan.canRun)
    }
}

@Suite struct CenterSampledTests {
    @Test func gridLengthIsExactAndTheSourceMovesHalfAFrame() {
        let fr = FrameRate(numerator: 30000, denominator: 1001)
        let d = MediaTime(seconds: 10, timescale: 600)
        let span = TimeSpan(start: .frameStart(index: 30, frameRate: fr), end: .frameStart(index: 70, frameRate: fr))
        let c = CutPlanning.centerSampled(span, frameRate: fr, duration: d)
        #expect(c.length == span.duration, "40 frames stay 40 frames on the output grid")
        #expect(c.source.start > span.start && c.source.start < .frameStart(index: 31, frameRate: fr), "aimed at the middle of frame 30")
    }

    @Test func aSpanThatIsAFewHundredthsOfAFrameLongStillHasWholeFrames() {
        // Real files round their frame times (to 1/600 s or a millisecond), so 240 frames can measure 240.05 frames.
        let fr = FrameRate(numerator: 30, denominator: 1)
        let d = MediaTime(seconds: 60, timescale: 600)
        let start = MediaTime(seconds: 9.96833, timescale: 60000)
        for (extra, expected) in [(0.0, 240), (0.05, 240), (-0.05, 240), (0.4, 240), (0.6, 241)] as [(Double, Int)] {
            let span = TimeSpan(start: start, end: start + MediaTime(seconds: (240 + extra) / 30, timescale: 60000))
            let c = CutPlanning.centerSampled(span, frameRate: fr, duration: d)
            #expect(c.length == MediaTime(value: Int64(expected), timescale: 30), "240 + \(extra) frames is \(expected) frames")
        }
        // 29.97 fps, the real-world case: 240 frames spaced by the ms-rounded times of a phone file.
        let ntsc = FrameRate(numerator: 30000, denominator: 1001)
        let c = CutPlanning.centerSampled(TimeSpan(start: MediaTime(seconds: 9.98, timescale: 1000), end: MediaTime(seconds: 17.99, timescale: 1000)), frameRate: ntsc, duration: d)
        #expect(c.length == MediaTime(value: 240 * 1001, timescale: 30000), "8.01 s at 29.97 fps is 240 frames, not 241")
        // Never less than one frame.
        #expect(CutPlanning.centerSampled(TimeSpan(start: .zero, end: MediaTime(seconds: 0.001, timescale: 1000)), frameRate: fr, duration: d).length == MediaTime(value: 1, timescale: 30))
    }

    @Test func nearTheEndTheSourceRangeIsClampedButTheGridLengthIsKept() {
        let d = MediaTime(seconds: 4, timescale: 600)
        let c = CutPlanning.centerSampled(TimeSpan(start: MediaTime(seconds: 3), end: d), frameRate: FrameRate(numerator: 30, denominator: 1), duration: d)
        #expect(c.source.end == d && c.length == MediaTime(seconds: 1, timescale: 600))
    }
}
