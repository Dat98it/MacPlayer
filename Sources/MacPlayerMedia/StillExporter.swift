import CoreGraphics
import Foundation
import MacPlayerCore

/// Saves one frame of a video as a PNG or JPEG: the frame at `time`, optionally cropped to a shape (centred) and scaled
/// down. Written to a temporary sibling first and moved into place, so a failure never leaves half an image or damages
/// an image that was already there.
public enum StillExporter {
    public enum StillError: Error, Equatable { case cannotWrite }

    public static func export(source: URL, at time: MediaTime, aspect: CanvasPreset = .source, format: ImageWriter.Format, maxWidth: Int? = nil, to destination: URL) async throws {
        var image = try await FrameGrabber.image(url: source, at: time, accuracy: .exact)
        if let a = aspect.aspect {
            let c = CropRect.centered(aspect: a, sourceWidth: Double(image.width), sourceHeight: Double(image.height))
            let rect = CGRect(x: c.x * Double(image.width), y: c.y * Double(image.height), width: c.width * Double(image.width), height: c.height * Double(image.height)).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }
        if let limit = maxWidth, image.width > limit, let scaled = resized(image, width: limit) { image = scaled }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).macplayer-partial-\(UUID().uuidString.prefix(6))")
        do {
            try ImageWriter.write(image, to: temp, format: format)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: destination) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    static func resized(_ image: CGImage, width: Int) -> CGImage? {
        let h = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()
    }
}
