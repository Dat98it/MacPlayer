import Foundation

/// How the finer colour tools change one colour. The renderer asks this for every point of a small colour cube and lets the graphics
/// card look colours up in it, so a whole picture is graded in one step, in the preview and in the export alike.
/// Colours are red, green, blue in 0...1 as the picture stores them (not linear light).
public enum ColorGrading {
    /// The settings made ready: curve tables worked out once, and which steps are needed at all.
    public struct Plan {
        let c: ColorAdjust
        let master: [Double]?, red: [Double]?, green: [Double]?, blue: [Double]?
        let useWheels: Bool, useHSL: Bool
        let lut: CubeLUT?

        public init(_ c: ColorAdjust, lut: CubeLUT? = nil) {
            self.c = c
            func table(_ p: [CurvePoint]) -> [Double]? { p.isEmpty ? nil : CurveMath.table(p, size: 1024) }
            master = table(c.curves.master); red = table(c.curves.red); green = table(c.curves.green); blue = table(c.curves.blue)
            useWheels = !c.wheels.isNeutral
            useHSL = !c.hsl.isNeutral
            self.lut = c.lut == nil ? nil : lut
        }

        func look(_ t: [Double], _ v: Double) -> Double {
            let f = min(max(v, 0), 1) * Double(t.count - 1)
            let i = Int(f), j = min(i + 1, t.count - 1)
            return t[i] + (t[j] - t[i]) * (f - Double(i))
        }

        public func transform(_ r0: Double, _ g0: Double, _ b0: Double) -> (Double, Double, Double) {
            var r = r0, g = g0, b = b0
            func clamp01() { r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1) }
            // Exposure: brighter or darker by up to two stops (worked on the stored values, so about a fifth of a stop per 0.1 less in value).
            if c.exposure != 0 {
                let k = pow(2, c.exposure * 2 / 2.2)
                r *= k; g *= k; b *= k
                clamp01()
            }
            // Shadows lift or deepen the dark parts, highlights bring down or push up the light parts.
            if c.shadows != 0 || c.highlights != 0 {
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let dark = (1 - l) * (1 - l), light = l * l
                let d = c.shadows * 0.3 * dark + c.highlights * 0.3 * light
                r += d; g += d; b += d
                clamp01()
            }
            if c.tint != 0 { r += 0.05 * c.tint; b += 0.05 * c.tint; g -= 0.0352 * c.tint; clamp01() }
            if c.vibrance != 0 {
                let (h, s0, v) = Self.rgbToHSV(r, g, b)
                let s = min(max(s0 * (1 + c.vibrance * (1 - s0)), 0), 1)
                (r, g, b) = Self.hsvToRGB(h, s, v)
            }
            if master != nil || red != nil || green != nil || blue != nil {
                if let m = master { r = look(m, r); g = look(m, g); b = look(m, b) }
                if let t = red { r = look(t, r) }
                if let t = green { g = look(t, g) }
                if let t = blue { b = look(t, b) }
            }
            if useWheels {
                let l = min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1)
                let ws = (1 - l) * (1 - l), wh = l * l, wm = max(0, 1 - ws - wh)
                for (wheel, w) in [(c.wheels.shadows, ws), (c.wheels.midtones, wm), (c.wheels.highlights, wh)] where !wheel.isNeutral {
                    let wl = wheel.clamped()
                    let tint = Self.wheelTint(wl)
                    r += (tint.0 * 0.35 + wl.luma * 0.25) * w
                    g += (tint.1 * 0.35 + wl.luma * 0.25) * w
                    b += (tint.2 * 0.35 + wl.luma * 0.25) * w
                }
                clamp01()
            }
            if useHSL {
                var (h, s, v) = Self.rgbToHSV(r, g, b)
                if s > 0.0005 {
                    var dh = 0.0, ds = 0.0, dv = 0.0
                    for band in HSLBand.allCases {
                        let a = c.hsl[band]
                        if a.isNeutral { continue }
                        var d = abs(h - band.centerDegrees)
                        if d > 180 { d = 360 - d }
                        let width = 40.0
                        guard d < width else { continue }
                        let w = 0.5 * (1 + cos(Double.pi * d / width))
                        dh += w * a.hue * 30; ds += w * a.saturation; dv += w * a.luminance
                    }
                    h = (h + dh).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
                    s = min(max(s * (1 + min(max(ds, -1), 1)), 0), 1)
                    v = min(max(v + min(max(dv, -1), 1) * 0.3 * s, 0), 1)
                    (r, g, b) = Self.hsvToRGB(h, s, v)
                }
            }
            if let lut, let ref = c.lut {
                let (lr, lg, lb) = lut.sample(r: r, g: g, b: b)
                let k = min(max(ref.strength, 0), 1)
                r += (lr - r) * k; g += (lg - g) * k; b += (lb - b) * k
            }
            clamp01()
            return (r, g, b)
        }

        /// What a wheel adds to red, green and blue: the colour in its direction, with the same total (so the tint does not change brightness).
        static func wheelTint(_ w: ColorWheel) -> (Double, Double, Double) {
            guard w.amount > 1e-6 else { return (0, 0, 0) }
            let (hr, hg, hb) = hsvToRGB(w.hue * 360, 1, 1)
            let mean = (hr + hg + hb) / 3
            return ((hr - mean) * w.amount, (hg - mean) * w.amount, (hb - mean) * w.amount)
        }

        static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            var h = 0.0
            if d > 1e-9 {
                if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == g { h = 60 * ((b - r) / d + 2) }
                else { h = 60 * ((r - g) / d + 4) }
                if h < 0 { h += 360 }
            }
            return (h, mx <= 1e-9 ? 0 : d / mx, mx)
        }

        static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
            let c = v * s, hp = (h.truncatingRemainder(dividingBy: 360)) / 60
            let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
            let (r, g, b): (Double, Double, Double)
            switch Int(hp) {
            case 0: (r, g, b) = (c, x, 0)
            case 1: (r, g, b) = (x, c, 0)
            case 2: (r, g, b) = (0, c, x)
            case 3: (r, g, b) = (0, x, c)
            case 4: (r, g, b) = (x, 0, c)
            default: (r, g, b) = (c, 0, x)
            }
            return (r + m, g + m, b + m)
        }
    }

    /// The colour cube for `c`: `size`³ points, 4 floats each (red, green, blue, 1), red changing fastest, in the order Core Image reads.
    public static func cube(for c: ColorAdjust, lut: CubeLUT? = nil, size: Int = 33) -> [Float] {
        let plan = Plan(c, lut: lut)
        var out = [Float](repeating: 1, count: size * size * size * 4)
        let last = Double(size - 1)
        var i = 0
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    let (r, g, b) = plan.transform(Double(ri) / last, Double(gi) / last, Double(bi) / last)
                    out[i] = Float(r); out[i + 1] = Float(g); out[i + 2] = Float(b)
                    i += 4
                }
            }
        }
        return out
    }
}
