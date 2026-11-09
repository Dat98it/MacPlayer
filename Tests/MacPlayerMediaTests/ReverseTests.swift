import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct ReverseTests {
    private func index(of url: URL, at seconds: Double) async throws -> Int {
        let img = try await FrameGrabber.image(url: url, at: MediaTime(seconds: seconds, timescale: 600), accuracy: .exact)
        return try #require(FrameGrabber.syntheticIndex(of: img), "frame number at \(seconds) s")
    }

    @Test func aReversedClipPlaysItsFramesBackwardsAndKeepsItsLength() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 3, gop: 30))            // 90 frames, numbered 0...89
        let out = Fixtures.shared.outputURL("reversed-all")
        try await ReverseRenderer.reverse(source: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)), to: out)
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 3) < 0.15, "length \(info.duration.seconds)")
        #expect(info.hasAudio && info.hasVideo, "picture and sound")
        let first = try await index(of: out, at: 0), mid = try await index(of: out, at: 1.5), late = try await index(of: out, at: 2.5)
        #expect(first >= 84, "the first frame played is the last of the source: \(first)")
        #expect(abs(mid - 44) <= 4, "half way through is half way back: \(mid)")
        #expect(late < first && late <= 20, "and it keeps going backwards: \(late)")
    }

    @Test func aPartOfAClipCanBeReversed() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))
        let out = Fixtures.shared.outputURL("reversed-part")
        try await ReverseRenderer.reverse(source: src, span: TimeSpan(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2.5)), to: out)
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 1.5) < 0.15, "length \(info.duration.seconds)")
        let first = try await index(of: out, at: 0)
        #expect(abs(first - 74) <= 3, "starts at the end of the part (frame 74): \(first)")
    }

    @Test func theSoundIsReversedToo() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 3, gop: 30))
        let out = Fixtures.shared.outputURL("reversed-sound")
        try await ReverseRenderer.reverse(source: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)), to: out)
        let a = try #require(await AudioEnvelope.read(src)), b = try #require(await AudioEnvelope.read(out))
        #expect(abs(a.seconds - b.seconds) < 0.2, "the same length of sound")
        let flipped = Array(a.bins.reversed())
        let n = min(flipped.count, b.bins.count)
        // the loudness curve of the reversed sound follows the source's, backwards
        if let lag = AudioEnvelope.align(Array(flipped.prefix(n)), Array(b.bins.prefix(n)), maxLagBins: 20) { #expect(lag.correlation > 0.7, "correlation \(lag.correlation)") }
    }

    @Test func aTooLongPartIsRefusedBeforeAnythingIsWritten() async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("reversed-too-long")
        do {
            try await ReverseRenderer.reverse(source: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 400)), to: out)
            Issue.record("should have been refused")
        } catch let e as ReverseRenderer.ReverseError { if case .tooLong = e {} else { Issue.record("wrong error \(e)") } }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
