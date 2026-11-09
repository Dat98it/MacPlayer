import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MacPlayerCore
@testable import MacPlayerMedia

/// Pictures made for the tests: the left half red, the right half blue.
enum TestPhoto {
    static func image(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ name: String, width: Int = 200, height: Int = 100, type: UTType = .png, orientation: Int? = nil, gps: Bool = false, space: CGColorSpace? = nil) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-photo-\(name)-\(UUID().uuidString.prefix(6)).\(type.preferredFilenameExtension ?? "img")")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let o = orientation { props[kCGImagePropertyOrientation] = o }
        if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 21.03, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 105.85, kCGImagePropertyGPSLongitudeRef: "E"]
                 props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T1"] }
        CGImageDestinationAddImage(dest, image(width: width, height: height, space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!), props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    static let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    static func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: Int(image.extent.height) - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }
    static func pixel(_ cg: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) { pixel(CIImage(cgImage: cg), x, y) }
}

@Suite(.serialized) struct PhotoTests {
    private func base(_ url: URL) throws -> PhotoLoader.Loaded { try PhotoLoader.full(url: url) }

    @Test func aPictureReportsItsSizeTurnedWhenTheCameraHeldItOnItsSide() throws {
        let plain = try TestPhoto.write("plain", width: 200, height: 100)
        let sideways = try TestPhoto.write("side", width: 200, height: 100, type: .jpeg, orientation: 6)
        let a = try PhotoLoader.info(url: plain), b = try PhotoLoader.info(url: sideways)
        #expect(a.primaryVideo?.width == 200 && a.primaryVideo?.height == 100 && a.duration == .zero && a.hasVideo && !a.hasAudio)
        #expect(b.primaryVideo?.width == 100 && b.primaryVideo?.height == 200, "shown 100 wide and 200 high")
        #expect(Int(try PhotoLoader.preview(url: sideways, maxPixel: 4000).image.extent.width) == 100)
    }

    @Test func aPreviewIsSmallerButKeepsTheShapeAndTellsTheFullSize() throws {
        let url = try TestPhoto.write("big", width: 1600, height: 800)
        let p = try PhotoLoader.preview(url: url, maxPixel: 400)
        #expect(Int(p.image.extent.width) == 400 && Int(p.image.extent.height) == 200)
        #expect(p.pixelWidth == 1600 && p.pixelHeight == 800)
    }

    @Test func aFileThatIsNotAPictureIsRefused() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("not-\(UUID().uuidString.prefix(6)).jpg")
        try Data("hello".utf8).write(to: url)
        #expect(throws: PhotoError.self) { try PhotoLoader.info(url: url) }
        #expect(throws: PhotoError.self) { try PhotoLoader.full(url: url) }
    }

    @Test func withoutEditsThePictureComesOutAsItWent() throws {
        let b = try base(try TestPhoto.write("neutral"))
        let out = PhotoRenderer.render(base: b.image, look: VideoLook(), overlays: [])
        #expect(Int(out.extent.width) == 200 && Int(out.extent.height) == 100)
        let l = TestPhoto.pixel(out, 20, 50), r = TestPhoto.pixel(out, 180, 50)
        #expect(l.r > 250 && l.g < 5 && l.b < 5, "left red: \(l)")
        #expect(r.b > 250 && r.r < 5 && r.g < 5, "right blue: \(r)")
    }

    @Test func cropRotateAndFlipChangeTheShapeAndTheContent() throws {
        let b = try base(try TestPhoto.write("shape"))
        var look = VideoLook(); look.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)       // the right half: blue
        let cropped = PhotoRenderer.render(base: b.image, look: look, overlays: [])
        #expect(Int(cropped.extent.width) == 100 && Int(cropped.extent.height) == 100)
        #expect(TestPhoto.pixel(cropped, 50, 50).b > 250 && TestPhoto.pixel(cropped, 5, 50).b > 250, "all blue")
        var turned = VideoLook(); turned.rotation = 90
        let r = PhotoRenderer.render(base: b.image, look: turned, overlays: [])
        #expect(Int(r.extent.width) == 100 && Int(r.extent.height) == 200, "turned a quarter: \(r.extent)")
        #expect(TestPhoto.pixel(r, 50, 20).r > 250 && TestPhoto.pixel(r, 50, 180).b > 250, "red half is now on top (clockwise)")
        var flipped = VideoLook(); flipped.flipHorizontal = true
        let f = PhotoRenderer.render(base: b.image, look: flipped, overlays: [])
        #expect(TestPhoto.pixel(f, 20, 50).b > 250 && TestPhoto.pixel(f, 180, 50).r > 250, "left and right swapped")
    }

    @Test func aFilterAndColourChangeAreDrawn() throws {
        let b = try base(try TestPhoto.write("filter"))
        var look = VideoLook(); look.effects.filter = .mono
        let mono = PhotoRenderer.render(base: b.image, look: look, overlays: [])
        let p = TestPhoto.pixel(mono, 20, 50)
        #expect(abs(p.r - p.g) < 12 && abs(p.g - p.b) < 12, "no colour left: \(p)")
        var dark = VideoLook(); dark.color.brightness = -0.8
        #expect(TestPhoto.pixel(PhotoRenderer.render(base: b.image, look: dark, overlays: []), 20, 50).r < 200)
        // The live settings of a preview replace the look's own.
        var live = LookEffects(); live.filter = .mono
        let viaLive = PhotoRenderer.render(base: b.image, look: VideoLook(), overlays: [], effects: live)
        #expect(abs(TestPhoto.pixel(viaLive, 20, 50).r - TestPhoto.pixel(viaLive, 20, 50).g) < 12)
    }

    @Test func textAndShapesAreDrawnWhateverTimesTheyWereGiven() throws {
        let b = try base(try TestPhoto.write("text", width: 400, height: 200))
        var text = TextOverlay(text: "HELLO", start: MediaTime(seconds: 5), end: MediaTime(seconds: 6), sizeFraction: 0.3, x: 0.5, y: 0.5)
        text.colorHex = "#FFFFFF"
        let shape = TextOverlay.shape(ShapeSpec(kind: .rectangle, width: 0.2, height: 0.3, fillHex: "#00FF00", strokeHex: nil), start: MediaTime(seconds: 9), end: MediaTime(seconds: 10))
        let plain = PhotoRenderer.render(base: b.image, look: VideoLook(), overlays: [])
        let withText = PhotoRenderer.render(base: b.image, look: VideoLook(), overlays: [text])
        var changed = 0
        for y in stride(from: 70, to: 130, by: 3) { for x in stride(from: 120, to: 280, by: 3) {
            let a = TestPhoto.pixel(plain, x, y), c = TestPhoto.pixel(withText, x, y)
            if abs(a.r - c.r) + abs(a.g - c.g) + abs(a.b - c.b) > 120 { changed += 1 }
        } }
        #expect(changed > 15, "the text shows although its own times (5–6 s) mean nothing for a photo (\(changed) points changed)")
        let withShape = PhotoRenderer.render(base: b.image, look: VideoLook(), overlays: [shape])
        let g = TestPhoto.pixel(withShape, 200, 100)
        #expect(g.g > 200 && g.r < 60, "the green rectangle is in the middle: \(g)")
    }

    @Test func saysHowBigTheResultOfAnEditIs() throws {
        var look = VideoLook(); look.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(PhotoRenderer.outputSize(source: CGSize(width: 200, height: 100), look: look) == CGSize(width: 100, height: 100))
        look.canvas = .portrait9x16
        let s = PhotoRenderer.outputSize(source: CGSize(width: 200, height: 100), look: look)
        #expect(abs(s.width / s.height - 9.0 / 16) < 0.02)
    }
}

@Suite(.serialized) struct PhotoExportTests {
    private func out(_ ext: String) -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-photo-out-\(UUID().uuidString.prefix(6)).\(ext)") }

    private func readBack(_ url: URL) throws -> (cg: CGImage, props: [CFString: Any]) {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)), (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:])
    }

    @Test func anEditedPictureIsSavedInEachFormat() throws {
        let src = try TestPhoto.write("src", width: 200, height: 100)
        var look = VideoLook(); look.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
        for format in PhotoFormat.allCases {
            var o = PhotoExportOptions(); o.format = format
            let url = out(format.fileExtension)
            let size = try PhotoExporter.export(source: src, look: look, overlays: [], options: o, to: url)
            let r = try readBack(url)
            #expect(r.cg.width == 100 && r.cg.height == 100 && size.width == 100, "\(format): \(r.cg.width)×\(r.cg.height)")
            #expect(TestPhoto.pixel(r.cg, 50, 50).b > 235 && TestPhoto.pixel(r.cg, 50, 50).r < 25, "\(format) kept the crop: \(TestPhoto.pixel(r.cg, 50, 50))")
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func aSizeLimitShrinksTheResultAndTheOriginalIsNotTouched() throws {
        let src = try TestPhoto.write("limit", width: 1200, height: 600)
        let before = try Data(contentsOf: src)
        var o = PhotoExportOptions(); o.format = .jpeg; o.maxLongEdge = 400
        let url = out("jpg")
        let size = try PhotoExporter.export(source: src, look: VideoLook(), overlays: [], options: o, to: url)
        #expect(size.width == 400 && size.height == 200)
        let r = try readBack(url)
        #expect(r.cg.width == 400 && r.cg.height == 200)
        #expect(try Data(contentsOf: src) == before, "the original is as it was")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func aHigherQualityMakesABiggerJPEG() throws {
        let src = try TestPhoto.write("quality", width: 600, height: 400)
        func bytes(_ q: Double) throws -> Int {
            var o = PhotoExportOptions(); o.format = .jpeg; o.quality = q
            let url = out("jpg"); defer { try? FileManager.default.removeItem(at: url) }
            // Some detail so that the compressor has something to lose.
            var look = VideoLook(); look.effects.sharpen = 1; look.effects.vignette = 0.6
            try PhotoExporter.export(source: src, look: look, overlays: [], options: o, to: url)
            return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        #expect(try bytes(1.0) > bytes(0.3))
    }

    @Test func theCameraRotationIsAppliedOnceAndNotKeptAsAnInstruction() throws {
        let src = try TestPhoto.write("rot", width: 200, height: 100, type: .jpeg, orientation: 6)      // shown 100×200
        var o = PhotoExportOptions(); o.format = .png
        let url = out("png")
        try PhotoExporter.export(source: src, look: VideoLook(), overlays: [], options: o, to: url)
        let r = try readBack(url)
        #expect(r.cg.width == 100 && r.cg.height == 200)
        let orientation = (r.props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        #expect(orientation == 1, "the pixels are already upright")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func locationCanBeLeftOut() throws {
        let src = try TestPhoto.write("gps", type: .jpeg, gps: true)
        for remove in [false, true] {
            var o = PhotoExportOptions(); o.format = .jpeg; o.removeLocation = remove
            let url = out("jpg"); defer { try? FileManager.default.removeItem(at: url) }
            try PhotoExporter.export(source: src, look: VideoLook(), overlays: [], options: o, to: url)
            let hasGPS = (try readBack(url).props[kCGImagePropertyGPSDictionary] as? [CFString: Any]) != nil
            #expect(hasGPS == !remove, "removeLocation=\(remove)")
        }
    }

    @Test func aWideColourPictureKeepsItsColourSpace() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = try TestPhoto.write("p3", type: .png, space: p3)
        var o = PhotoExportOptions(); o.format = .png
        let url = out("png"); defer { try? FileManager.default.removeItem(at: url) }
        try PhotoExporter.export(source: src, look: VideoLook(), overlays: [], options: o, to: url)
        let before = try readBack(src).cg, after = try readBack(url).cg
        #expect(after.colorSpace?.name == before.colorSpace?.name, "space \(String(describing: before.colorSpace?.name)) → \(String(describing: after.colorSpace?.name))")
        let a = TestPhoto.pixel(before, 20, 50), b = TestPhoto.pixel(after, 20, 50)
        #expect(abs(a.r - b.r) < 4 && abs(a.g - b.g) < 4 && abs(a.b - b.b) < 4, "values unchanged \(a) → \(b)")
    }

    @Test func thumbnailsAreSmallAndUpright() throws {
        let src = try TestPhoto.write("thumb", width: 800, height: 400, type: .jpeg, orientation: 6)
        let t = try #require(PhotoLoader.thumbnail(url: src, maxSize: CGSize(width: 120, height: 120)))
        #expect(max(t.width, t.height) <= 121 && t.height > t.width, "upright: \(t.width)×\(t.height)")
    }
}

@Suite(.serialized) struct PhotoCropMappingTests {
    /// Four coloured quarters: red top left, green top right, blue bottom left, yellow bottom right.
    private func quadrants(_ w: Int, _ h: Int) throws -> CIImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ x: Int, _ y: Int) { ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(CGRect(x: x, y: y, width: w / 2, height: h / 2)) }
        fill(1, 0, 0, 0, h / 2); fill(0, 1, 0, w / 2, h / 2); fill(0, 0, 1, 0, 0); fill(1, 1, 0, w / 2, 0)
        return CIImage(cgImage: ctx.makeImage()!)
    }

    @Test func aFrameDrawnOnTheShownPictureCutsWhatThePictureShowsInIt() throws {
        let base = try quadrants(400, 200)
        // A frame on the original: the middle of the top-left quarter.
        let source = CropRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        for rotation in [0, 90, 180, 270] { for fh in [false, true] { for fv in [false, true] {
            var shownLook = VideoLook(); shownLook.rotation = rotation; shownLook.flipHorizontal = fh; shownLook.flipVertical = fv
            var cutLook = shownLook; cutLook.crop = source
            let whole = PhotoRenderer.render(base: base, look: shownLook, overlays: [])
            let cut = PhotoRenderer.render(base: base, look: cutLook, overlays: [])
            let frame = CropGeometry.toDisplay(source, rotation: rotation, flipH: fh, flipV: fv)
            let W = whole.extent.width, H = whole.extent.height
            #expect(abs(cut.extent.width - frame.width * W) < 1.5 && abs(cut.extent.height - frame.height * H) < 1.5, "rot \(rotation) \(fh)/\(fv): size \(cut.extent.size) vs frame \(frame)")
            // The middle of what was cut is the same colour as the middle of the frame on the whole picture: red (the top-left quarter).
            let a = TestPhoto.pixel(cut, Int(cut.extent.width / 2), Int(cut.extent.height / 2))
            let b = TestPhoto.pixel(whole, Int((frame.x + frame.width / 2) * W), Int((frame.y + frame.height / 2) * H))
            #expect(abs(a.r - b.r) < 6 && abs(a.g - b.g) < 6 && abs(a.b - b.b) < 6 && a.r > 240 && a.g < 15, "rot \(rotation) \(fh)/\(fv): cut \(a) frame \(b)")
            // And the frame lies inside the quarter where the red now is: its corners are all red on the whole picture.
            for (cx, cy) in [(frame.x + 0.01, frame.y + 0.01), (frame.x + frame.width - 0.01, frame.y + frame.height - 0.01)] {
                let c = TestPhoto.pixel(whole, Int(cx * W), Int(cy * H))
                #expect(c.r > 240 && c.g < 15 && c.b < 15, "rot \(rotation) \(fh)/\(fv): corner \(c)")
            }
        } } }
    }
}

@Suite(.serialized) struct PhotoAnimationTests {
    /// A GIF of `colors.count` frames (each a flat colour, 80×40, left half red, right half of the frame's colour).
    private func gif(_ name: String, delays: [Double], loop: Int = 0) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-anim-\(name)-\(UUID().uuidString.prefix(6)).gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
        let shades: [CGFloat] = [0, 0.33, 0.66, 1]
        for (i, d) in delays.enumerated() {
            let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            ctx.setFillColor(CGColor(srgbRed: 0, green: shades[i % 4], blue: 1, alpha: 1)); ctx.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d, kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func anAnimationReportsItsFramesTimingAndLooping() throws {
        let url = try gif("timing", delays: [0.1, 0.2, 0.3, 0.4], loop: 3)
        let a = try #require(PhotoLoader.animation(url: url))
        #expect(a.frameCount == 4 && a.loopCount == 3)
        #expect(zip(a.delays, [0.1, 0.2, 0.3, 0.4]).allSatisfy { abs($0 - $1) < 0.011 } && abs(a.duration - 1.0) < 0.05, "\(a.delays)")
        #expect(try PhotoLoader.frame(url: url, index: 3, maxPixel: nil).width == 80)
        #expect(PhotoLoader.animation(url: try TestPhoto.write("still-gif", type: .gif)) == nil, "a GIF with one frame is a picture")
        #expect(PhotoLoader.animation(url: try TestPhoto.write("still-png", type: .png)) == nil)
    }

    @Test func anAnimationIsSavedWithTheEditOnEveryFrame() throws {
        let url = try gif("edit", delays: [0.1, 0.1, 0.2, 0.3])
        var look = VideoLook(); look.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)          // the right half: it differs from frame to frame
        var o = PhotoExportOptions(); o.format = .gif
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-anim-out-\(UUID().uuidString.prefix(6)).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        let size = try PhotoExporter.export(source: url, look: look, overlays: [], options: o, to: out)
        #expect(size.width == 40 && size.height == 40)
        let a = try #require(PhotoLoader.animation(url: out))
        #expect(a.frameCount == 4 && abs(a.duration - 0.7) < 0.06, "frames \(a.frameCount) lasting \(a.duration)")
        // Every frame is the cropped half: blue, getting greener from frame to frame.
        let greens = try (0..<4).map { i -> Int in TestPhoto.pixel(try PhotoLoader.frame(url: out, index: i, maxPixel: nil), 20, 20).g }
        #expect(greens == greens.sorted() && greens[3] > greens[0] + 150, "the frames keep their differences: \(greens)")
        #expect((0..<4).allSatisfy { TestPhoto.pixel(try! PhotoLoader.frame(url: out, index: $0, maxPixel: nil), 20, 20).r < 30 }, "and none shows the red half that was cut away")
    }

    @Test func anOtherFormatKeepsTheFirstFrameOnly() throws {
        let url = try gif("still", delays: [0.1, 0.1, 0.1, 0.1])
        var o = PhotoExportOptions(); o.format = .png
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-anim-still-\(UUID().uuidString.prefix(6)).png")
        defer { try? FileManager.default.removeItem(at: out) }
        try PhotoExporter.export(source: url, look: VideoLook(), overlays: [], options: o, to: out)
        #expect(PhotoLoader.animation(url: out) == nil)
        let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 1)
    }
}

@Suite(.serialized) struct PhotoPlannedSizeTests {
    @Test func theSizeToldBeforeSavingIsTheSizeWritten() throws {
        // Odd sizes, crops and limits: the numbers the screen shows must be the numbers of the file, to the pixel.
        let cases: [(w: Int, h: Int, crop: CropRect, limit: Int?, rotation: Int)] = [
            (2048, 1536, CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), 1230, 0),
            (997, 1331, CropRect(x: 0.13, y: 0.07, width: 0.71, height: 0.77), 640, 0),
            (3024, 4032, CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), 2400, 0),
            (1000, 667, .full, 333, 90),
            (801, 599, CropRect(x: 0.1, y: 0.1, width: 0.55, height: 0.9), nil, 270),
            (640, 480, .full, 4000, 0),
        ]
        for c in cases {
            let src = try TestPhoto.write("plan", width: c.w, height: c.h, type: .jpeg)
            var look = VideoLook(); look.crop = c.crop; look.rotation = c.rotation
            var o = PhotoExportOptions(); o.format = .png; o.maxLongEdge = c.limit
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-plan-\(UUID().uuidString.prefix(6)).png")
            defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: src) }
            let planned = PhotoExporter.plannedSize(width: Double(c.w), height: Double(c.h), look: look, maxLongEdge: c.limit)
            let written = try PhotoExporter.export(source: src, look: look, overlays: [], options: o, to: out)
            #expect(written.width == planned.width && written.height == planned.height, "\(c.w)×\(c.h) limit \(String(describing: c.limit)): told \(planned.width)×\(planned.height), wrote \(written.width)×\(written.height)")
            let info = try PhotoLoader.info(url: out)
            #expect(info.primaryVideo?.width == planned.width && info.primaryVideo?.height == planned.height, "and the file says \(info.primaryVideo?.width ?? 0)×\(info.primaryVideo?.height ?? 0)")
            if let limit = c.limit { #expect(max(planned.width, planned.height) <= limit + 1, "within the limit") }
        }
    }
}
