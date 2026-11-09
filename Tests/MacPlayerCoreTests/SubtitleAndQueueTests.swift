import Foundation
import Testing
@testable import MacPlayerCore

private func t(_ s: Double) -> MediaTime { MediaTime(seconds: s, timescale: 1000) }

private let srt = """
1
00:00:01,000 --> 00:00:03,500
Xin chào các bạn
Hôm nay học tiếng Việt

2
00:00:04,000 --> 00:00:06,000
<i>Dòng hai</i>

"""

/// Encodes like old Vietnamese subtitle tools: Windows-1258 keeps some letters precomposed (ê, ă, ơ...) and writes tone
/// marks as separate combining characters, so "ế" is "ê" followed by an acute accent.
private func encodeWindows1258(_ s: String) -> Data? {
    let enc = SubtitleCodec.vietnameseWindows
    var out = Data()
    for ch in s {
        var scalars = Array(String(ch).decomposedStringWithCanonicalMapping.unicodeScalars)
        var cur = String(Character(scalars.removeFirst()))
        // Fold in whichever marks make a letter the code page has precomposed (e + circumflex = ê); the rest stay separate.
        var folded = true
        while folded {
            folded = false
            for (i, m) in scalars.enumerated() {
                let candidate = (cur + String(Character(m))).precomposedStringWithCanonicalMapping
                if candidate.data(using: enc) != nil { cur = candidate; scalars.remove(at: i); folded = true; break }
            }
        }
        guard let head = cur.data(using: enc) else { return nil }
        out.append(head)
        for m in scalars { guard let d = String(Character(m)).data(using: enc) else { return nil }; out.append(d) }
    }
    return out
}

@Suite struct SubtitleTests {
    @Test func parsesSRTWithMultiLineVietnamese() throws {
        let r = try SubtitleCodec.parse(srt)
        #expect(r.cues.count == 2 && r.warnings.isEmpty)
        #expect(r.cues[0].text == "Xin chào các bạn\nHôm nay học tiếng Việt")
        #expect(r.cues[0].start.seconds == 1 && r.cues[0].end.seconds == 3.5)
        #expect(r.cues[1].plainText == "Dòng hai")
    }

    @Test func parsesWindowsLineEndingsAndMissingIndexes() throws {
        let text = "00:00:01,000 --> 00:00:02,000\r\nA\r\n\r\n00:00:03,000 --> 00:00:04,000\r\nB\r\n"
        let r = try SubtitleCodec.parse(text)
        #expect(r.cues.map(\.text) == ["A", "B"])
    }

    @Test func parsesWebVTTWithHeaderNotesAndShortTimestamps() throws {
        let vtt = "WEBVTT\n\nNOTE a comment\n\nintro\n00:01.000 --> 00:02.500 align:start\nHello\n\n01:00:00.000 --> 01:00:01.000\nHour\n"
        let r = try SubtitleCodec.parse(vtt)
        #expect(r.cues.count == 2 && r.cues[0].end.seconds == 2.5 && r.cues[1].start.seconds == 3600)
    }

    @Test func badBlocksAreSkippedWithAWarning() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nok\n\n2\n99:99:99 --> nonsense\nbad\n\n3\n00:00:05,000 --> 00:00:06,000\nok2\n"
        let r = try SubtitleCodec.parse(text)
        #expect(r.cues.map(\.text) == ["ok", "ok2"] && r.warnings.count == 1)
    }

    @Test func nonSubtitleTextThrows() {
        #expect(throws: SubtitleError.notSubtitleText) { try SubtitleCodec.parse("just some prose") }
        #expect(throws: SubtitleError.notSubtitleText) { try SubtitleCodec.parse("   ") }
        #expect(throws: SubtitleError.noCues) { try SubtitleCodec.parse("WEBVTT\n\n") }
    }

    @Test func writeThenReadGivesTheSameCues() throws {
        let cues = [SubtitleCue(start: t(1.001), end: t(2.5), text: "Đây là thử nghiệm"), SubtitleCue(start: t(3725.25), end: t(3726), text: "Hai\ndòng")]
        for f in [SubtitleCodec.Format.srt, .vtt] {
            let back = try SubtitleCodec.parse(SubtitleCodec.serialize(cues, format: f)).cues
            #expect(back.map(\.text) == cues.map(\.text) && back.map(\.start) == cues.map(\.start) && back.map(\.end) == cues.map(\.end))
        }
        #expect(SubtitleCodec.serialize(cues, format: .srt).contains("01:02:05,250 --> 01:02:06,000"))
        #expect(SubtitleCodec.serialize(cues, format: .vtt).hasPrefix("WEBVTT\n\n"))
    }

    @Test func encodingsDecodeVietnameseCorrectly() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nTiếng Việt: ăâêôơư đ ạ ỳ ế ộ ệ\n"
        // UTF-8 with and without BOM, UTF-16, and the legacy Windows-1258 used by old Vietnamese subtitle tools.
        let utf8 = Data(text.utf8)
        #expect(SubtitleCodec.decode(utf8)?.text == text)
        #expect(SubtitleCodec.decode(Data([0xEF, 0xBB, 0xBF]) + utf8)?.text == text)
        #expect(SubtitleCodec.decode(try #require(text.data(using: .utf16)))?.text == text)
        let legacy = try #require(encodeWindows1258(text))
        let decoded = try #require(SubtitleCodec.decode(legacy))
        #expect(decoded.text == text && decoded.encoding.contains("1258"), "got \(decoded.encoding)")
        #expect(SubtitleCodec.decode(legacy, forcing: .utf8) == nil || SubtitleCodec.decode(legacy, forcing: .utf8)?.text != text)
    }

    @Test func issuesFlagOverlapEmptyAndOutOfRange() {
        var d = SubtitleDocument()
        d.cues = [SubtitleCue(start: t(0), end: t(5), text: "a"), SubtitleCue(start: t(4), end: t(6), text: "b"),
                  SubtitleCue(start: t(7), end: t(7), text: "c"), SubtitleCue(start: t(8), end: t(9), text: " "),
                  SubtitleCue(start: t(9), end: t(30), text: "late"), SubtitleCue(start: t(40), end: t(41), text: "beyond")]
        let kinds = d.issues(videoDuration: t(20)).map(\.kind)
        #expect(kinds.contains(.overlapsPrevious) && kinds.contains(.endsBeforeStart) && kinds.contains(.emptyText)
            && kinds.contains(.endsAfterVideoEnds) && kinds.contains(.startsAfterVideoEnds))
    }

    @Test func shiftKeepsLengthAndNeverGoesNegative() {
        var d = SubtitleDocument()
        d.cues = [SubtitleCue(start: t(1), end: t(3), text: "a"), SubtitleCue(start: t(10), end: t(11), text: "b")]
        d.shiftAll(by: 2.5)
        #expect(d.cues[0].start.seconds == 3.5 && d.cues[0].end.seconds == 5.5)
        d.shiftAll(by: -100)
        #expect(d.cues[0].start == .zero && (d.cues[0].end - d.cues[0].start).seconds == 2)
    }

    @Test func mergeSplitFindReplace() {
        var d = SubtitleDocument()
        d.cues = [SubtitleCue(start: t(0), end: t(2), text: "Một"), SubtitleCue(start: t(2), end: t(4), text: "Hai"), SubtitleCue(start: t(4), end: t(6), text: "Một hai ba")]
        let merged = d.merge(ids: Set(d.cues.prefix(2).map(\.id)))
        #expect(merged != nil && d.cues.count == 2 && d.cues[0].text == "Một\nHai" && d.cues[0].end.seconds == 4)
        let (a, b) = d.split(id: d.cues[1].id, at: t(5))!
        #expect(d.cues.first { $0.id == a }?.text == "Một hai" || d.cues.first { $0.id == a }?.text == "Một")
        #expect(d.cues.first { $0.id == b } != nil && d.cues.first { $0.id == a }!.end == t(5))
        #expect(d.split(id: d.cues[0].id, at: t(100)) == nil, "split time must be inside the cue")
        #expect(d.find("hai").count >= 1 && d.find("MOT").count >= 1, "search ignores case and accents")
        let n = d.replace("một", with: "Một (1)")
        #expect(n >= 1)
    }

    @Test func clipExportRebasesCuesToTheClipStart() {
        var d = SubtitleDocument()
        d.cues = [SubtitleCue(start: t(8), end: t(12), text: "straddles start"), SubtitleCue(start: t(15), end: t(16), text: "inside"), SubtitleCue(start: t(30), end: t(31), text: "outside")]
        let out = d.cues(in: TimeSpan(start: t(10), end: t(20)))
        #expect(out.map(\.text) == ["straddles start", "inside"])
        #expect(out[0].start == .zero && out[0].end.seconds == 2 && out[1].start.seconds == 5)
    }

    @Test func portraitStyleKeepsTextAboveTheAppButtons() {
        #expect(SubtitleStyle.portrait.bottomMargin > SubtitleStyle().bottomMargin)
    }
}

@Suite struct QueueTests {
    private func job(_ name: String, priority: Int = 0, at: Double = 0) -> ExportJob {
        ExportJob(label: name, pieces: [JobPiece(sourcePath: "/in.mp4", span: TimeSpan(start: .zero, end: t(5)))], options: ExportOptions(),
                  target: .newCopy(path: "/out/\(name).mp4", overwrite: false), priority: priority, now: Date(timeIntervalSince1970: at))
    }

    @Test func oldestFirstWithinPriorityAndConcurrencyLimit() {
        var q = ExportQueueModel(); q.maxConcurrent = 2
        q.enqueue([job("a", at: 1), job("b", at: 2), job("c", at: 3, ), job("urgent", priority: 5, at: 4)])
        #expect(q.nextToStart().map(\.label) == ["urgent", "a"])
        q.markRunning(q.jobs[0].id)
        #expect(q.nextToStart().count == 1, "one slot left")
    }

    @Test func oneFailureDoesNotStopTheRest() {
        var q = ExportQueueModel()
        q.enqueue([job("a"), job("b"), job("c")])
        q.markRunning(q.jobs[0].id); q.markFailed(q.jobs[0].id, message: "disk full")
        q.markRunning(q.jobs[1].id); q.markSucceeded(q.jobs[1].id, path: "/out/b.mp4")
        #expect(q.nextToStart().map(\.label) == ["c"])
        let s = q.summary
        #expect(s.succeeded == 1 && s.failed == 1 && s.remaining == 1)
    }

    @Test func cancelAndRetry() {
        var q = ExportQueueModel(); q.enqueue(job("a"))
        let id = q.jobs[0].id
        q.cancel(id)
        #expect(q.jobs[0].state == .cancelled && !q.hasWork)
        q.retry(id)
        #expect(q.jobs[0].state == .queued && q.hasWork)
        q.markSucceeded(id, path: "/x"); q.cancel(id)
        #expect(q.jobs[0].state == .succeeded(path: "/x"), "a finished job cannot be cancelled")
    }

    @Test func progressOnlyMovesForwardAndOnlyWhileRunning() {
        var q = ExportQueueModel(); q.enqueue(job("a"))
        let id = q.jobs[0].id
        q.setProgress(id, 0.5)
        #expect(q.jobs[0].progress == 0)
        q.markRunning(id); q.setProgress(id, 0.5); q.setProgress(id, 0.3)
        #expect(q.jobs[0].progress == 0.5)
    }

    @Test func restoreAfterCrashRequeuesRunningJobs() throws {
        let fs = FakeFileSystem()
        let store = QueueStore(fs: fs, path: "/q/queue.json")
        var q = ExportQueueModel(); q.enqueue([job("a"), job("b"), job("c")])
        q.markRunning(q.jobs[0].id); q.markSucceeded(q.jobs[1].id, path: "/out/b.mp4")
        try store.save(q)
        let back = store.load()
        #expect(back.jobs[0].state == .queued && back.jobs[0].restoredAfterCrash)
        #expect(back.jobs[1].state == .succeeded(path: "/out/b.mp4"), "finished work is not redone")
        #expect(back.jobs[2].state == .queued && !back.jobs[2].restoredAfterCrash)
    }

    @Test func damagedQueueFileIsSetAsideNotDeleted() throws {
        let fs = FakeFileSystem()
        fs.put("/q/queue.json", "{ broken")
        let q = QueueStore(fs: fs, path: "/q/queue.json").load()
        #expect(q.jobs.isEmpty)
        #expect(fs.files.keys.contains { $0.contains("queue.json.damaged-") })
    }

    @Test func removeFinishedKeepsRunningAndQueued() {
        var q = ExportQueueModel(); q.enqueue([job("a"), job("b"), job("c")])
        q.markRunning(q.jobs[0].id); q.markSucceeded(q.jobs[1].id, path: "/x")
        q.removeFinished()
        #expect(q.jobs.map(\.label) == ["a", "c"])
        q.remove(q.jobs[0].id)
        #expect(q.jobs.map(\.label) == ["a", "c"], "a running job cannot be removed")
    }
}

@Suite struct PreferencesTests {
    final class Dict: PreferenceStoring {
        var d: [String: Any] = [:]
        func object(forKey key: String) -> Any? { d[key] }
        func set(_ value: Any?, forKey key: String) { d[key] = value }
    }

    @Test func safeDefaults() {
        let p = AppPreferences(store: Dict())
        #expect(p.defaultSave == .newCopy && p.backupBeforeReplace && !p.telemetryEnabled && p.rememberPositions && p.autosaveEnabled)
        #expect(p.copySuffix == "-edited" && p.skipSeconds == 5)
    }

    @Test func valuesRoundTripAndAreClamped() {
        let p = AppPreferences(store: Dict())
        p.maxConcurrentExports = 99; p.skipSeconds = -4; p.resumeBehavior = .always
        #expect(p.maxConcurrentExports == 4 && p.skipSeconds == 0.1 && p.resumeBehavior == .always)
    }

    @Test func positionsAreRememberedPersistedCappedAndClearable() throws {
        let fs = FakeFileSystem()
        let s = PositionStore(fs: fs, path: "/pos.json", limit: 3)
        let k = PositionStore.key(path: "/a.mp4", size: 10)
        s.remember(k, seconds: 120, duration: 600)
        s.remember(PositionStore.key(path: "/early.mp4", size: 1), seconds: 1, duration: 600)
        s.remember(PositionStore.key(path: "/end.mp4", size: 1), seconds: 598, duration: 600)
        #expect(s.count == 1, "the first seconds and the last seconds are not worth resuming")
        s.flush()
        #expect(PositionStore(fs: fs, path: "/pos.json").position(for: k) == 120)
        #expect(s.position(for: PositionStore.key(path: "/a.mp4", size: 11)) == nil, "a different file at the same path does not resume")
        for i in 0..<5 { s.remember(PositionStore.key(path: "/f\(i).mp4", size: 1), seconds: 50, duration: 600) }
        #expect(s.count == 3)
        s.clear()
        #expect(s.count == 0 && PositionStore(fs: fs, path: "/pos.json").count == 0)
    }
}
