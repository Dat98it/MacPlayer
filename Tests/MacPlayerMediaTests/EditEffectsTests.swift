import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Source frames have: red 40x40 at top-right, green at bottom-left, blue at bottom-right (320x180).
@Suite(.serialized) struct EditEffectsTests {
    private func export(_ src: URL, _ name: String, look: VideoLook = VideoLook(), audio: AudioSettings = AudioSettings(),
                        overlays: [TextOverlay] = [], cues: [SubtitleCue] = [], from: Int64 = 0, to: Int64 = 60, subtitleSize: Double = 0.05,
                        options: ExportOptions = ExportOptions(mode: .exact)) async throws -> URL {
        let out = Fixtures.shared.outputURL(name)
        var recipe = RenderRecipe(look: look, audio: audio, overlays: overlays, burnedInCues: cues)
        recipe.subtitleStyle = SubtitleStyle(); recipe.subtitleStyle.sizeFraction = subtitleSize
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(from, to), look: look, audio: audio)], recipe: recipe, to: out, options: options)
        return out
    }

    /// Same render path as an edited export (so colour conversion is identical) but nothing visible is added.
    private func baseline(_ src: URL, _ name: String, to: Int64 = 90) async throws -> URL {
        let never = TextOverlay(text: "x", start: MediaTime(seconds: 50), end: MediaTime(seconds: 51))
        return try await export(src, name, overlays: [never], to: to)
    }

    @Test func rotating90ClockwiseMovesTheMarkers() async throws {
        let src = try await Fixtures.shared.source()
        var look = VideoLook(); look.rotation = 90
        let out = try await export(src, "rot90", look: look)
        let info = try await MediaProbe.probe(url: out)
        #expect(info.primaryVideo?.width == 180 && info.primaryVideo?.height == 320, "got \(info.primaryVideo?.width ?? 0)x\(info.primaryVideo?.height ?? 0)")
        let f = try await frame(out, at: 0.5)
        // Clockwise: top-right red -> bottom-right; bottom-left green -> top-left; bottom-right blue -> bottom-left.
        #expect(f.isRed(f.width - 20, f.height - 20), "red should now be bottom-right")
        #expect(f.isGreen(20, 20), "green should now be top-left")
        #expect(f.isBlue(20, f.height - 20), "blue should now be bottom-left")
    }

    @Test func flipsMirrorThePicture() async throws {
        let src = try await Fixtures.shared.source()
        var h = VideoLook(); h.flipHorizontal = true
        let fh = try await frame(try await export(src, "fliph", look: h), at: 0.5)
        #expect(fh.isRed(20, 20) && fh.isGreen(fh.width - 20, fh.height - 20) && fh.isBlue(20, fh.height - 20))
        var v = VideoLook(); v.flipVertical = true
        let fv = try await frame(try await export(src, "flipv", look: v), at: 0.5)
        #expect(fv.isRed(fv.width - 20, fv.height - 20) && fv.isGreen(20, 20) && fv.isBlue(fv.width - 20, 20))
    }

    @Test func cropKeepsTheChosenRegion() async throws {
        let src = try await Fixtures.shared.source()
        var look = VideoLook(); look.crop = CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5) // bottom-right quarter
        let out = try await export(src, "crop", look: look)
        let info = try await MediaProbe.probe(url: out)
        #expect(info.primaryVideo?.width == 160 && info.primaryVideo?.height == 90)
        let f = try await frame(out, at: 0.5)
        #expect(f.isBlue(f.width - 20, f.height - 20), "the blue corner marker is in the bottom-right quarter")
        #expect(!f.isRed(20, 20), "the top-right marker was cropped away")
    }

    @Test func portraitCanvasLetterboxesOrFills() async throws {
        let src = try await Fixtures.shared.source()
        var fit = VideoLook(); fit.canvas = .portrait9x16; fit.fit = .fit
        let a = try await export(src, "fit", look: fit)
        let ia = try await MediaProbe.probe(url: a)
        #expect(ia.primaryVideo?.width == 180 && ia.primaryVideo?.height == 320)
        let fa = try await frame(a, at: 0.5)
        #expect(fa.isBlack(90, 5) && fa.isBlack(90, 315), "fit leaves black bars above and below")
        #expect(!fa.isBlack(90, 160), "the picture is in the middle")

        var fill = fit; fill.fit = .fill
        let b = try await export(src, "fill", look: fill)
        let fb = try await frame(b, at: 0.5)
        #expect(!fb.isBlack(90, 40) && !fb.isBlack(90, 300), "fill covers the whole canvas")
    }

    @Test func colourAdjustmentsChangeThePicture() async throws {
        let src = try await Fixtures.shared.source()
        let base = try await frame(try await export(src, "c0"), at: 0.5)
        var bright = VideoLook(); bright.color.brightness = 0.6
        let b = try await frame(try await export(src, "c1", look: bright), at: 0.5)
        let area = CGRect(x: 60, y: 60, width: 150, height: 80)
        #expect(b.meanLuma(in: area) > base.meanLuma(in: area) + 20, "brighter")
        var grey = VideoLook(); grey.color.saturation = -1
        let g = try await frame(try await export(src, "c2", look: grey), at: 0.5)
        let px = g.rgb(g.width - 20, 20) // was pure red
        #expect(abs(px.r - px.g) < 25 && abs(px.g - px.b) < 25, "no saturation: red becomes grey, got \(px)")
        var warm = VideoLook(); warm.color.temperature = 0.8
        let w = try await frame(try await export(src, "c3", look: warm), at: 0.5)
        let wa = w.rgb(150, 90), ba = base.rgb(150, 90)
        #expect((wa.r - wa.b) > (ba.r - ba.b), "warmer: more red than blue")
    }

    @Test func textAppearsOnlyDuringItsTimeRange() async throws {
        let src = try await Fixtures.shared.source()
        let t = TextOverlay(text: "TITLE", start: MediaTime(seconds: 1), end: MediaTime(seconds: 2), sizeFraction: 0.2, colorHex: "#FFFFFF", x: 0.5, y: 0.5, fade: 0)
        let plain = try await baseline(src, "t0")
        let with = try await export(src, "t1", overlays: [t], to: 90)
        let area = CGRect(x: 60, y: 60, width: 200, height: 60)
        let before = try await frame(with, at: 0.5).meanAbsDiff(try await frame(plain, at: 0.5), in: area)
        let during = try await frame(with, at: 1.5).meanAbsDiff(try await frame(plain, at: 1.5), in: area)
        let after = try await frame(with, at: 2.6).meanAbsDiff(try await frame(plain, at: 2.6), in: area)
        #expect(during > 8 && before < 4 && after < 4, "text only inside 1s...2s: before \(before), during \(during), after \(after)")
    }

    @Test func burnedInSubtitlesAppearWithTheirCue() async throws {
        let src = try await Fixtures.shared.source()
        let cue = SubtitleCue(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2), text: "Xin chào Việt Nam")
        let plain = try await baseline(src, "s0")
        let burned = try await export(src, "s1", cues: [cue], to: 90, subtitleSize: 0.12)
        let area = CGRect(x: 20, y: 130, width: 280, height: 45)
        let during = try await frame(burned, at: 1.5).meanAbsDiff(try await frame(plain, at: 1.5), in: area)
        let outside = try await frame(burned, at: 2.6).meanAbsDiff(try await frame(plain, at: 2.6), in: area)
        #expect(during > 6 && outside < 4, "subtitle in the lower third only during its cue: \(during) / \(outside)")
    }

    @Test func exportedFrameMatchesThePreviewFrame() async throws {
        let src = try await Fixtures.shared.source()
        var look = VideoLook()
        look.crop = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        look.rotation = 90; look.color.saturation = 0.4; look.color.brightness = 0.1
        let title = TextOverlay(text: "Match", start: .zero, end: MediaTime(seconds: 4), sizeFraction: 0.1, y: 0.2, fade: 0)
        let out = try await export(src, "parity", look: look, overlays: [title], from: 0, to: 90)

        // The preview: the same builder (without the half-frame export guard), asked for a still through the generator.
        let preview = try await CompositionBuilder.build(pieces: [RenderPiece(sourceURL: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)), look: look)],
                                                          overlays: [title], frameAccurate: false)
        let gen = AVAssetImageGenerator(asset: preview.composition)
        gen.videoComposition = preview.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        var worst = 0.0
        for t in [0.5, 1.5, 2.5] {
            let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let p = Pixels(cg), e = try await frame(out, at: t)
            #expect(p.width == e.width && p.height == e.height, "same size: preview \(p.width)x\(p.height) export \(e.width)x\(e.height)")
            worst = max(worst, p.meanAbsDiff(e))
        }
        #expect(worst < 3, "preview and export differ by \(worst)/255 on average (should be codec loss only)")
    }

    @Test func theRenderPathDoesNotShiftColours() async throws {
        // Regression: untagged compositor output made the encoder and the preview disagree by up to 13 levels.
        let src = try await Fixtures.shared.source()
        var look = VideoLook(); look.color.brightness = 0.0001 // engages the compositor with a near-neutral look
        let piece = RenderPiece(sourceURL: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)), look: look)
        let out = try await export(src, "neutral", look: look, to: 90)
        let built = try await CompositionBuilder.build(pieces: [piece], frameAccurate: false)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600))
        let preview = Pixels(cg), original = try await frame(src, at: 1.5), exported = try await frame(out, at: 1.5)
        #expect(preview.meanAbsDiff(original) < 1.5, "preview vs source \(preview.meanAbsDiff(original))")
        #expect(exported.meanAbsDiff(original) < 2.5, "export vs source \(exported.meanAbsDiff(original))")
    }

    @Test func muteSilencesTheSoundAndSpeedChangesLength() async throws {
        let src = try await Fixtures.shared.source()
        let normal = try await export(src, "a0", to: 90)
        #expect(try await FrameScanner.beepOnsets(url: normal).count >= 2)
        var muted = AudioSettings(); muted.muted = true
        let m = try await export(src, "a1", audio: muted, to: 90)
        #expect(try await FrameScanner.beepOnsets(url: m).isEmpty, "muted clip has no beeps")

        var fast = VideoLook(); fast.speed = 2
        let f = try await export(src, "sp", look: fast, from: 0, to: 90)
        let d = try await MediaProbe.probe(url: f).duration.seconds
        // The picture is 1.49 s; the soundtrack of a sped-up clip runs about 0.1 s longer (known, see docs), so the file is a little over.
        #expect(abs(d - 1.5) < 0.2, "3 s at 2x is about 1.5 s, got \(d)")
    }

    @Test func gainRaisesAndLowersLevel() async throws {
        let src = try await Fixtures.shared.source()
        func peak(_ u: URL) async throws -> Float {
            let a = AVURLAsset(url: u)
            let t = try await a.loadTracks(withMediaType: .audio)[0]
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            r.add(o); r.startReading()
            var p: Float = 0
            while let sb = o.copyNextSampleBuffer(), let b = CMSampleBufferGetDataBuffer(sb) {
                let n = CMBlockBufferGetDataLength(b)
                var d = [Float](repeating: 0, count: n / 4)
                d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
                p = max(p, d.map(abs).max() ?? 0)
            }
            return p
        }
        let base = try await peak(try await export(src, "g0", to: 90))
        var down = AudioSettings(); down.gainDB = -12
        let low = try await peak(try await export(src, "g1", audio: down, to: 90))
        #expect(low < base * 0.4 && low > base * 0.15, "-12 dB is about a quarter: base \(base) low \(low)")
    }

    @Test func fadeInStartsSilent() async throws {
        let src = try await Fixtures.shared.source()
        var a = AudioSettings(); a.fadeIn = 0.1
        let out = try await export(src, "fade", audio: a, from: 0, to: 60)
        let onsets = try await FrameScanner.beepOnsets(url: out)
        // The beep at t=0 starts at full level without a fade; with a 100 ms fade-in it is quieter at first, so
        // its detected onset moves later than 0.
        #expect((onsets.first?.seconds ?? 0) > 0.02, "fade-in delays the point where the beep is loud: \(onsets.first?.seconds ?? -1)")
    }
}

@Suite(.serialized) struct MultiSourceRenderTests {
    @Test func eachPieceKeepsItsOwnLookAndSpeed() async throws {
        let a = try await Fixtures.shared.source()
        let b = try await Fixtures.shared.source(.init(container: .mov, codec: .hevc))
        var flip = VideoLook(); flip.flipHorizontal = true
        var fast = VideoLook(); fast.speed = 2
        let pieces = [
            RenderPiece(sourceURL: a, span: span30(0, 30)),                       // 1 s, as is
            RenderPiece(sourceURL: b, span: span30(30, 60), look: flip),           // 1 s, mirrored
            RenderPiece(sourceURL: a, span: span30(60, 120), look: fast),          // 2 s of source at 2x = 1 s
        ]
        let out = Fixtures.shared.outputURL("multi-look")
        try await RenderExporter().export(pieces: pieces, to: out, options: ExportOptions(mode: .exact))
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 3.0) < 0.15, "1 + 1 + (2 s at 2x) = 3 s, got \(info.duration.seconds)")
        let f1 = try await frame(out, at: 0.5), f2 = try await frame(out, at: 1.5), f3 = try await frame(out, at: 2.5)
        #expect(f1.isRed(f1.width - 20, 20), "first piece as is: red top-right")
        #expect(f2.isRed(20, 20), "second piece mirrored: red top-left")
        #expect(f3.isRed(f3.width - 20, 20), "third piece not mirrored")
    }

    @Test func aPieceFromADifferentSizeFitsTheCanvasOfTheFirst() async throws {
        let wide = try await Fixtures.shared.source()                                   // 320x180
        let portrait = try await Fixtures.shared.source(.init(rotation: 90))            // displays 180x320
        let out = Fixtures.shared.outputURL("multi-size")
        var look = VideoLook(); look.canvas = .landscape16x9 // forces the compositor even for the neutral first piece
        let pieces = [RenderPiece(sourceURL: wide, span: span30(0, 30), look: look), RenderPiece(sourceURL: portrait, span: span30(0, 30), look: look)]
        try await RenderExporter().export(pieces: pieces, recipe: RenderRecipe(look: look), to: out, options: ExportOptions(mode: .exact))
        let info = try await MediaProbe.probe(url: out)
        #expect(info.primaryVideo?.width == 320 && info.primaryVideo?.height == 180)
        let f = try await frame(out, at: 1.5) // the portrait clip, letterboxed
        #expect(f.isBlack(5, 90) && f.isBlack(f.width - 5, 90), "pillarbox bars on the sides")
        #expect(!f.isBlack(f.width / 2, 90))
    }

    @Test func aTimelinePreviewHasTheSameLengthAsTheExport() async throws {
        let a = try await Fixtures.shared.source()
        var fast = VideoLook(); fast.speed = 2
        let pieces = [RenderPiece(sourceURL: a, span: span30(0, 60), look: fast), RenderPiece(sourceURL: a, span: span30(60, 90))]
        let preview = try await CompositionBuilder.build(pieces: pieces, frameAccurate: false)
        #expect(abs(preview.duration.seconds - 2.0) < 0.01, "1 s (2 s at 2x) + 1 s")
    }
}

/// A near-neutral look keeps the barcode readable but sends the export through the compositor (which samples on a fixed
/// frame grid), so these catch frame loss that only happens on that path.
@Suite(.serialized) struct CompositorFrameAccuracyTests {
    private var engaged: VideoLook { var l = VideoLook(); l.color.brightness = 0.0001; return l }

    @Test func aSingleClipKeepsEveryChosenFrame() async throws {
        for (name, kind) in [("30 fps", Fixtures.Kind()), ("29.97 fps", Fixtures.Kind(fps: 30))] {
            let src = try await Fixtures.shared.source(kind)
            let out = Fixtures.shared.outputURL("grid")
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(30, 70), look: engaged)], recipe: RenderRecipe(look: engaged), to: out, options: ExportOptions(mode: .exact))
            let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
            #expect(idx == Array(30..<70), "\(name): got \(idx.first ?? -1)...\(idx.last ?? -1), \(idx.count) frames")
        }
    }

    @Test func aClipToTheEndOfTheFileKeepsItsLastFrame() async throws {
        let src = try await Fixtures.shared.source() // 4 s = 120 frames
        let out = Fixtures.shared.outputURL("grid-end")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(90, 120), look: engaged)], recipe: RenderRecipe(look: engaged), to: out, options: ExportOptions(mode: .exact))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx == Array(90..<120), "got \(idx.first ?? -1)...\(idx.last ?? -1), \(idx.count) frames")
    }

    @Test func joinedPiecesLoseNoFrameAtTheJoins() async throws {
        let a = try await Fixtures.shared.source()
        let pieces = [RenderPiece(sourceURL: a, span: span30(0, 30), look: engaged), RenderPiece(sourceURL: a, span: span30(60, 90), look: engaged),
                      RenderPiece(sourceURL: a, span: span30(30, 60), look: engaged)]
        let out = Fixtures.shared.outputURL("grid-join")
        try await RenderExporter().export(pieces: pieces, recipe: RenderRecipe(look: engaged), to: out, options: ExportOptions(mode: .exact))
        let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
        #expect(idx == Array(0..<30) + Array(60..<90) + Array(30..<60), "\(idx.count) frames")
    }

    @Test func soundStaysWithinOneFrameOfThePictureOnTheCompositorPath() async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("grid-sync")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(20, 110), look: engaged)], recipe: RenderRecipe(look: engaged), to: out, options: ExportOptions(mode: .exact))
        let frames = try await FrameScanner.scanVideo(url: out)
        let onsets = try await FrameScanner.beepOnsets(url: out)
        var worst = 0.0, pairs = 0
        for o in onsets {
            if let f = frames.first(where: { ($0.index ?? 1) % 30 == 0 && abs($0.time.seconds - o.seconds) < 0.5 }) { worst = max(worst, abs(o.seconds - f.time.seconds)); pairs += 1 }
        }
        #expect(pairs >= 2 && worst < 1.0 / 30, "A/V offset \(worst * 1000) ms over \(pairs) cues")
    }
}
