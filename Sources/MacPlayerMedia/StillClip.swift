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

    /// Where the video of this photo is kept: named after the photo's path, size and date, so a changed photo gets a new video.
    public static func cachedURL(for image: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: image.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(image.standardizedFileURL.path)|\(size)|\(Int(date))".precomposedStringWithCanonicalMapping.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return cacheFolder.appendingPathComponent(String(format: "%016llx.mov", h))
    }

    /// The video of the photo, made now if it is not there yet.
    public static func make(from image: URL) async throws -> URL {
        let out = cachedURL(for: image)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
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
}
