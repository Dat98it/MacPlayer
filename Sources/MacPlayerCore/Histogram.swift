import Foundation

/// How the brightness of a picture is spread: how many pixels have each of the 256 levels of red, green, blue and of overall brightness.
/// Shown while grading, so a person can see a picture that is too dark, too bright or has lost detail at either end.
public struct Histogram: Equatable, Sendable {
    public var red = [Int](repeating: 0, count: 256)
    public var green = [Int](repeating: 0, count: 256)
    public var blue = [Int](repeating: 0, count: 256)
    public var luma = [Int](repeating: 0, count: 256)
    public var pixels = 0
    public init() {}

    /// Counts the pixels of an 8-bit picture. `bytes` holds `width × height` pixels of 4 bytes each; `order` says where red, green and blue are
    /// in a pixel (RGBA: 0,1,2; BGRA: 2,1,0).
    public static func compute(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int, red: Int = 0, green: Int = 1, blue: Int = 2) -> Histogram {
        var h = Histogram()
        guard width > 0, height > 0, bytesPerRow >= width * 4, bytes.count >= bytesPerRow * (height - 1) + width * 4 else { return h }
        for y in 0..<height {
            var i = y * bytesPerRow
            for _ in 0..<width {
                let r = Int(bytes[i + red]), g = Int(bytes[i + green]), b = Int(bytes[i + blue])
                h.red[r] += 1; h.green[g] += 1; h.blue[b] += 1
                h.luma[min(255, (2126 * r + 7152 * g + 722 * b + 5000) / 10000)] += 1
                i += 4
            }
        }
        h.pixels = width * height
        return h
    }

    /// The counts of one channel as heights 0...1, the tallest bar being 1 (a spike at the very end is not allowed to flatten the rest:
    /// the heights are measured against the tallest of the bars inside 2...253, or the very tallest when those are empty).
    public func heights(of counts: [Int]) -> [Double] {
        let inner = counts[2..<254].max() ?? 0
        let top = Double(max(inner > 0 ? inner : (counts.max() ?? 1), 1))
        return counts.map { min(Double($0) / top, 1) }
    }

    /// The part of the picture (0...1) that is pure black or pure white in every channel, i.e. has lost its detail there.
    public var clippedDark: Double { pixels > 0 ? Double(min(red[0], green[0], blue[0])) / Double(pixels) : 0 }
    public var clippedLight: Double { pixels > 0 ? Double(min(red[255], green[255], blue[255])) / Double(pixels) : 0 }
}
