import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import ImageIO
import MacPlayerCore

/// A sound (a song, a recording) on a video project's main track (0.16). The editing and export code works on videos, so the sound is played
/// from a video MacPlayer makes of it once, in its own folder: a cover picture (the song's artwork, or a card with its title) shown for the whole
/// length, with the sound itself — copied as it is when it is AAC or Apple Lossless, else written as Apple Lossless, so nothing of it is lost.
/// The sound file is only read.
public enum AudioCover {
    nonisolated(unsafe) public static var cacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent("macplayer-covers", isDirectory: true)
    /// How often the (unchanging) cover picture is written, in seconds, and how many pictures go between two full ones. A 79-minute mix
    /// took 21 s and 596 MB with one full picture every 2 s and the sound in Apple Lossless (0.16.0 before release); see `make`.
    public static let pictureEvery = 5
    /// Without words, where the tile's centre is, from the bottom of the picture (0.6 = 40% from the top), leaving the lower part for the texts.
    public static let centreFromBottom: CGFloat = 0.6
    public static let keyEvery = 15
    /// The cover's size: a 16:9 HD frame, the shape most videos made from a song end up in.
    public static let width = 1920, height = 1080

    public enum CoverError: Error, CustomStringConvertible {
        case noSound(String), writer(String)
        public var description: String {
            switch self {
            case .noSound(let n): return "“\(n)” has no sound that can be read"
            case .writer(let m): return "the sound could not be turned into a clip: \(m)"
            }
        }
    }

    /// What a sound file says about itself.
    public struct Info: Equatable, Sendable {
        public var title: String
        public var artist: String?
        public var album: String?
        /// The cover picture's bytes (JPEG or PNG), when the file has one.
        public var artwork: Data?
        public init(title: String, artist: String? = nil, album: String? = nil, artwork: Data? = nil) {
            self.title = title; self.artist = artist; self.album = album; self.artwork = artwork
        }
    }

    /// Title, artist, album and artwork from the file's tags; the title falls back to the file's name.
    public static func info(of url: URL) async -> Info {
        let asset = AVURLAsset(url: url)
        var out = Info(title: url.deletingPathExtension().lastPathComponent)
        guard let items = try? await asset.load(.commonMetadata) else { return out }
        func text(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                  let s = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        if let t = await text(.commonIdentifierTitle) { out.title = t }
        out.artist = await text(.commonIdentifierArtist)
        out.album = await text(.commonIdentifierAlbumName)
        if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first {
            if let d = try? await item.load(.dataValue), artworkImage(d) != nil { out.artwork = d }
        }
        return out
    }

    /// The artwork's picture, upright.
    public static func artworkImage(_ data: Data, maxPixel: Int = 1400) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }

    /// Two colours for a sound without artwork, always the same for the same title (so a project looks the same every time it is opened).
    public static func palette(for title: String) -> (CGColor, CGColor) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in title.precomposedStringWithCanonicalMapping.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hue = Double(h % 360) / 360
        return (hsb(hue, 0.62, 0.52), hsb((hue + 0.11).truncatingRemainder(dividingBy: 1), 0.75, 0.22))
    }

    private static func hsb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The cover picture: the artwork on a blurred, darkened copy of itself, or a coloured card with a note. With `words`, the title, artist and
    /// album are drawn beside it. Without (what a project's cover video uses since 0.16.2), the tile sits in the middle, a little high, and the
    /// words are left to the project as texts the person can change (`SoundTitles`): drawn into the picture they could not be edited.
    public static func picture(for info: Info, width: Int = AudioCover.width, height: Int = AudioCover.height, words: Bool = true) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        let art = info.artwork.flatMap { artworkImage($0) }
        // Background.
        if let art {
            let ci = CIImage(cgImage: art)
            let k = max(W / ci.extent.width, H / ci.extent.height) * 1.15
            let filled = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let moved = filled.transformed(by: CGAffineTransform(translationX: (W - filled.extent.width) / 2, y: (H - filled.extent.height) / 2))
            let blurred = moved.clampedToExtent().applyingGaussianBlur(sigma: 60)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.28, kCIInputSaturationKey: 1.2])
                .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
            let c = CIContext(options: [.workingColorSpace: NSNull()])
            if let bg = c.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: W, height: H)) { ctx.draw(bg, in: CGRect(x: 0, y: 0, width: W, height: H)) }
        } else {
            let (a, b) = palette(for: info.title)
            if let g = CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
            }
        }
        // A soft shade under the text side keeps light artwork readable.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.18)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // The cover tile on the left.
        let side = (H * (words ? 0.56 : 0.5)).rounded()
        let tile = words ? CGRect(x: (W * 0.13).rounded(), y: ((H - side) / 2).rounded(), width: side, height: side)
                         : CGRect(x: ((W - side) / 2).rounded(), y: (H * centreFromBottom - side / 2).rounded(), width: side, height: side)
        let path = CGPath(roundedRect: tile, cornerWidth: side * 0.045, cornerHeight: side * 0.045, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.025), blur: side * 0.09, color: CGColor(gray: 0, alpha: 0.55))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let art {
            // Filled into the square, centred.
            let k = max(side / CGFloat(art.width), side / CGFloat(art.height))
            let w = CGFloat(art.width) * k, h = CGFloat(art.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(art, in: CGRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h))
        } else {
            let (a, b) = palette(for: info.title + "·")
            if let g = CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
            }
            drawText("♫", in: CGRect(x: tile.minX, y: tile.midY - side * 0.3, width: side, height: side * 0.6), ctx: ctx, size: side * 0.42, weight: .regular,
                     color: CGColor(gray: 1, alpha: 0.88), center: true, lines: 1)
        }
        ctx.restoreGState()

        guard words else { return ctx.makeImage() }
        // The words on the right.
        let x = tile.maxX + W * 0.06, textWidth = W - x - W * 0.08
        var y = tile.maxY - side * 0.08
        y -= drawText(info.title, in: CGRect(x: x, y: tile.minY, width: textWidth, height: y - tile.minY), ctx: ctx, size: H * 0.066, weight: .bold, color: CGColor(gray: 1, alpha: 1), lines: 3)
        y -= H * 0.022
        if let artist = info.artist {
            y -= drawText(artist, in: CGRect(x: x, y: tile.minY, width: textWidth, height: y - tile.minY), ctx: ctx, size: H * 0.04, weight: .medium, color: CGColor(gray: 1, alpha: 0.82), lines: 2)
            y -= H * 0.012
        }
        if let album = info.album {
            _ = drawText(album, in: CGRect(x: x, y: tile.minY, width: textWidth, height: y - tile.minY), ctx: ctx, size: H * 0.03, weight: .regular, color: CGColor(gray: 1, alpha: 0.6), lines: 2)
        }
        return ctx.makeImage()
    }

    private enum Weight { case regular, medium, bold }

    /// Draws `text` from the top of `rect` down (at most `lines` lines, the last one ended with "…"), and returns the height used.
    @discardableResult
    private static func drawText(_ text: String, in rect: CGRect, ctx: CGContext, size: CGFloat, weight: Weight, color: CGColor, center: Bool = false, lines: Int) -> CGFloat {
        guard rect.height > size * 0.5, rect.width > 10 else { return 0 }
        let base = CTFontCreateUIFontForLanguage(weight == .bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var font = base
        if weight == .medium {
            let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.23]] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(d, size, nil)
        }
        var align: CTTextAlignment = center ? .center : .left
        var lineBreak: CTLineBreakMode = .byWordWrapping
        let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &align),
                        CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: &lineBreak)]
        let para = CTParagraphStyleCreate(settings, settings.count)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                                                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: rect.minX, y: rect.minY - 10_000, width: rect.width, height: rect.height + 10_000), transform: nil), nil)
        guard let all = CTFrameGetLines(frame) as? [CTLine], !all.isEmpty else { return 0 }
        let lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * 1.06
        let fit = max(1, min(lines, all.count, Int(rect.height / lineHeight)))
        var used: CGFloat = 0
        for i in 0..<fit {
            var line = all[i]
            if i == fit - 1, fit < all.count || CTLineGetStringRange(line).location + CTLineGetStringRange(line).length < (text as NSString).length {
                // The rest of the text in this last line, cut with "…".
                let r = CTLineGetStringRange(line)
                let rest = NSAttributedString(string: (text as NSString).substring(from: r.location), attributes: attrs)
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                line = CTLineCreateTruncatedLine(CTLineCreateWithAttributedString(rest), Double(rect.width), .end, token) ?? line
            }
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let lx = center ? rect.midX - w / 2 : rect.minX
            ctx.textPosition = CGPoint(x: lx, y: rect.maxY - used - CTFontGetAscent(font))
            CTLineDraw(line, ctx)
            used += lineHeight
        }
        return used
    }

    /// Where the video of this sound is kept: named after the sound's path, size and date, so a changed file gets a new video. ("cover2": since
    /// 0.16.2 the picture has no words; "cover3": 0.16.3 adds the picture at the very end; a project made by 0.16.0/0.16.1 keeps its own older video while it is there.)
    public static func cachedURL(for sound: URL) -> URL { cachedURL(for: sound, version: current) }

    /// Is this a sound's cover video (in MacPlayer's covers folder)?
    public static func isCover(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(cacheFolder.standardizedFileURL.path + "/") }

    /// The versions of the cover video: 1 = 0.16.0/0.16.1 (words drawn in), 2 = 0.16.2 (no words, no picture at the very end), 3 = now.
    public static let current = 3
    public static func cachedURL(for sound: URL, version: Int) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sound.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf29ce484222325
        let key = version == 1 ? "cover" : "cover\(version)"
        for b in "\(key)|\(sound.standardizedFileURL.path)|\(size)|\(Int(date))".precomposedStringWithCanonicalMapping.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return cacheFolder.appendingPathComponent(String(format: "%016llx.mov", h))
    }

    /// Which older version a project's cover video `video` of `sound` is (1 or 2), or nil when it is the current one or not one of ours.
    /// An older one is made again: version 2 has no picture at the end (an export of the song's end failed), version 1 has words drawn in.
    public static func olderVersion(of video: URL, sound: URL) -> Int? {
        let p = video.standardizedFileURL.path
        return [1, 2].first { cachedURL(for: sound, version: $0).standardizedFileURL.path == p }
    }

    /// The video of the sound, made now if it is not there yet.
    public static func make(from sound: URL) async throws -> URL {
        let out = cachedURL(for: sound)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: sound)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CoverError.noSound(sound.lastPathComponent) }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw CoverError.noSound(sound.lastPathComponent) }
        let formats = try await track.load(.formatDescriptions)
        let fmt = formats.first
        let asbd = fmt.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let codec = fmt.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let tags = await info(of: sound)
        guard let cover = picture(for: tags, words: false) else { throw CoverError.writer("no picture") }

        let temp = cacheFolder.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let w = width, h = height
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            // The picture never changes: a full picture every `keyEvery` pictures, the ones between cost almost nothing.
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: keyEvery, AVVideoAverageBitRateKey: 4_000_000, AVVideoAllowFrameReorderingKey: false],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(vInput)

        // The sound: copied when it already is AAC or Apple Lossless, else decoded and written as Apple Lossless (lossless, any source).
        let reader = try AVAssetReader(asset: asset)
        let passthrough = codec == kAudioFormatMPEG4AAC || codec == kAudioFormatAppleLossless || codec == kAudioFormatMPEGLayer3
        let aOutput: AVAssetReaderTrackOutput
        let aInput: AVAssetWriterInput
        if passthrough {
            aOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
        } else {
            let rate = max(8000, min(asbd?.mSampleRate ?? 44100, 192_000))
            let channels = max(1, min(Int(asbd?.mChannelsPerFrame ?? 2), 2))
            let bits = (asbd?.mBitsPerChannel ?? 0) > 16 ? 24 : 16
            aOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: bits,
            ])
        }
        aOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(aOutput) else { throw CoverError.writer("the sound cannot be read") }
        reader.add(aOutput)
        aInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(aInput) else { throw CoverError.writer("the sound cannot be written") }
        writer.add(aInput)

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard let buffer = pb else { throw CoverError.writer("no buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cover, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        guard reader.startReading() else { throw CoverError.writer(reader.error?.localizedDescription ?? "read") }
        guard writer.startWriting() else { throw CoverError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        // One picture every `pictureEvery` seconds for the whole length; both tracks are fed as the writer asks, so they interleave.
        // The times of the pictures: every `pictureEvery` seconds, and one more a thirtieth of a second before the end. Without that last one
        // the end of the song (up to 5 s after the last picture) had no picture at all: an export of it failed with "no frame to compose" (0.16.3).
        var times = stride(from: 0, to: duration.seconds, by: Double(pictureEvery)).map { CMTime(value: CMTimeValue($0), timescale: 1) }
        let last = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
        if let t = times.last, CMTimeCompare(last, CMTimeAdd(t, CMTime(value: 1, timescale: 10))) > 0 { times.append(last) }
        let frames = times.count
        final class Feed: @unchecked Sendable {
            var next = 0, failed = false, left = 2
            var done: CheckedContinuation<Void, Never>?
            let lock = NSLock()
            func finish() { lock.lock(); left -= 1; let c = left == 0 ? done : nil; lock.unlock(); c?.resume() }
        }
        let feed = Feed()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            feed.done = c
            vInput.requestMediaDataWhenReady(on: DispatchQueue(label: "macplayer.cover.video")) {
                while vInput.isReadyForMoreMediaData {
                    if feed.next >= frames || feed.failed { vInput.markAsFinished(); feed.finish(); return }
                    if !adaptor.append(buffer, withPresentationTime: times[feed.next]) { feed.failed = true; vInput.markAsFinished(); feed.finish(); return }
                    feed.next += 1
                }
            }
            aInput.requestMediaDataWhenReady(on: DispatchQueue(label: "macplayer.cover.audio")) {
                while aInput.isReadyForMoreMediaData {
                    guard let sample = aOutput.copyNextSampleBuffer() else { aInput.markAsFinished(); feed.finish(); return }
                    if !aInput.append(sample) { feed.failed = true; aInput.markAsFinished(); feed.finish(); return }
                }
            }
        }
        if feed.failed || reader.status == .failed {
            writer.cancelWriting()
            throw CoverError.writer(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "append")
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw CoverError.writer(writer.error?.localizedDescription ?? "finish") }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: temp, to: out)
        return out
    }
}
