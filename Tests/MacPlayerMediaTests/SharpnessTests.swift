import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// Things made bigger or smaller on the picture stay sharp (0.17.2: the maintainer saw dropped texts, stickers and pictures come out soft).
@Suite(.serialized) struct SharpnessTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func alphas(_ img: CIImage, size: CGSize) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(img, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    @Test func aTextMadeBiggerIsDrawnAtThatSizeNotBlownUp() throws {
        let size = CGSize(width: 640, height: 360)
        var big = TextOverlay(text: "Đến khi nào", start: .zero, end: MediaTime(seconds: 2))
        big.sizeFraction = 0.15; big.x = 0.5; big.y = 0.5
        var scaled = big
        scaled.id = UUID(); scaled.sizeFraction = 0.06; scaled.scale = 2.5
        func drawn(_ o: TextOverlay) throws -> [UInt8] {
            let layer = OverlayLayer(overlays: [o], cues: [], style: SubtitleStyle(), live: false)
            let img = try #require(layer.visible(at: 0.5, size: size).first?.0)
            return alphas(img, size: size)
        }
        let a = try drawn(big), b = try drawn(scaled)
        let soft = { (p: [UInt8]) in p.filter { $0 > 30 && $0 < 225 }.count }
        let diff = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        let inked = max(1, a.filter { $0 > 128 }.count)
        // Blown up 2.5× from a small drawing, the edges were about twice as wide (many more half-see-through pixels).
        #expect(Double(soft(b)) < Double(soft(a)) * 1.3, "edges as crisp as text drawn that big: \(soft(b)) vs \(soft(a)) soft pixels")
        #expect(Double(diff) / Double(inked) < 40, "same letters: \(Double(diff) / Double(inked)) per inked pixel")
    }

    @Test func aBigPictureMadeSmallIsAveragedNotSampled() {
        // 1-pixel checkerboard, 2000×2000, shown at 200×200: every output pixel should be the mean grey.
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 1, "inputColor0": CIColor.white, "inputColor1": CIColor.black,
                                                                             "inputSharpness": 1, "inputCenter": CIVector(x: 0, y: 0)])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let small = RecipeCompositor.scaledSharply(checker, toWidth: 200, height: 150)
        #expect(small.extent.origin == .zero && abs(small.extent.width - 200) < 0.01 && abs(small.extent.height - 150) < 0.01)
        var bytes = [UInt8](repeating: 0, count: 100 * 4)
        ctx.render(small, toBitmap: &bytes, rowBytes: 40, bounds: CGRect(x: 50, y: 50, width: 10, height: 10), format: .RGBA8, colorSpace: nil)
        let reds = stride(from: 0, to: bytes.count, by: 4).map { Int(bytes[$0]) }
        let spread = (reds.max() ?? 0) - (reds.min() ?? 0)
        #expect(spread < 40, "an even grey, not stripes: \(reds.min() ?? 0)…\(reds.max() ?? 0)")
    }
}
