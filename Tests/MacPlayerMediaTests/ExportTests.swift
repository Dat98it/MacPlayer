import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct CutAccuracyTests {
    @Test(arguments: [CutMode.fast, CutMode.exact])
    func cutKeepsExactlyTheChosenFrames(mode: CutMode) async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("cut-\(mode.rawValue)")
        try await ClipExporter().export(source: src, spans: [span30(35, 85)], to: out, options: ExportOptions(mode: mode))
        let frames = try await FrameScanner.scanVideo(url: out)
        let idx = frames.compactMap(\.index)
        #expect(idx.first == 35 && idx.last == 84 && idx.count == 50, "mode \(mode): got \(idx.first ?? -1)...\(idx.last ?? -1) (\(idx.count))")
        #expect(zip(idx, idx.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }

    @Test func audioStaysWithinOneFrameOfTheVideo() async throws {
        let src = try await Fixtures.shared.source()
        for mode in [CutMode.fast, .exact] {
            let out = Fixtures.shared.outputURL("sync-\(mode.rawValue)")
            try await ClipExporter().export(source: src, spans: [span30(20, 110)], to: out, options: ExportOptions(mode: mode))
            let frames = try await FrameScanner.scanVideo(url: out)
            let onsets = try await FrameScanner.beepOnsets(url: out)
            var worst = 0.0, pairs = 0
            for o in onsets {
                if let f = frames.first(where: { ($0.index ?? 1) % 30 == 0 && abs($0.time.seconds - o.seconds) < 0.5 }) {
                    worst = max(worst, abs(o.seconds - f.time.seconds)); pairs += 1
                }
            }
            #expect(pairs >= 2, "need beep/frame pairs to measure (mode \(mode))")
            #expect(worst < 1.0 / 30, "A/V offset \(worst * 1000) ms in \(mode) mode exceeds one frame")
        }
    }

    @Test func fastCutCopiesTheStreamAndExactCutReencodesIt() async throws {
        let src = try await Fixtures.shared.source()
        let fast = Fixtures.shared.outputURL("fast"), exact = Fixtures.shared.outputURL("exact")
        try await ClipExporter().export(source: src, spans: [span30(35, 85)], to: fast, options: ExportOptions(mode: .fast))
        try await ClipExporter().export(source: src, spans: [span30(35, 85)], to: exact, options: ExportOptions(mode: .exact))
        let f = try #require(try await SampleInspector.inspect(url: fast)), e = try #require(try await SampleInspector.inspect(url: exact))
        #expect(f.sampleCount > e.sampleCount - 8 && f.totalBytes != e.totalBytes, "the two paths must not produce the same bytes")
        // The fast file keeps the frames from the previous keyframe (hidden by an edit list): more samples than shown frames.
        #expect(f.sampleCount > 50, "fast cut keeps lead-in frames: \(f.sampleCount) samples for 50 frames")
        #expect(f.timeMappings.first.map { $0.source > 0 } == true, "an edit list starts the picture after the lead-in")
    }

    @Test func variableFrameRateSourceStillCutsOnRealFrames() async throws {
        var spec = SyntheticMedia.Spec()
        spec.width = 320; spec.height = 180; spec.seconds = 3; spec.dropEveryNthFrame = 7
        let src = Fixtures.shared.outputURL("vfr")
        try await SyntheticMedia.generate(to: src, spec: spec)
        let all = try await FrameScanner.scanVideo(url: src).compactMap(\.index)
        #expect(all.count < 90, "frames were dropped so timing is irregular")
        let out = Fixtures.shared.outputURL("vfr-cut")
        try await ClipExporter().export(source: src, spans: [span30(30, 60)], to: out, options: ExportOptions(mode: .exact))
        let got = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        let expected = all.filter { $0 >= 30 && $0 < 60 }
        #expect(got == expected, "VFR: expected \(expected.count) frames, got \(got.count)")
    }

    @Test(arguments: [CutMode.fast, CutMode.exact])
    func aVideoWithoutSoundCutsInBothModes(mode: CutMode) async throws {
        // Regression: an empty audio track made the fast cut fail ("The operation could not be completed").
        let src = try await Fixtures.shared.source(.init(audio: false))
        let out = Fixtures.shared.outputURL("nosound-\(mode.rawValue)")
        try await ClipExporter().export(source: src, spans: [span30(30, 70)], to: out, options: ExportOptions(mode: mode))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx.first == 30 && idx.last == 69 && idx.count == 40)
        #expect(try await MediaProbe.probe(url: out).hasAudio == false)
    }

    @Test func rotatedPhoneVideoKeepsItsOrientation() async throws {
        let src = try await Fixtures.shared.source(.init(rotation: 90))
        let info = try await MediaProbe.probe(url: src)
        #expect(info.primaryVideo?.rotation == 90 && info.primaryVideo!.height > info.primaryVideo!.width, "display size is portrait")
        for mode in [CutMode.fast, .exact] {
            let out = Fixtures.shared.outputURL("rot-\(mode.rawValue)")
            try await ClipExporter().export(source: src, spans: [span30(10, 40)], to: out, options: ExportOptions(mode: mode))
            let o = try await MediaProbe.probe(url: out)
            #expect(o.primaryVideo?.rotation == 90 && o.primaryVideo!.height > o.primaryVideo!.width, "\(mode) lost the rotation")
        }
    }

    @Test func longerGOPSourceStillCutsExactly() async throws {
        let src = try await Fixtures.shared.source(.init(gop: 90))
        let out = Fixtures.shared.outputURL("gop")
        try await ClipExporter().export(source: src, spans: [span30(50, 70)], to: out, options: ExportOptions(mode: .exact))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx.first == 50 && idx.last == 69 && idx.count == 20)
    }

    @Test func hevcInMovAndMp4Cut() async throws {
        for container in [SyntheticMedia.Container.mov, .mp4] {
            let src = try await Fixtures.shared.source(.init(container: container, codec: .hevc))
            let out = Fixtures.shared.outputURL("hevc", ext: container.rawValue)
            try await ClipExporter().export(source: src, spans: [span30(15, 45)], to: out, options: ExportOptions(mode: .exact, container: OutputContainer(rawValue: container.rawValue)!, codec: .hevc))
            let o = try await MediaProbe.probe(url: out)
            #expect(o.primaryVideo?.codec == "hvc1")
            #expect(try await FrameScanner.scanVideo(url: out).compactMap(\.index).count == 30)
        }
    }

    @Test func multipleRangesJoinInOrder() async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("join")
        try await ClipExporter().export(source: src, spans: [span30(60, 70), span30(10, 20)], to: out, options: ExportOptions(mode: .exact))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx == Array(60..<70) + Array(10..<20))
    }

    @Test func twoDifferentSourcesJoinIntoOneFile() async throws {
        let a = try await Fixtures.shared.source()
        let b = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        let out = Fixtures.shared.outputURL("two-sources")
        let pieces = [RenderPiece(sourceURL: a, span: span30(0, 30)), RenderPiece(sourceURL: b, span: span30(60, 90))]
        try await RenderExporter().export(pieces: pieces, to: out, options: ExportOptions(mode: .exact))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx == Array(0..<30) + Array(60..<90))
    }

    @Test func resolutionLimitScalesDownNeverUp() async throws {
        let big = try await Fixtures.shared.source(.init(seconds: 1, width: 1280, height: 720))
        let down = Fixtures.shared.outputURL("down")
        try await ClipExporter().export(source: big, spans: [span30(0, 20)], to: down, options: ExportOptions(mode: .exact, resolution: .p480))
        let d = try await MediaProbe.probe(url: down)
        #expect(d.primaryVideo?.height == 480 && d.primaryVideo?.width == 854, "720p limited to 480p keeps the aspect: \(d.primaryVideo?.width ?? 0)x\(d.primaryVideo?.height ?? 0)")
        let small = try await Fixtures.shared.source()
        let same = Fixtures.shared.outputURL("noup")
        try await ClipExporter().export(source: small, spans: [span30(0, 20)], to: same, options: ExportOptions(mode: .exact, resolution: .p480))
        #expect(try await MediaProbe.probe(url: same).primaryVideo?.height == 180, "a 180p source is not enlarged to 480p")
    }

    @Test func fastCutRefusesEditsThatNeedRendering() async throws {
        let src = try await Fixtures.shared.source()
        var recipe = RenderRecipe(); recipe.look.rotation = 90
        await #expect(throws: ExportError.self) {
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 30), look: recipe.look)], recipe: recipe,
                                              to: Fixtures.shared.outputURL("nofast"), options: ExportOptions(mode: .fast))
        }
    }

    @Test func existingDestinationIsNeverOverwrittenByTheExporter() async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("exists")
        try Data("precious".utf8).write(to: out)
        await #expect(throws: ExportError.self) { try await ClipExporter().export(source: src, spans: [span30(0, 30)], to: out, options: ExportOptions()) }
        #expect(try String(contentsOf: out, encoding: .utf8) == "precious")
    }

    @Test func cancelStopsQuicklyAndLeavesNoFile() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4))
        let out = Fixtures.shared.outputURL("cancel")
        let started = Date()
        let task = Task { try await ClipExporter().export(source: src, spans: [TimeSpan(start: .zero, end: MediaTime(seconds: 4))], to: out, options: ExportOptions(mode: .exact)) }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        do { try await task.value; Issue.record("expected a cancellation error") }
        catch let e as ExportError { #expect(e == .cancelled) }
        catch { Issue.record("unexpected error \(error)") }
        #expect(Date().timeIntervalSince(started) < 5, "cancel must release workers within 5 s")
        #expect(!FileManager.default.fileExists(atPath: out.path), "no partial file may look like a result")
    }
}
