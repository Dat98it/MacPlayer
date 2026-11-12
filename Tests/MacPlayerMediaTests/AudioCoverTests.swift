import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// 0.16: a sound on a video project's main track is played from a video MacPlayer makes of it (a cover picture with the sound, nothing of
/// the sound lost); an animation on the main track moves; an animated PNG is saved as one.
@Suite(.serialized) struct AudioCoverTests {
    private let rate = 44_100.0

    /// A stereo sound: a 440 Hz tone on the left, 660 Hz on the right, written in the given format.
    private func sound(_ name: String, ext: String, seconds: Double, settings: [String: Any]? = nil) throws -> URL {
        let url = Fixtures.shared.outputURL(name, ext: ext)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) {
            let t = Double(i) / rate
            buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 440 * t))
            buffer.floatChannelData![1][i] = Float(0.5 * sin(2 * .pi * 660 * t))
        }
        try file.write(from: buffer)
        return url
    }

    private func pcm(_ url: URL, channel: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                         AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: rate])
        reader.add(out); reader.startReading()
        var s: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for i in stride(from: channel, to: data.count, by: 2) { s.append(data[i]) }
        }
        return s
    }

    private func crossings(_ s: ArraySlice<Float>) -> Int { zip(s, s.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count }

    private func codec(_ url: URL) async throws -> FourCharCode {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let f = try #require(try await track.load(.formatDescriptions).first)
        return CMFormatDescriptionGetMediaSubType(f)
    }

    private func png(width: Int, height: Int, r: Double, g: Double, b: Double) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil); CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func aWavBecomesAVideoWithACoverAndTheWholeSoundLosslessAndTheSoundIsUntouched() async throws {
        AudioCover.cacheFolder = Fixtures.shared.root.appendingPathComponent("covers-\(UUID().uuidString.prefix(6))")
        let src = try sound("cover-wav", ext: "wav", seconds: 3.4)
        let before = try Data(contentsOf: src)
        let v = try await AudioCover.make(from: src)
        #expect(v.path.hasPrefix(AudioCover.cacheFolder.path), "made in MacPlayer's folder, never next to the sound")
        #expect(StillClip.isMade(v))
        #expect(try Data(contentsOf: src) == before)
        let info = try await MediaProbe.probe(url: v)
        #expect(info.hasVideo && info.hasAudio)
        #expect(info.primaryVideo?.width == AudioCover.width && info.primaryVideo?.height == AudioCover.height)
        #expect(abs(info.duration.seconds - 3.4) < 0.05, "as long as the sound: \(info.duration.seconds)")
        #expect(try await codec(v) == kAudioFormatAppleLossless, "a sound in no lossless-copyable format is written as Apple Lossless")
        // Lossless: the samples are the ones of the file (16-bit rounding at most).
        let a = try await pcm(src, channel: 0), b = try await pcm(v, channel: 0)
        #expect(abs(a.count - b.count) <= 2048, "\(a.count) vs \(b.count) samples")
        let n = min(a.count, b.count)
        let worst = (0..<n).reduce(Float(0)) { max($0, abs(a[$1] - b[$1])) }
        #expect(worst < 0.0002, "largest difference \(worst)")
        // Both channels kept, each with its own tone.
        let right = try await pcm(v, channel: 1)
        #expect(abs(crossings(right[0..<44_100]) - 660) <= 3 && abs(crossings(b[0..<44_100]) - 440) <= 3)
        // The cover picture is there all along, not black.
        let px = try await frame(v, at: 3.0)
        #expect(px.meanLuma(in: CGRect(x: 0, y: 0, width: 400, height: 400)) > 8)
        // Made once.
        #expect(try await AudioCover.make(from: src) == v)
    }

    @Test func anAACSoundIsCopiedAsItIs() async throws {
        AudioCover.cacheFolder = Fixtures.shared.root.appendingPathComponent("covers-\(UUID().uuidString.prefix(6))")
        let src = try sound("cover-aac", ext: "m4a", seconds: 2, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        let v = try await AudioCover.make(from: src)
        #expect(try await codec(v) == kAudioFormatMPEG4AAC, "copied, not encoded again")
        let info = try await MediaProbe.probe(url: v)
        #expect(abs(info.duration.seconds - 2) < 0.08 && info.hasVideo)
        let s = try await pcm(v, channel: 0)
        #expect(abs(crossings(s[4410..<48_510]) - 440) <= 4)
    }

    @Test func aFileWithoutSoundIsRefused() async throws {
        AudioCover.cacheFolder = Fixtures.shared.root.appendingPathComponent("covers-\(UUID().uuidString.prefix(6))")
        let silent = try await Fixtures.shared.source(Fixtures.Kind(audio: false))
        await #expect(throws: AudioCover.CoverError.self) { _ = try await AudioCover.make(from: silent) }
    }

    @Test func theCoverShowsTheArtworkOrAColouredCardAndIsAlwaysTheSameForTheSameSong() throws {
        let red = try png(width: 500, height: 500, r: 1, g: 0, b: 0)
        let withArt = Pixels(try #require(AudioCover.picture(for: AudioCover.Info(title: "Song", artist: "Someone", album: "Album", artwork: red))))
        #expect(withArt.width == 1920 && withArt.height == 1080)
        // The tile on the left (13% in, 56% of the height): the artwork itself.
        let tileCentre = (x: Int(1920 * 0.13 + 1080 * 0.28), y: 540)
        #expect(withArt.isRed(tileCentre.x, tileCentre.y))
        // The background is a darkened, blurred copy of it: reddish, darker.
        let bg = withArt.rgb(30, 30)
        #expect(bg.r > bg.g + 30 && bg.r < 200, "\(bg)")
        // Words on the right: lighter pixels than the background around them.
        let words = withArt.meanLuma(in: CGRect(x: 1000, y: 280, width: 700, height: 120))
        #expect(words > withArt.meanLuma(in: CGRect(x: 1000, y: 900, width: 700, height: 100)) + 5)

        let card1 = Pixels(try #require(AudioCover.picture(for: AudioCover.Info(title: "Untitled"))))
        let card2 = Pixels(try #require(AudioCover.picture(for: AudioCover.Info(title: "Untitled"))))
        let other = Pixels(try #require(AudioCover.picture(for: AudioCover.Info(title: "Another one"))))
        #expect(card1.meanAbsDiff(card2) == 0, "the same song gets the same card")
        #expect(card1.meanAbsDiff(other) > 3, "another song gets other colours")
        #expect(card1.meanLuma(in: CGRect(x: 0, y: 0, width: 1920, height: 1080)) > 15, "not black")
    }

    @Test func tagsAreReadAndTheTitleFallsBackToTheFileName() async throws {
        let src = try sound("Plain Name", ext: "wav", seconds: 0.5)
        let info = await AudioCover.info(of: src)
        #expect(info.title == src.deletingPathExtension().lastPathComponent && info.artist == nil && info.artwork == nil)
    }

    @Test func theWholeTimelinesSoundIsSavedAsM4AWithItsFades() async throws {
        AudioCover.cacheFolder = Fixtures.shared.root.appendingPathComponent("covers-\(UUID().uuidString.prefix(6))")
        let cover = try await AudioCover.make(from: try sound("timeline-sound", ext: "wav", seconds: 4))
        var faded = AudioSettings(); faded.fadeIn = 1
        let video = try await Fixtures.shared.source()           // 4 s with sound
        let out = Fixtures.shared.outputURL("timeline-sound", ext: "m4a")
        try await AudioExporter.exportTimeline(pieces: [RenderPiece(sourceURL: cover, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)), audio: faded),
                                                        RenderPiece(sourceURL: video, span: span30(0, 60))], to: out)
        let info = try await MediaProbe.probe(url: out)
        #expect(info.hasAudio && !info.hasVideo, "sound only")
        #expect(abs(info.duration.seconds - 5) < 0.1, "3 s + 2 s: \(info.duration.seconds)")
        let s = try await pcm(out, channel: 0)
        func level(_ a: Double, _ b: Double) -> Double { let r = s[Int(a * rate)..<min(s.count, Int(b * rate))]; return (r.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, r.count))).squareRoot() }
        #expect(level(0.05, 0.25) < level(1.5, 2.5) * 0.5, "the fade in is in the sound (\(level(0.05, 0.25)) vs \(level(1.5, 2.5)))")
        #expect(abs(crossings(s[Int(1.5 * rate)..<Int(2.5 * rate)]) - 440) <= 4, "the song's tone")
        // Saving never goes over a file.
        await #expect(throws: ExportError.self) { try await AudioExporter.exportTimeline(pieces: [RenderPiece(sourceURL: cover, span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)))], to: out) }
    }

    @Test func aSoundClipInATimelineExportsWithItsSoundAndCover() async throws {
        AudioCover.cacheFolder = Fixtures.shared.root.appendingPathComponent("covers-\(UUID().uuidString.prefix(6))")
        let cover = try await AudioCover.make(from: try sound("cover-export", ext: "wav", seconds: 12))
        // A part between two of the cover's pictures (one every 5 s): the picture is there all along.
        let out = Fixtures.shared.outputURL("cover-export-out")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: cover, span: TimeSpan(start: MediaTime(seconds: 6.3), end: MediaTime(seconds: 8.3)))],
                                          to: out, options: ExportOptions(mode: .exact))
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 2) < 0.1 && info.hasAudio && info.hasVideo)
        for t in [0.05, 1.0, 1.9] {
            let px = try await frame(out, at: t)
            #expect(px.meanLuma(in: CGRect(x: 0, y: 0, width: px.width, height: px.height)) > 8, "the cover at \(t) s")
        }
        let fps = info.primaryVideo?.frameRate?.framesPerSecond ?? 0
        #expect(fps >= 24, "a made video never sets a pace of one picture a second (\(fps))")
        let s = try await pcm(out, channel: 0)
        #expect(abs(crossings(s[4410..<48_510]) - 440) <= 4)
    }
}

@Suite(.serialized) struct AnimationClipTests {
    /// An animation of `colors.count` frames of `delay` seconds each, written by ImageIO as a GIF or an animated PNG.
    static func animation(_ name: String, png: Bool, colors: [(Double, Double, Double)], delay: Double, w: Int = 120, h: Int = 80) throws -> URL {
        let url = Fixtures.shared.outputURL(name, ext: png ? "png" : "gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, (png ? UTType.png : UTType.gif).identifier as CFString, colors.count, nil))
        if png { CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary) }
        else { CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
        for c in colors {
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let props: [CFString: Any] = png ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]]
                                             : [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), props as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test(arguments: [false, true]) func anAnimationOnTheMainTrackMovesWithItsOwnTiming(png: Bool) async throws {
        // The default folder: StillClipTests changes `cacheFolder` while its own tests run, at the same time as this suite.
        let src = try Self.animation("anim", png: png, colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1)], delay: 0.5)
        let a = try #require(PhotoLoader.animation(url: src))
        #expect(a.frameCount == 3 && abs(a.duration - 1.5) < 0.01)
        let v = try await StillClip.make(from: src)
        let info = try await MediaProbe.probe(url: v)
        // Repeated for a minute: 40 times 1.5 s.
        #expect(abs(info.duration.seconds - 60) < 0.05, "\(info.duration.seconds)")
        #expect(info.primaryVideo?.width == 120 && info.primaryVideo?.height == 80)
        // Each frame for half a second, over and over.
        let red = try await frame(v, at: 0.25), green = try await frame(v, at: 0.75), blue = try await frame(v, at: 1.25), again = try await frame(v, at: 1.75), late = try await frame(v, at: 45.8)
        #expect(red.isRed(60, 40) && green.isGreen(60, 40) && blue.isBlue(60, 40) && again.isRed(60, 40))
        #expect(late.isGreen(60, 40), "45.8 s = 30 loops + 0.8 s: the second frame")
        // At first the whole animation, played through until it lasts about 3 seconds.
        #expect(abs(StillClip.defaultLength(for: src) - 3) < 0.01)
    }

    @Test func aStillPictureKeepsItsOldVideoNameAndAnAnimationGetsANewOne() throws {
        let gif = try Self.animation("name", png: false, colors: [(1, 0, 0), (0, 1, 0)], delay: 0.2)
        let still = try Self.animation("name-still", png: false, colors: [(1, 0, 0)], delay: 0.2)
        #expect(PhotoLoader.animation(url: still) == nil)
        #expect(StillClip.defaultLength(for: still) == StillClip.defaultLength)
        #expect(StillClip.cachedURL(for: gif) != StillClip.cachedURL(for: still))
        // A long animation is used whole.
        #expect(abs(StillClip.defaultLength(for: try Self.animation("long", png: false, colors: Array(repeating: (0, 0, 1), count: 8), delay: 0.5)) - 4) < 0.01)
    }

    @Test func anAnimatedPNGIsSavedAsAnAnimatedPNGWithTheEditOnEveryFrame() throws {
        let src = try Self.animation("apng-src", png: true, colors: [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1)], delay: 0.1)
        var look = VideoLook(); look.color.saturation = -1         // black and white
        var o = PhotoExportOptions(); o.format = .png
        let out = Fixtures.shared.outputURL("apng-out", ext: "png")
        let size = try PhotoExporter.export(source: src, look: look, overlays: [], options: o, to: out)
        #expect(size.width == 120 && size.height == 80)
        let a = try #require(PhotoLoader.animation(url: out))
        #expect(a.frameCount == 4 && abs(a.duration - 0.4) < 0.01)
        let s = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetType(s) as String? == UTType.png.identifier)
        let second = Pixels(try #require(CGImageSourceCreateImageAtIndex(s, 1, nil))).rgb(60, 40)
        #expect(abs(second.r - second.g) < 6 && abs(second.g - second.b) < 6 && second.g > 60, "the green frame, made grey: \(second)")
        // JPEG still keeps only the first frame.
        o.format = .jpeg
        let jpg = Fixtures.shared.outputURL("apng-first", ext: "jpg")
        _ = try PhotoExporter.export(source: src, look: VideoLook(), overlays: [], options: o, to: jpg)
        #expect(PhotoLoader.animation(url: jpg) == nil)
    }

    @Test func anAnimationAsALayerMovesAndKeepsItsSeeThroughParts() async throws {
        // Two frames, half a second each: a red square, then a blue one, in the middle of a see-through picture.
        let url = Fixtures.shared.outputURL("sticker", ext: "gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for c in [(1.0, 0.0, 0.0), (0.0, 0.0, 1.0)] {
            let ctx = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.clear(CGRect(x: 0, y: 0, width: 160, height: 90))
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)); ctx.fill(CGRect(x: 55, y: 20, width: 50, height: 50))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        let layer = try #require(try await StillClip.makeLayer(from: url))
        #expect(StillClip.isMade(layer) && layer != StillClip.cachedURL(for: url))
        // A still picture is not made into a video.
        let still = Fixtures.shared.outputURL("sticker-still", ext: "png")
        try ImageWriter.write(try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()), to: still, format: .png)
        #expect(try await StillClip.makeLayer(from: still) == nil)

        let main = try await Fixtures.shared.source()
        var t = OverlayTransform(); t.centerX = 0.5; t.centerY = 0.5; t.width = 1
        let spec = LayerSpec(kind: .video(path: layer.path, sourceStart: .zero, sourceEnd: MediaTime(seconds: 2)), lane: 0, start: .zero, duration: MediaTime(seconds: 2), transform: t)
        var engaged = VideoLook(); engaged.color.exposure = 0.0001
        func render(_ layers: [LayerSpec], _ name: String) async throws -> URL {
            let out = Fixtures.shared.outputURL(name)
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: main, span: span30(0, 60), look: engaged)], recipe: RenderRecipe(look: engaged, layers: layers), to: out, options: ExportOptions(mode: .exact))
            return out
        }
        let base = try await render([], "sticker-base"), out = try await render([spec], "sticker-over")
        let b0 = try await frame(base, at: 0.25), f0 = try await frame(out, at: 0.25), f1 = try await frame(out, at: 0.75)
        #expect(f0.isRed(160, 90), "the first frame in the middle: \(f0.rgb(160, 90))")
        #expect(f1.isBlue(160, 90), "then the second: \(f1.rgb(160, 90))")
        // Around the square the video shows through (not black).
        for (x, y) in [(20, 20), (300, 160), (40, 150)] {
            let a = b0.rgb(x, y), c = f0.rgb(x, y)
            #expect(abs(a.r - c.r) + abs(a.g - c.g) + abs(a.b - c.b) < 30, "see-through at \((x, y)): \(a) vs \(c)")
        }
    }
}
