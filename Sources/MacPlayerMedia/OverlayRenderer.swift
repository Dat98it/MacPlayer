import CoreGraphics
import CoreImage
import CoreText
import Foundation
import MacPlayerCore

/// Draws text (titles, captions, subtitles) into transparent images the compositor lays over the video.
/// Pure CoreGraphics/CoreText with no AppKit, so preview and export draw exactly the same pixels.
enum OverlayRenderer {
    static func color(hex: String, alpha: CGFloat = 1) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: CGFloat
        if s.count == 6 { r = CGFloat((v >> 16) & 255) / 255; g = CGFloat((v >> 8) & 255) / 255; b = CGFloat(v & 255) / 255 }
        else { r = 1; g = 1; b = 1 }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    struct TextBox {
        var text: String
        var fontName: String
        var sizeFraction: Double
        var colorHex: String
        var outlineHex: String?
        var backgroundHex: String?
        var alignment: TextAlignmentChoice
        /// Centre of the box (normalised, top-left origin) for overlays; nil = bottom-anchored (subtitles).
        var centerX: Double
        var centerY: Double?
        var bottomMargin: Double
        /// Outline thickness as a fraction of the letter size (nil = the usual 6% when there is an outline colour).
        var outlineWidth: Double? = nil
        var shadow = false
        var shadowHex = "#000000"
        var letterSpacing = 0.0
        var uppercase = false
        /// How much of the text shows, 0...1 (the typewriter). The rest is laid out but not drawn, so the text does not shift as it grows.
        var reveal = 1.0
    }

    /// A transparent image of `size` with the text drawn in it. Returns nil for empty text.
    static func render(_ box: TextBox, size: CGSize) -> CGImage? {
        var text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if box.uppercase { text = text.uppercased() }
        guard !text.isEmpty, size.width > 8, size.height > 8 else { return nil }
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        let fontSize = max(8, CGFloat(box.sizeFraction) * size.height)
        let font = CTFontCreateWithName(box.fontName as CFString, fontSize, nil)
        let para: CTParagraphStyle = {
            var a: CTTextAlignment = box.alignment == .left ? .left : box.alignment == .right ? .right : .center
            return withUnsafeMutablePointer(to: &a) { p in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: p)
                return CTParagraphStyleCreate(&setting, 1)
            }
        }()
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex: box.colorHex),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ]
        if box.letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = box.letterSpacing * fontSize }
        let strokeFraction = box.outlineWidth ?? 0.06
        if let outline = box.outlineHex, strokeFraction > 0 {
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color(hex: outline)
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -(fontSize * strokeFraction) // negative: fill and stroke
        }
        let attributed = NSMutableAttributedString(string: text, attributes: attrs)
        if box.reveal < 1 {
            // The letters not yet shown are drawn in no colour at all.
            let shown = Int(ceil(Double(text.count) * max(0, box.reveal)))
            if shown < text.count {
                let from = text.index(text.startIndex, offsetBy: shown)
                let range = NSRange(from..<text.endIndex, in: text)
                attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: CGColor(gray: 0, alpha: 0), range: range)
                attributed.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: CGColor(gray: 0, alpha: 0), range: range)
            }
        }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let (rect, pad) = layout(box, setter: setter, fontSize: fontSize, size: size)

        if let bg = box.backgroundHex {
            ctx.setFillColor(color(hex: bg, alpha: 0.65))
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -pad, dy: -pad), cornerWidth: pad, cornerHeight: pad, transform: nil))
            ctx.fillPath()
        }
        if box.shadow { ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.28, color: color(hex: box.shadowHex, alpha: 0.95)) }
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// Where the text goes in a picture of `size` (CG coordinates, origin bottom-left), and the padding of its background.
    static func layout(_ box: TextBox, setter: CTFramesetter, fontSize: CGFloat, size: CGSize) -> (CGRect, CGFloat) {
        // Wrap within 90% of the width (leave the safe margin).
        let maxWidth = size.width * 0.9
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: size.height), nil)
        let boxW = min(maxWidth, ceil(fit.width) + fontSize * 0.2), boxH = ceil(fit.height)
        let pad = box.backgroundHex == nil ? 0 : fontSize * 0.25
        let cx = CGFloat(box.centerX) * size.width
        let originY: CGFloat
        if let cy = box.centerY { originY = (1 - CGFloat(cy)) * size.height - boxH / 2 } else { originY = CGFloat(box.bottomMargin) * size.height + pad }
        var rect = CGRect(x: cx - boxW / 2, y: originY, width: boxW, height: boxH)
        // Keep inside the picture.
        rect.origin.x = min(max(rect.origin.x, 0), size.width - rect.width)
        rect.origin.y = min(max(rect.origin.y, pad), size.height - rect.height - pad)
        return (rect, pad)
    }

    /// The box an element covers in a picture of `size` before it is moved, scaled or turned by its animation: as fractions of the picture,
    /// from the top-left. Nil for an empty text. (For the handles drawn over the picture.)
    public static func elementRect(_ o: TextOverlay, size: CGSize) -> CGRect? {
        if let shape = o.shape {
            return CGRect(x: o.x - shape.width / 2, y: o.y - shape.height / 2, width: shape.width, height: shape.height)
        }
        let box = box(for: o)
        var text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if box.uppercase { text = text.uppercased() }
        guard !text.isEmpty, size.width > 8, size.height > 8 else { return nil }
        let fontSize = max(8, CGFloat(box.sizeFraction) * size.height)
        let font = CTFontCreateWithName(box.fontName as CFString, fontSize, nil)
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if box.letterSpacing != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = box.letterSpacing * fontSize }
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let (r, pad) = layout(box, setter: setter, fontSize: fontSize, size: size)
        let outer = r.insetBy(dx: -pad, dy: -pad)
        return CGRect(x: outer.minX / size.width, y: 1 - outer.maxY / size.height, width: outer.width / size.width, height: outer.height / size.height)
    }

    // MARK: Shapes

    /// A shape drawn in a transparent picture of `size`, centred at (`centerX`, `centerY`) (0...1 from the top-left).
    static func renderShape(_ spec: ShapeSpec, centerX: Double, centerY: Double, size: CGSize) -> CGImage? {
        guard size.width > 8, size.height > 8 else { return nil }
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let bw = max(1, spec.width * size.width), bh = max(1, spec.height * size.height)
        let rect = CGRect(x: centerX * size.width - bw / 2, y: (1 - centerY) * size.height - bh / 2, width: bw, height: bh)
        let path = shapePath(spec.kind, in: rect)
        if let fill = spec.fillHex { ctx.setFillColor(color(hex: fill)); ctx.addPath(path); ctx.fillPath(using: spec.kind == .ring ? .evenOdd : .winding) }
        if let stroke = spec.strokeHex, spec.strokeWidth > 0 {
            ctx.setStrokeColor(color(hex: stroke)); ctx.setLineWidth(max(1, spec.strokeWidth * size.height)); ctx.setLineJoin(.round)
            ctx.addPath(path); ctx.strokePath()
        }
        return ctx.makeImage()
    }

    /// The outline of a shape that fills `r` (CG coordinates, origin bottom-left).
    static func shapePath(_ kind: ShapeKind, in r: CGRect) -> CGPath {
        // Points are given in a unit square with the origin at the top-left, then placed in `r`.
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.maxY - CGFloat(y) * r.height) }
        let p = CGMutablePath()
        func poly(_ q: [(Double, Double)]) { for (i, v) in q.enumerated() { i == 0 ? p.move(to: pt(v.0, v.1)) : p.addLine(to: pt(v.0, v.1)) }; p.closeSubpath() }
        func regular(_ n: Int, rotation: Double) {
            for i in 0..<n { let a = rotation + Double(i) * 2 * Double.pi / Double(n); let q = pt(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5); i == 0 ? p.move(to: q) : p.addLine(to: q) }
            p.closeSubpath()
        }
        switch kind {
        case .rectangle, .line: p.addRect(r)
        case .roundedRectangle: let c = min(r.width, r.height) * 0.2; p.addRoundedRect(in: r, cornerWidth: c, cornerHeight: c)
        case .ellipse: p.addEllipse(in: r)
        case .triangle: p.move(to: pt(0.5, 0)); p.addLine(to: pt(1, 1)); p.addLine(to: pt(0, 1)); p.closeSubpath()
        case .star:
            for i in 0..<10 {
                let a = -Double.pi / 2 + Double(i) * Double.pi / 5, rad = i % 2 == 0 ? 0.5 : 0.21
                let q = pt(0.5 + cos(a) * rad * 1.0, 0.5 + sin(a) * rad * 1.0)
                i == 0 ? p.move(to: q) : p.addLine(to: q)
            }
            p.closeSubpath()
        case .heart:
            p.move(to: pt(0.5, 0.95))
            p.addCurve(to: pt(0.04, 0.36), control1: pt(0.34, 0.82), control2: pt(0.04, 0.62))
            p.addCurve(to: pt(0.5, 0.2), control1: pt(0.04, 0.12), control2: pt(0.4, 0.06))
            p.addCurve(to: pt(0.96, 0.36), control1: pt(0.6, 0.06), control2: pt(0.96, 0.12))
            p.addCurve(to: pt(0.5, 0.95), control1: pt(0.96, 0.62), control2: pt(0.66, 0.82))
            p.closeSubpath()
        case .arrow:
            for (i, q) in [(0.0, 0.3), (0.6, 0.3), (0.6, 0.02), (1.0, 0.5), (0.6, 0.98), (0.6, 0.7), (0.0, 0.7)].enumerated() { i == 0 ? p.move(to: pt(q.0, q.1)) : p.addLine(to: pt(q.0, q.1)) }
            p.closeSubpath()
        case .diamond: poly([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case .pentagon: regular(5, rotation: -Double.pi / 2)
        case .hexagon: regular(6, rotation: 0)
        case .speechBubble:
            // A rounded box with a tail at its lower left.
            let box = CGRect(x: r.minX, y: r.minY + r.height * 0.22, width: r.width, height: r.height * 0.78)
            let c = min(box.width, box.height) * 0.22
            p.addRoundedRect(in: box, cornerWidth: c, cornerHeight: c)
            p.move(to: pt(0.2, 0.7)); p.addLine(to: pt(0.12, 1)); p.addLine(to: pt(0.42, 0.7)); p.closeSubpath()
        case .burst:
            for i in 0..<24 {
                let a = -Double.pi / 2 + Double(i) * Double.pi / 12, rad = i % 2 == 0 ? 0.5 : 0.4
                let q = pt(0.5 + cos(a) * rad, 0.5 + sin(a) * rad)
                i == 0 ? p.move(to: q) : p.addLine(to: q)
            }
            p.closeSubpath()
        case .checkmark: poly([(0.04, 0.55), (0.38, 0.9), (0.97, 0.2), (0.84, 0.08), (0.38, 0.62), (0.17, 0.42)])
        case .cross: poly([(0.36, 0), (0.64, 0), (0.64, 0.36), (1, 0.36), (1, 0.64), (0.64, 0.64), (0.64, 1), (0.36, 1), (0.36, 0.64), (0, 0.64), (0, 0.36), (0.36, 0.36)])
        case .ring:
            // Filled with the even-odd rule: the inner circle stays empty.
            p.addEllipse(in: r)
            p.addEllipse(in: r.insetBy(dx: r.width * 0.16, dy: r.height * 0.16))
        }
        return p
    }

    static func box(for o: TextOverlay, reveal: Double = 1) -> TextBox {
        let f = o.flair
        // No outline when it is switched off (width 0); otherwise the chosen colour, or black on plain text as always.
        let outline: String? = f?.outlineWidth == 0 ? nil : (f?.outlineHex ?? (o.backgroundHex == nil ? "#000000" : nil))
        return TextBox(text: o.text, fontName: o.fontName, sizeFraction: o.sizeFraction, colorHex: o.colorHex, outlineHex: outline,
                       backgroundHex: o.backgroundHex, alignment: o.alignment, centerX: o.x, centerY: o.y, bottomMargin: 0,
                       outlineWidth: f?.outlineWidth, shadow: f?.shadow ?? false, shadowHex: f?.shadowHex ?? "#000000",
                       letterSpacing: f?.letterSpacing ?? 0, uppercase: f?.uppercase ?? false, reveal: reveal)
    }

    static func box(for cue: SubtitleCue, style: SubtitleStyle) -> TextBox {
        TextBox(text: cue.plainText, fontName: style.fontName, sizeFraction: style.sizeFraction, colorHex: style.colorHex, outlineHex: style.outlineHex,
                backgroundHex: style.backgroundHex, alignment: style.alignment, centerX: 0.5, centerY: nil, bottomMargin: style.bottomMargin)
    }
}

/// Where elements sit on the picture, for drawing their handles (the app layer cannot see the renderer itself).
public enum ElementGeometry {
    /// The box of an element before its animation moves, scales or turns it: fractions of the picture, from the top-left.
    public static func baseRect(_ o: TextOverlay, pictureSize: CGSize) -> CGRect? { OverlayRenderer.elementRect(o, size: pictureSize) }
}
