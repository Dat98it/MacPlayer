import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Photos on the main track: a photo becomes a short silent video in MacPlayer's own folder, and a timeline that mixes it with videos plays and
/// exports at the videos' pace.
@Suite(.serialized) struct StillClipTests {
    private func photo(_ name: String, r: Double, g: Double, b: Double, w: Int = 300, h: Int = 200) throws -> URL {
        let url = Fixtures.shared.outputURL(name, ext: "png")
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil); CGImageDestinationFinalize(dest)
        return url
    }

    @Test func aPhotoBecomesAMinuteLongStillVideoInItsOwnFolderAndThePhotoIsUntouched() async throws {
        StillClip.cacheFolder = Fixtures.shared.root.appendingPathComponent("stills-\(UUID().uuidString.prefix(6))")
        let p = try photo("still-src", r: 1, g: 0, b: 0, w: 301, h: 201)
        let before = try Data(contentsOf: p)
        let v = try await StillClip.make(from: p)
        #expect(v.path.hasPrefix(StillClip.cacheFolder.path), "made in MacPlayer's folder, never next to the photo")
        #expect(try Data(contentsOf: p) == before)
        let info = try await MediaProbe.probe(url: v)
        #expect(abs(info.duration.seconds - Double(StillClip.seconds)) < 0.05 && info.hasVideo && !info.hasAudio)
        #expect(info.primaryVideo?.width == 300 && info.primaryVideo?.height == 200, "even sizes for the encoder")
        let px = try await frame(v, at: 30)
        #expect(px.isRed(150, 100))
        // Made once: asking again gives the same file without making it again.
        let again = try await StillClip.make(from: p)
        #expect(again == v)
    }

    @Test func aTimelineOfAVideoAndAPhotoExportsAtTheVideosPace() async throws {
        StillClip.cacheFolder = Fixtures.shared.root.appendingPathComponent("stills-\(UUID().uuidString.prefix(6))")
        let video = try await Fixtures.shared.source()
        let still = try await StillClip.make(from: try photo("still-blue", r: 0, g: 0, b: 1, w: 320, h: 180))
        let out = Fixtures.shared.outputURL("video-and-photo")
        // No effect at all: before 0.10 the picture was then copied as it is, and the photo's part had one frame a second.
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: video, span: span30(0, 60)), RenderPiece(sourceURL: still, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)))],
                                          to: out, options: ExportOptions(mode: .exact))
        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil); reader.add(o); reader.startReading()
        var times: [Double] = []
        while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) } }
        times.sort()
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(abs(Double(times.count) - 150) <= 2, "5 s at 30 fps: \(times.count) frames")
        #expect((gaps.max() ?? 1) < 0.05, "no long frames where the photo is (largest gap \(gaps.max() ?? -1) s)")
        let photoPart = try await frame(out, at: 3.5)
        #expect(photoPart.isBlue(160, 90), "the photo is shown after the video")
    }

    @Test func aPhotoClipKeepsTextMovingOverIt() async throws {
        // The compositor draws every frame even when the source does not change (tweening), so a text fading in over a photo really fades.
        StillClip.cacheFolder = Fixtures.shared.root.appendingPathComponent("stills-\(UUID().uuidString.prefix(6))")
        let still = try await StillClip.make(from: try photo("still-black", r: 0, g: 0, b: 0, w: 320, h: 180))
        var o = TextOverlay(text: "████", start: .zero, end: MediaTime(seconds: 3), sizeFraction: 0.5, y: 0.5)
        o.colorHex = "#FFFFFF"; o.fade = 1.5
        let out = Fixtures.shared.outputURL("photo-text")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: still, span: TimeSpan(start: .zero, end: MediaTime(seconds: 3)))],
                                          recipe: RenderRecipe(overlays: [o]), to: out, options: ExportOptions(mode: .exact))
        let a = try await frame(out, at: 0.3).rgb(160, 90), b = try await frame(out, at: 1.2).rgb(160, 90)
        #expect(b.r > a.r + 40, "the text gets brighter between 0.3 s and 1.2 s (\(a.r) → \(b.r))")
    }
}
