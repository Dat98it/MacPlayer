import AVFoundation
import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Regression tests for the faults found by running the app on real footage (0.7.1).
@Suite(.serialized) struct RegressionFixesTests {
    // MARK: The sound encoder accepts the rates real videos use

    @Test func everySampleRateGetsABitRateTheEncoderAccepts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        for rate in [8_000.0, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000] {
            for channels in [1, 2] {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                               AVEncoderBitRateKey: AACSettings.bitRate(sampleRate: rate, channels: channels)]
                let writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("aac-check-\(UUID().uuidString.prefix(6)).m4a"), fileType: .m4a)
                #expect(writer.canApply(outputSettings: settings, forMediaType: .audio), "\(Int(rate)) Hz, \(channels) channel(s), \(settings[AVEncoderBitRateKey]!) bit/s")
            }
        }
    }

    @Test func anExactCutOfAVideoWithLowRateSoundIsWritten() async throws {
        let src = Fixtures.shared.root.appendingPathComponent("lowrate-\(UUID().uuidString.prefix(6)).mp4")
        var spec = SyntheticMedia.Spec(); spec.width = 320; spec.height = 180; spec.seconds = 3; spec.audioSampleRate = 22_050
        try await SyntheticMedia.generate(to: src, spec: spec)
        let out = Fixtures.shared.outputURL("lowrate-cut")
        var options = ExportOptions(); options.mode = .exact
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 60))], to: out, options: options)
        let info = try await MediaProbe.probe(url: out)
        #expect(info.hasAudio && abs(info.duration.seconds - 2) < 0.2)
    }

    // MARK: The messages that name a language or an error really name it

    @Test func speechMessagesInterpolate() {
        #expect(SpeechTranscriber.SpeechError.notOnDevice("vi-VN").description.contains("vi-VN"))
        #expect(SpeechTranscriber.SpeechError.failed("boom").description.contains("boom"))
        #expect(!SpeechTranscriber.SpeechError.failed("boom").description.contains("\\("))
    }

    // MARK: A mask sits on the picture, not on the frame, when the picture has bars

    private func rgba(_ ci: CIImage) -> Pixels { Pixels(PhotoRenderer.cgImage(ci, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!) }
    private func litBox(_ p: Pixels) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var b = (minX: Int.max, maxX: -1, minY: Int.max, maxY: -1)
        for y in 0..<p.height { for x in 0..<p.width where p.luma(x, y) > 25 { b = (min(b.minX, x), max(b.maxX, x), min(b.minY, y), max(b.maxY, y)) } }
        return b.maxX < 0 ? nil : b
    }
    private var wide: CIImage { CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)) }

    @Test func aShapeMaskIsCentredOnAPictureWithBarsAbove() {
        var look = VideoLook(); look.canvas = .portrait9x16; look.fit = .fit
        let plain = rgba(PhotoRenderer.render(base: wide, look: look, overlays: []))
        var m = MaskSpec(shape: .ellipse); m.width = 0.5; m.height = 0.5; m.feather = 0
        look.mask = m
        let masked = rgba(PhotoRenderer.render(base: wide, look: look, overlays: []))
        let pic = litBox(plain)!, kept = litBox(masked)!
        #expect(masked.luma(masked.width / 2, masked.height / 2) > 200, "the middle of the picture shows through the middle of the shape")
        #expect(abs(Double(kept.minX + kept.maxX) / 2 - Double(pic.minX + pic.maxX) / 2) < 3)
        #expect(abs(Double(kept.minY + kept.maxY) / 2 - Double(pic.minY + pic.maxY) / 2) < 3, "and it is not pushed up or down by the bars")
    }

    @Test func aShapeMaskIsCentredOnAPictureWithBarsAtTheSides() {
        var look = VideoLook(); look.canvas = .square1x1; look.fit = .fit
        let tall = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 180, height: 320))
        let plain = rgba(PhotoRenderer.render(base: tall, look: look, overlays: []))
        var m = MaskSpec(shape: .ellipse); m.width = 0.5; m.height = 0.5; m.feather = 0
        look.mask = m
        let masked = rgba(PhotoRenderer.render(base: tall, look: look, overlays: []))
        let pic = litBox(plain)!, kept = litBox(masked)!
        #expect(abs(Double(kept.minX + kept.maxX) / 2 - Double(pic.minX + pic.maxX) / 2) < 3, "centred sideways: \(kept) in \(pic)")
        #expect(abs(Double(kept.minY + kept.maxY) / 2 - Double(pic.minY + pic.maxY) / 2) < 3)
    }

    @Test func aSubjectMaskStaysOnTheSubjectWhenThePictureHasBars() {
        // A made-up subject: the middle quarter of the upright picture.
        SubjectMasker.provider = { image, _ in
            let e = image.extent
            let box = CIImage(color: .white).cropped(to: CGRect(x: e.minX + e.width * 0.25, y: e.minY + e.height * 0.25, width: e.width * 0.5, height: e.height * 0.5))
            return box.composited(over: CIImage(color: .black).cropped(to: e))
        }
        defer { SubjectMasker.provider = nil }
        var plainLook = VideoLook(); plainLook.canvas = .portrait9x16; plainLook.fit = .fit
        var look = plainLook; look.isolateSubject = true
        let pic = litBox(rgba(PhotoRenderer.render(base: wide, look: plainLook, overlays: [])))!
        let kept = litBox(rgba(PhotoRenderer.render(base: wide, look: look, overlays: [])))
        #expect(kept != nil, "the subject is still there")
        if let kept {
            let w = Double(pic.maxX - pic.minX + 1), h = Double(pic.maxY - pic.minY + 1)
            #expect(abs(Double(kept.minX) - (Double(pic.minX) + w * 0.25)) < 3 && abs(Double(kept.maxX) - (Double(pic.minX) + w * 0.75)) < 3)
            #expect(abs(Double(kept.minY) - (Double(pic.minY) + h * 0.25)) < 3 && abs(Double(kept.maxY) - (Double(pic.minY) + h * 0.75)) < 3)
        }
    }

    // MARK: A delayed sound keeps up with a faster or slower clip

    private func audioPieces(_ built: BuiltRender) -> [(start: Double, end: Double, rate: Double)] {
        built.composition.tracks(withMediaType: .audio).flatMap { t in
            t.segments.filter { !$0.isEmpty }.map { s in
                (s.timeMapping.target.start.seconds, s.timeMapping.target.end.seconds, s.timeMapping.source.duration.seconds / max(1e-9, s.timeMapping.target.duration.seconds))
            }
        }
    }

    @Test(arguments: [(2.0, 1.0), (0.5, 0.5), (1.0, 0.5), (2.0, -0.5)])
    func theSoundOfAClipWithADelayPlaysAtTheClipsSpeed(speed: Double, offset: Double) async throws {
        let src = try await Fixtures.shared.source()
        var look = VideoLook(); look.speed = speed
        var audio = AudioSettings(); audio.offsetSeconds = offset
        let built = try await CompositionBuilder.build(pieces: [RenderPiece(sourceURL: src, span: span30(0, 90), look: look, audio: audio)], includeAudio: true, frameAccurate: true)
        let pieces = audioPieces(built)
        #expect(!pieces.isEmpty)
        for p in pieces { #expect(abs(p.rate - speed) < 0.05, "a stretch of sound plays at \(p.rate)x, the clip at \(speed)x") }
        let end = pieces.map(\.end).max() ?? 0
        #expect(end <= built.duration.seconds + 0.01, "the sound ends with the picture (\(end) s against \(built.duration.seconds) s)")
        if offset > 0 { #expect(abs((pieces.map(\.start).min() ?? 0) - offset) < 0.02, "the sound starts \(offset) s late") }
    }

    @Test func aDelayedSoundDoesNotPushTheNextClipsSoundLater() async throws {
        let src = try await Fixtures.shared.source()
        var audio = AudioSettings(); audio.offsetSeconds = 0.5
        let pieces = [RenderPiece(sourceURL: src, span: span30(0, 60), audio: audio), RenderPiece(sourceURL: src, span: span30(0, 60))]
        let built = try await CompositionBuilder.build(pieces: pieces, includeAudio: true, frameAccurate: true)
        let segs = audioPieces(built).sorted { $0.start < $1.start }
        let secondClipStarts = built.duration.seconds / 2      // two clips of the same length
        let second = segs.last { $0.start >= secondClipStarts - 0.05 }
        #expect(second != nil && abs(second!.start - secondClipStarts) < 0.02, "the second clip's sound starts with the second clip: \(segs)")
        #expect((segs.first?.end ?? 99) <= secondClipStarts + 0.01, "and the first clip's sound ends with the first clip: \(segs)")
    }

    // MARK: A freeze frame lasts as long as the person asked

    @Test func aLongFreezeFrameIsBuiltAsLongAsItsTimelineLength() async throws {
        let src = try await Fixtures.shared.source()
        // The same three pieces the Freeze frame tool makes: the clip up to the frame, the frame held, and the rest.
        var held = VideoLook(); held.speed = (1.0 / 30) / 8
        let pieces = [RenderPiece(sourceURL: src, span: span30(0, 30)), RenderPiece(sourceURL: src, span: span30(30, 31), look: held), RenderPiece(sourceURL: src, span: span30(31, 61))]
        let built = try await CompositionBuilder.build(pieces: pieces, includeAudio: false, frameAccurate: true, fixedGrid: true)
        #expect(abs(built.duration.seconds - (1 + 8 + 1)) < 0.15, "built \(built.duration.seconds) s")
    }
}
