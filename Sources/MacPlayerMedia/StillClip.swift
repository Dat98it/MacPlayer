import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import MacPlayerCore

/// A photo on the main video track is played from a short silent video of that photo, made once and kept in MacPlayer's own folder
/// (never next to the photo, and the photo itself is only read). The video holds one picture a second for a minute, so the clip made
/// from it can be dragged out to any length up to that; such a clip is so still that it compresses to almost nothing.
public enum StillClip {
    nonisolated(unsafe) public static var cacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent("macplayer-stills", isDirectory: true)
    /// How long the made video is (the longest a photo clip can be).
    public static let seconds = 60
    /// How long a photo stays on screen when it is first put on the timeline.
    public static let defaultLength = 5.0
    /// The largest side of the picture in the made video.
    public static let maxSide = 1920

    public enum StillError: Error, CustomStringConvertible {
        case unreadable(String), writer(String)
        public var description: String {
            switch self {
            case .unreadable(let n): return "“\(n)” cannot be read as a picture"
            case .writer(let m): return "the photo could not be turned into a clip: \(m)"
            }
        }
    }

    /// Is this one of the videos MacPlayer made itself (of a photo, an animation or a sound)? Such a video never sets the pace of a project
    /// (a photo is one picture a second, an animation has its own uneven timing), and is always drawn through the compositor.
    public static func isMade(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return [cacheFolder, AudioCover.cacheFolder].contains { p.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Where the video of this photo is kept: named after the photo's path, size and date, so a changed photo gets a new video.
    /// An animation (GIF, animated PNG or WebP) gets a name of its own: 0.15 and older made a still of its first frame.
    public static func cachedURL(for image: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: image.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf29ce484222325
        let animated = PhotoLoader.animation(url: image) != nil ? "|anim" : ""
        for b in "\(image.standardizedFileURL.path)|\(size)|\(Int(date))\(animated)".precomposedStringWithCanonicalMapping.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return cacheFolder.appendingPathComponent(String(format: "%016llx.mov", h))
    }

    /// How long a picture stays on the timeline when it is first put there: a few seconds for a photo; for an animation, the whole
    /// animation, played again until it lasts about 3 seconds when it is shorter.
    public static func defaultLength(for image: URL) -> Double {
        guard let a = PhotoLoader.animation(url: image), a.duration > 0 else { return defaultLength }
        let d = a.duration
        return d < 3 ? d * (3 / d).rounded(.up) : d
    }

    /// How many times an animation is repeated in its video: enough for a minute (so the clip can be dragged out), at least once.
    static func loops(for a: PhotoLoader.Animation) -> Int { max(1, Int((Double(seconds) / max(0.02, a.duration)).rounded(.up))) }

    /// The video of the photo, made now if it is not there yet.
    public static func make(from image: URL) async throws -> URL {
        let out = cachedURL(for: image)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        if let animation = PhotoLoader.animation(url: image) { return try await makeAnimated(from: image, animation: animation, to: out) }
        guard let picture = PhotoLoader.thumbnail(url: image, maxSize: CGSize(width: maxSide, height: maxSide)) else { throw StillError.unreadable(image.lastPathComponent) }
        // Even sizes: the encoder wants them.
        let w = max(2, picture.width & ~1), h = max(2, picture.height & ~1)
        let temp = cacheFolder.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 2, AVVideoAverageBitRateKey: 6_000_000, AVVideoAllowFrameReorderingKey: false],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw StillError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard let buffer = pb else { throw StillError.writer("no buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for s in 0...seconds {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(s), timescale: 1)) else { throw StillError.writer(writer.error?.localizedDescription ?? "append") }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StillError.writer(writer.error?.localizedDescription ?? "finish") }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: temp, to: out)
        return out
    }

    /// The largest side of the frames of an animation's video (animations are small, and all their frames are kept in memory while it is made).
    public static let animationMaxSide = 1280

    /// Where the see-through video of an animation used as a layer is kept (0.16).
    public static func layerURL(for image: URL) -> URL {
        cachedURL(for: image).deletingPathExtension().appendingPathExtension("alpha.mov")
    }

    /// An animation used as a *layer* over the video (a moving sticker): a video that keeps its see-through parts (HEVC with alpha), made
    /// once. nil for a picture that is not an animation (a still picture stays a picture layer).
    public static func makeLayer(from image: URL) async throws -> URL? {
        guard let animation = PhotoLoader.animation(url: image) else { return nil }
        let out = layerURL(for: image)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        return try await makeAnimated(from: image, animation: animation, to: out, alpha: true)
    }

    /// An animation's video: each frame for as long as the file says, the whole animation repeated for about a minute. On black (H.264)
    /// for the main track; see-through (HEVC with alpha) for a layer.
    static func makeAnimated(from image: URL, animation: PhotoLoader.Animation, to out: URL, alpha: Bool = false) async throws -> URL {
        guard let first = try? PhotoLoader.frame(url: image, index: 0, maxPixel: nil) else { throw StillError.unreadable(image.lastPathComponent) }
        // Smaller when all the frames would take too much memory.
        var side = min(animationMaxSide, max(first.width, first.height))
        while side > 320, animation.frameCount * side * side * 4 > 700_000_000 { side = side * 3 / 4 }
        let k = Double(side) / Double(max(first.width, first.height))
        let w = max(2, Int((Double(first.width) * k).rounded()) & ~1), h = max(2, Int((Double(first.height) * k).rounded()) & ~1)
        let temp = cacheFolder.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAverageBitRateKey: 8_000_000, AVVideoAllowFrameReorderingKey: false],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        // Every frame drawn once (on black: a video has no see-through parts), then written again for each repeat.
        var buffers: [CVPixelBuffer] = []
        for i in 0..<animation.frameCount {
            let cg = i == 0 ? first : try PhotoLoader.frame(url: image, index: i, maxPixel: nil)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let buffer = pb else { throw StillError.writer("no buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                if alpha { ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)) }
                else { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            buffers.append(buffer)
        }
        guard writer.startWriting() else { throw StillError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        let timescale: CMTimeScale = 6000
        var t: CMTimeValue = 0
        for _ in 0..<loops(for: animation) {
            for (i, buffer) in buffers.enumerated() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: t, timescale: timescale)) else { throw StillError.writer(writer.error?.localizedDescription ?? "append") }
                t += max(1, CMTimeValue((animation.delays[i] * Double(timescale)).rounded()))
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: t, timescale: timescale))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StillError.writer(writer.error?.localizedDescription ?? "finish") }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: temp, to: out)
        return out
    }
}
