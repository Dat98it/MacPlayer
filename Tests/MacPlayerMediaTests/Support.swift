import AVFoundation
import CoreGraphics
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Short synthetic sources, generated once per test run into a temp folder (no personal media involved).
actor Fixtures {
    static let shared = Fixtures()

    private var tasks: [String: Task<URL, Error>] = [:]
    nonisolated let root: URL = {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macplayer-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    struct Kind: Hashable {
        var container: SyntheticMedia.Container = .mp4
        var codec: SyntheticMedia.Codec = .h264
        var fps: Int32 = 30
        var seconds = 4.0
        var audio = true
        var rotation = 0
        var gop = 30
        var width = 320
        var height = 180
    }

    func source(_ k: Kind = Kind()) async throws -> URL {
        let key = "\(k)"
        if let t = tasks[key] { return try await t.value }
        let url = root.appendingPathComponent("src-\(tasks.count)-\(k.codec.rawValue)-\(k.fps)fps.\(k.container.rawValue)")
        let t = Task { () -> URL in
            var s = SyntheticMedia.Spec()
            s.container = k.container; s.codec = k.codec; s.width = k.width; s.height = k.height
            s.frameRate = FrameRate(numerator: k.fps, denominator: k.fps == 30 ? 1 : 1)
            s.seconds = k.seconds; s.withAudio = k.audio; s.keyframeInterval = k.gop; s.rotationMetadata = k.rotation
            try await SyntheticMedia.generate(to: url, spec: s)
            return url
        }
        tasks[key] = t
        return try await t.value
    }

    nonisolated func outputURL(_ name: String, ext: String = "mp4") -> URL {
        let u = root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).\(ext)")
        return u
    }
}

/// Reads pixels from a decoded frame.
struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        width = w; height = h
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        data = buf
    }

    /// RGB at (x, y) with the origin at the TOP-left.
    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let o = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
    }

    func luma(_ x: Int, _ y: Int) -> Double { let c = rgb(x, y); return 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b) }

    func meanLuma(in r: CGRect) -> Double {
        var sum = 0.0, n = 0.0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) { for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) { sum += luma(x, y); n += 1 } }
        return n == 0 ? 0 : sum / n
    }

    /// Mean absolute difference per channel against another image of the same size, over a region (0...255).
    func meanAbsDiff(_ o: Pixels, in r: CGRect? = nil) -> Double {
        let rect = r ?? CGRect(x: 0, y: 0, width: width, height: height)
        var sum = 0.0, n = 0.0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                let a = rgb(x, y), b = o.rgb(x, y)
                sum += Double(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)) / 3; n += 1
            }
        }
        return n == 0 ? 0 : sum / n
    }

    func isRed(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.r > 180 && c.g < 90 && c.b < 90 }
    func isGreen(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.g > 180 && c.r < 90 && c.b < 90 }
    func isBlue(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.b > 180 && c.r < 90 && c.g < 90 }
    func isBlack(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.r < 30 && c.g < 30 && c.b < 30 }
}

func frame(_ url: URL, at seconds: Double) async throws -> Pixels {
    Pixels(try await FrameGrabber.image(url: url, at: MediaTime(seconds: seconds, timescale: 600), accuracy: .exact))
}

func fr30(_ n: Int64) -> MediaTime { .frameStart(index: n, frameRate: FrameRate(numerator: 30, denominator: 1)) }
func span30(_ a: Int64, _ b: Int64) -> TimeSpan { TimeSpan(start: fr30(a), end: fr30(b)) }
