import Foundation

/// A 3D colour look read from a `.cube` file (the format colourists and camera makers share). Only the reading and the lookup live here.
public struct CubeLUT: Equatable, Sendable {
    public let title: String
    public let size: Int
    /// Red, green, blue for every grid point, red changing fastest, then green, then blue: size³ × 3 values.
    public let data: [Float]
    public let domainMin: [Double]
    public let domainMax: [Double]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case oneDimensional, noSize, badSize(Int), wrongCount(expected: Int, found: Int), badLine(Int)
        public var description: String {
            switch self {
            case .oneDimensional: return "This is a 1D look file; only 3D .cube files can be used."
            case .noSize: return "This file does not say how big the look is (LUT_3D_SIZE)."
            case .badSize(let n): return "A look of size \(n) is not supported (2 to 65)."
            case .wrongCount(let e, let f): return "The file has \(f) colours, but its size needs \(e)."
            case .badLine(let n): return "Line \(n) of the file cannot be read."
            }
        }
    }

    public init(title: String, size: Int, data: [Float], domainMin: [Double] = [0, 0, 0], domainMax: [Double] = [1, 1, 1]) {
        self.title = title; self.size = size; self.data = data; self.domainMin = domainMin; self.domainMax = domainMax
    }

    public static func parse(_ text: String) throws -> CubeLUT {
        var title = "", size = 0
        var dmin = [0.0, 0.0, 0.0], dmax = [1.0, 1.0, 1.0]
        var values: [Float] = []
        var lineNumber = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = parts.first else { continue }
            switch head.uppercased() {
            case "TITLE": title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            case "LUT_1D_SIZE": throw ParseError.oneDimensional
            case "LUT_3D_SIZE":
                guard parts.count > 1, let n = Int(parts[1]) else { throw ParseError.badLine(lineNumber) }
                guard (2...65).contains(n) else { throw ParseError.badSize(n) }
                size = n; values.reserveCapacity(n * n * n * 3)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4, let a = Double(parts[1]), let b = Double(parts[2]), let c = Double(parts[3]) else { throw ParseError.badLine(lineNumber) }
                if head.uppercased() == "DOMAIN_MIN" { dmin = [a, b, c] } else { dmax = [a, b, c] }
            default:
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    if Float(head) == nil && parts.count < 3 { continue }       // a keyword this reader does not know
                    throw ParseError.badLine(lineNumber)
                }
                values.append(contentsOf: [r, g, b])
            }
        }
        guard size > 0 else { throw ParseError.noSize }
        let expected = size * size * size * 3
        guard values.count == expected else { throw ParseError.wrongCount(expected: expected / 3, found: values.count / 3) }
        return CubeLUT(title: title, size: size, data: values, domainMin: dmin, domainMax: dmax)
    }

    /// The colour the look gives to (r, g, b), all 0...1 (trilinear between the grid points).
    public func sample(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let n = size, last = Double(n - 1)
        func pos(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max((v - lo) / max(hi - lo, 1e-9), 0), 1) * last }
        let fr = pos(r, domainMin[0], domainMax[0]), fg = pos(g, domainMin[1], domainMax[1]), fb = pos(b, domainMin[2], domainMax[2])
        let r0 = Int(fr), g0 = Int(fg), b0 = Int(fb)
        let r1 = min(r0 + 1, n - 1), g1 = min(g0 + 1, n - 1), b1 = min(b0 + 1, n - 1)
        let tr = fr - Double(r0), tg = fg - Double(g0), tb = fb - Double(b0)
        func at(_ ri: Int, _ gi: Int, _ bi: Int, _ c: Int) -> Double { Double(data[((bi * n + gi) * n + ri) * 3 + c]) }
        var out = (0.0, 0.0, 0.0)
        for c in 0..<3 {
            let c00 = at(r0, g0, b0, c) * (1 - tr) + at(r1, g0, b0, c) * tr
            let c10 = at(r0, g1, b0, c) * (1 - tr) + at(r1, g1, b0, c) * tr
            let c01 = at(r0, g0, b1, c) * (1 - tr) + at(r1, g0, b1, c) * tr
            let c11 = at(r0, g1, b1, c) * (1 - tr) + at(r1, g1, b1, c) * tr
            let v = (c00 * (1 - tg) + c10 * tg) * (1 - tb) + (c01 * (1 - tg) + c11 * tg) * tb
            switch c { case 0: out.0 = v; case 1: out.1 = v; default: out.2 = v }
        }
        return out
    }
}
