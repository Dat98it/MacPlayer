import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MacPlayerCore
@testable import MacPlayerMedia

/// A logo over the photo of a photo project: drawn where it is placed, the same on the screen and in the saved file, and on every
/// frame of an animation.
@Suite(.serialized) struct PhotoLogoTests {
    /// A solid green square: easy to find against the red and blue halves of the test photo.
    private func greenLogo() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-logo-\(UUID().uuidString.prefix(6)).png")
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); _ = CGImageDestinationFinalize(dest)
        return url
    }

    /// A logo in the top-left quarter (centre at 25 % / 25 %, a fifth of the width).
    private func clip(_ logo: URL) -> OverlayClip {
        var t = OverlayTransform(); t.centerX = 0.25; t.centerY = 0.25; t.width = 0.2
        return OverlayClip(name: "logo", kind: .image(path: logo.path, bookmark: nil), start: .zero, duration: MediaTime(seconds: 200_000), transform: t)
    }

    @Test func aLogoIsDrawnWhereItIsPlacedAndNowhereElse() throws {
        let photo = try TestPhoto.write("logo-base", width: 200, height: 100)
        let logo = try greenLogo()
        let base = try PhotoLoader.full(url: photo).image
        let out = PhotoRenderer.render(base: base, look: VideoLook(), overlays: [], logos: PhotoLogo.load([clip(logo)]))
        let atLogo = TestPhoto.pixel(out, 50, 25)
        #expect(atLogo.g > 230 && atLogo.r < 25 && atLogo.b < 25, "green where the logo is: \(atLogo)")
        let left = TestPhoto.pixel(out, 50, 85), right = TestPhoto.pixel(out, 150, 50)
        #expect(left.r > 230 && left.g < 25 && right.b > 230 && right.g < 25, "the photo is as it was elsewhere: \(left) \(right)")
        let without = PhotoRenderer.render(base: base, look: VideoLook(), overlays: [])
        #expect(TestPhoto.pixel(without, 50, 25).r > 230, "no logo, no green")
    }

    /// 0.20: a shape is drawn over a logo until the logo is brought to the front.
    @Test func layerOrderDecidesWhetherAShapeOrALogoIsOnTop() throws {
        let photo = try TestPhoto.write("logo-order", width: 200, height: 100)
        let base = try PhotoLoader.full(url: photo).image
        var p = Project(name: "order", kind: .photo)
        p.overlayClips = [clip(try greenLogo())]
        p.overlays = [TextOverlay.shape(ShapeSpec(kind: .rectangle, width: 0.1, height: 0.1, fillHex: "#FFFFFF"), start: .zero, end: MediaTime(seconds: 200_000), x: 0.25, y: 0.25)]
        let before = TestPhoto.pixel(PhotoRenderer.render(base: base, look: VideoLook(), overlays: p.overlays, logos: PhotoLogo.load(p.overlayClips)), 50, 25)
        #expect(before.r > 230 && before.g > 230 && before.b > 230, "the shape is over the logo, as before 0.20: \(before)")
        #expect(LayerOrder.move([p.overlayClips[0].id], .toFront, in: &p, timed: false))
        let after = TestPhoto.pixel(PhotoRenderer.render(base: base, look: VideoLook(), overlays: p.overlays, logos: PhotoLogo.load(p.overlayClips)), 50, 25)
        #expect(after.g > 230 && after.r < 25 && after.b < 25, "the logo now covers the shape: \(after)")
    }

    @Test func theSavedPhotoHasTheLogoAndTheOriginalAndTheLogoFileAreUntouched() throws {
        let photo = try TestPhoto.write("logo-save", width: 200, height: 100)
        let logo = try greenLogo()
        let photoBytes = try Data(contentsOf: photo), logoBytes = try Data(contentsOf: logo)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-logo-out-\(UUID().uuidString.prefix(6)).png")
        var options = PhotoExportOptions(); options.format = .png
        try PhotoExporter.export(source: photo, look: VideoLook(), overlays: [], layers: [clip(logo)], options: options, to: out)
        let saved = try PhotoLoader.full(url: out).image
        let p = TestPhoto.pixel(saved, 50, 25)
        #expect(p.g > 230 && p.r < 25, "the saved file shows the logo: \(p)")
        #expect(try Data(contentsOf: photo) == photoBytes && (try Data(contentsOf: logo)) == logoBytes)
    }

    @Test func aMissingLogoFileIsLeftOutInsteadOfBreakingThePhoto() throws {
        let photo = try TestPhoto.write("logo-missing", width: 200, height: 100)
        var c = clip(URL(fileURLWithPath: "/nowhere/logo.png")); c.name = "gone"
        let logos = PhotoLogo.load([c])
        #expect(logos.isEmpty)
        let out = PhotoRenderer.render(base: try PhotoLoader.full(url: photo).image, look: VideoLook(), overlays: [], logos: logos)
        #expect(TestPhoto.pixel(out, 50, 25).r > 230)
    }
}
