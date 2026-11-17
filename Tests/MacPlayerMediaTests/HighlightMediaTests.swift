import AVFoundation
import Foundation
import Testing
@testable import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct HighlightMediaTests {
    /// A 6 s, 10 fps, 160×90 video: a still grey picture, except for a white block running across between 3 and 4 s.
    private func actionVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl-\(UUID().uuidString).mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        w.add(input)
        #expect(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for f in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            let b = try #require(pb)
            CVPixelBufferLockBaseAddress(b, [])
            let row = CVPixelBufferGetBytesPerRow(b), p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            let t = Double(f) / 10
            let x0 = t >= 3 && t < 4 ? Int((t - 3) * 10) * 14 : -100
            for y in 0..<90 { for x in 0..<160 {
                let v: UInt8 = (x >= x0 && x < x0 + 40 && y > 20 && y < 70) ? 250 : 90
                let o = y * row + x * 4; p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(b, [])
            ad.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 10))
        }
        input.markAsFinished()
        await w.finishWriting()
        return url
    }

    @Test func movementIsMeasuredWhereItHappens() async throws {
        let url = try await actionVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        HighlightAnalyzer.detector = { _ in [CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6)] }
        defer { HighlightAnalyzer.detector = nil }
        let s = try await HighlightAnalyzer.signals(url: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 6)), step: 0.2)
        #expect(abs(s.count - 30) <= 1, "one sample every 0.2 s: \(s.count)")
        let inside = (0..<s.count).filter { s.time($0) > 3.05 && s.time($0) < 4.05 }.map { s.motion[$0] }
        let outside = (0..<s.count).filter { s.time($0) < 2.8 || s.time($0) > 4.4 }.map { s.motion[$0] }
        #expect((inside.min() ?? 0) > 0.02 && (outside.max() ?? 1) < 0.005, "inside \(inside) outside \(outside)")
        #expect(s.people.compactMap { $0 }.count >= 5 && s.people.compactMap { $0 }.allSatisfy { abs($0 - 0.12) < 0.001 }, "looked for people about once a second")
        #expect(s.loudness.isEmpty, "no sound track")
        let m = HighlightFinder.moments(s)
        #expect(m.first.map { $0.start < 3.2 && $0.end > 3.8 } == true, "the moment is the running block: \(m)")
    }

    @Test func aSpanEndingAHairAfterTheFileStillReads() async throws {
        let url = try await actionVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        // 6 s of video; the clip's end rounded up past it (as a real 86-minute match's clip was: -11841 before the fix).
        let s = try await HighlightAnalyzer.signals(url: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 6.0017)), step: 0.2)
        #expect(abs(s.count - 30) <= 1)
    }

    @Test func stoppingTheSearchStopsIt() async throws {
        let url = try await actionVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await HighlightAnalyzer.signals(url: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 6))) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// With MACPLAYER_HIGHLIGHT_FILES="path|…": the moments found in real videos (read only), printed (not a check). With
    /// MACPLAYER_HIGHLIGHT_OUT=<file>, also written as "file<TAB>start<TAB>end<TAB>score" lines to look at the pictures.
    @Test func momentsInRealVideos() async throws {
        guard let list = ProcessInfo.processInfo.environment["MACPLAYER_HIGHLIGHT_FILES"] else { return }
        var lines: [String] = []
        for path in list.split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let dur = try await AVURLAsset(url: url).load(.duration).seconds
            let t0 = Date()
            // MACPLAYER_HIGHLIGHT_SPAN="a-b": only that part (seconds), as a clip trimmed to it would be.
            let span = ProcessInfo.processInfo.environment["MACPLAYER_HIGHLIGHT_SPAN"]?.split(separator: "-").compactMap { Double($0) }
            let s = try await HighlightAnalyzer.signals(url: url, span: TimeSpan(start: MediaTime(seconds: span?.first ?? 0), end: MediaTime(seconds: span?.last ?? dur)))
            let took = Date().timeIntervalSince(t0)
            let m = HighlightFinder.moments(s)
            let cuts = HighlightFinder.cuts(motion: s.motion).count
            let looks = s.people.compactMap { $0 }, withPeople = looks.filter { $0 > 0.002 }.count
            print(String(format: "HIGHLIGHT %@ %.0fs in %.1fs: %d samples, %d cuts, people in %d/%d looks, sound %@ → %d moments, %.0fs",
                         String(url.lastPathComponent.prefix(24)), dur, took, s.count, cuts, withPeople, looks.count, s.loudness.isEmpty ? "none" : "yes",
                         m.count, m.reduce(0) { $0 + $1.end - $1.start }))
            print("GOALS", s.goals.map { String(format: "%@ %.0f(old seen %.0f)", $0.label, $0.firstNew, $0.lastOld) }.joined(separator: " "))
            print("PERIODS", s.periods.map { String(format: "%.0f–%.0f", $0.kickoff, $0.end) }.joined(separator: " "), "MARKS", s.marks.map { "\($0.kind.rawValue)@\(Int($0.time))" })
            print("LINEUPS", s.lineups.map { String(Int($0)) }.joined(separator: " "))
            print("EVENTS", m.filter { $0.event != nil }.sorted { $0.start < $1.start }.map { String(format: "%@ %.0f–%.0f", $0.event!.rawValue, $0.start, $0.end) }.joined(separator: " | "))
            print("MOMENTS", m.prefix(12).map { String(format: "%.1f–%.1f(%.2f)", $0.start, $0.end, $0.score) }.joined(separator: " "))
            if let dump = ProcessInfo.processInfo.environment["MACPLAYER_HIGHLIGHT_DUMP"] {
                // Every sample: time, motion, sound, people (−1 = not looked), person speed, score (for measuring by hand).
                let sc = HighlightFinder.scores(s)
                let rows = (0..<s.count).map { i in String(format: "%.1f\t%.4f\t%.1f\t%.4f\t%.3f\t%.2f", s.time(i), s.motion[i], s.loudness.isEmpty ? 0 : s.loudness[i], s.people[i] ?? -1, s.personSpeed[i], sc[i]) }
                try rows.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
                try s.thumbs.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "\n").write(toFile: dump + ".thumbs", atomically: true, encoding: .utf8)
            }
            lines += m.map { "\(path)\t\($0.start)\t\($0.end)\t\($0.score)" }
        }
        if let out = ProcessInfo.processInfo.environment["MACPLAYER_HIGHLIGHT_OUT"] { try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
