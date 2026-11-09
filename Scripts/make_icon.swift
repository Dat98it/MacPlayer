// Draws MacPlayer's own icon (no artwork from other apps) and writes Resources/AppIcon.icns.
// Every size is drawn natively as vector art (not scaled down from one big picture), so edges stay crisp on Retina;
// the smallest sizes drop the fine detail and keep only the play symbol.
// Usage: swift Scripts/make_icon.swift      (run from the project root)
import AppKit
import ImageIO

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, a])! }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)! }

/// macOS-style continuous-corner body (a superellipse, closer to Apple's icon shape than a plain rounded rectangle).
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + (r.width / 2) * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + (r.height / 2) * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// A triangle whose corners are rounded with radius `r`.
func roundedTriangle(_ pts: [CGPoint], r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2))
    for i in 1...3 { p.addArc(tangent1End: pts[i % 3], tangent2End: pts[(i + 1) % 3], radius: r) }
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    let s = CGFloat(px)
    let small = px <= 48          // 16 and 32 px: only the big shapes
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

    // The macOS icon grid: the body is 824/1024 of the canvas, centred.
    let inset = s * 0.0977
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = squircle(body)

    // 1. Soft contact shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * (small ? 0.008 : 0.014)), blur: s * (small ? 0.016 : 0.032), color: col(0, 0, 0, 0.40))
    ctx.addPath(bodyPath); ctx.setFillColor(col(0.12, 0.10, 0.45)); ctx.fillPath()
    ctx.restoreGState()

    // 2. Body: blue at the top left, violet in the middle, magenta in the lower right corner, with a light bloom on top.
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([col(0.13, 0.66, 1.0), col(0.33, 0.30, 0.98), col(0.62, 0.20, 0.88), col(0.93, 0.24, 0.66)], [0, 0.42, 0.75, 1]),
                           start: P(0.12, 0.96), end: P(0.88, 0.04), options: [])
    ctx.drawRadialGradient(gradient([col(1, 1, 1, 0.34), col(1, 1, 1, 0)], [0, 1]),
                           startCenter: P(0.3, 0.95), startRadius: 0, endCenter: P(0.3, 0.95), endRadius: s * 0.62, options: [])
    ctx.drawRadialGradient(gradient([col(1.0, 0.55, 0.35, 0.30), col(1.0, 0.55, 0.35, 0)], [0, 1]),
                           startCenter: P(0.92, 0.06), startRadius: 0, endCenter: P(0.92, 0.06), endRadius: s * 0.5, options: [])
    // 3. Hairline light edge just inside the body, brighter at the top.
    ctx.addPath(bodyPath); ctx.setLineWidth(max(1, s * 0.006) * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([col(1, 1, 1, 0.55), col(1, 1, 1, 0.06)], [0, 1]), start: P(0.5, 0.92), end: P(0.5, 0.1), options: [])
    ctx.restoreGState()

    // A photo card, drawn around its own centre and turned: white border, then the picture.
    func card(center: CGPoint, width w: CGFloat, height h: CGFloat, angle: CGFloat, alpha: CGFloat, detailed: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: angle)
        let outer = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let r = min(w, h) * 0.075
        let outerPath = CGPath(roundedRect: outer, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * (small ? 0.02 : 0.04), color: col(0.08, 0.03, 0.35, 0.5))
        ctx.addPath(outerPath); ctx.setFillColor(col(1, 1, 1, alpha)); ctx.fillPath()
        ctx.restoreGState()
        guard detailed else { ctx.restoreGState(); return }
        // The picture inside the border (wider border at the bottom, like an instant photo).
        let b = w * 0.045
        let pic = CGRect(x: -w / 2 + b, y: -h / 2 + b * 2.2, width: w - 2 * b, height: h - b * 3.2)
        let picR = r * 0.55
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: pic, cornerWidth: picR, cornerHeight: picR, transform: nil)); ctx.clip()
        ctx.drawLinearGradient(gradient([col(0.45, 0.78, 1.0), col(0.80, 0.86, 1.0), col(1.0, 0.86, 0.78)], [0, 0.6, 1]),
                               start: CGPoint(x: 0, y: pic.maxY), end: CGPoint(x: 0, y: pic.minY), options: [])
        // The sun, with a soft glow.
        let sun = CGPoint(x: pic.minX + pic.width * 0.72, y: pic.minY + pic.height * 0.70), sr = pic.height * 0.13
        ctx.drawRadialGradient(gradient([col(1, 0.95, 0.7, 0.9), col(1, 0.95, 0.7, 0)], [0, 1]), startCenter: sun, startRadius: 0, endCenter: sun, endRadius: sr * 3, options: [])
        ctx.setFillColor(col(1.0, 0.93, 0.62)); ctx.fillEllipse(in: CGRect(x: sun.x - sr, y: sun.y - sr, width: sr * 2, height: sr * 2))
        // Two mountains and a hill in front.
        func mountain(_ a: CGPoint, _ peak: CGPoint, _ c: CGPoint, _ top: CGColor, _ bottom: CGColor) {
            let m = CGMutablePath(); m.move(to: a); m.addLine(to: peak); m.addLine(to: c); m.closeSubpath()
            ctx.saveGState(); ctx.setLineJoin(.round); ctx.setLineWidth(pic.width * 0.03)
            ctx.addPath(m); ctx.setFillColor(top); ctx.setStrokeColor(top); ctx.drawPath(using: .fillStroke)
            ctx.addPath(m); ctx.clip()
            ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: peak, end: CGPoint(x: peak.x, y: pic.minY), options: [])
            ctx.restoreGState()
        }
        mountain(CGPoint(x: pic.minX - pic.width * 0.05, y: pic.minY), CGPoint(x: pic.minX + pic.width * 0.30, y: pic.minY + pic.height * 0.62), CGPoint(x: pic.minX + pic.width * 0.66, y: pic.minY), col(0.52, 0.42, 0.98), col(0.36, 0.28, 0.86))
        mountain(CGPoint(x: pic.minX + pic.width * 0.36, y: pic.minY), CGPoint(x: pic.minX + pic.width * 0.68, y: pic.minY + pic.height * 0.44), CGPoint(x: pic.maxX + pic.width * 0.05, y: pic.minY), col(0.40, 0.30, 0.90), col(0.27, 0.19, 0.72))
        ctx.restoreGState()
        ctx.restoreGState()
    }

    if small {
        card(center: P(0.46, 0.56), width: s * 0.54, height: s * 0.42, angle: -0.10, alpha: 1, detailed: false)
        // At 16 and 32 px a card is only a white shape with one mountain and the sun.
        ctx.saveGState()
        ctx.translateBy(x: s * 0.46, y: s * 0.56); ctx.rotate(by: -0.10)
        let w = s * 0.54, h = s * 0.42
        ctx.setFillColor(col(0.45, 0.78, 1.0)); ctx.fill(CGRect(x: -w * 0.42, y: -h * 0.36, width: w * 0.84, height: h * 0.70))
        ctx.setFillColor(col(0.40, 0.30, 0.92))
        let m = CGMutablePath(); m.move(to: CGPoint(x: -w * 0.42, y: -h * 0.36)); m.addLine(to: CGPoint(x: -w * 0.08, y: h * 0.18)); m.addLine(to: CGPoint(x: w * 0.22, y: -h * 0.36)); m.closeSubpath()
        ctx.addPath(m); ctx.fillPath()
        ctx.setFillColor(col(1.0, 0.93, 0.62)); ctx.fillEllipse(in: CGRect(x: w * 0.12, y: h * 0.08, width: w * 0.2, height: w * 0.2))
        ctx.restoreGState()
    } else {
        card(center: P(0.545, 0.60), width: s * 0.46, height: s * 0.355, angle: 0.15, alpha: 0.5, detailed: false)
        card(center: P(0.455, 0.575), width: s * 0.54, height: s * 0.42, angle: -0.10, alpha: 1, detailed: true)
    }

    // 4. The play badge over the lower right corner of the card: a white disc with a blue-violet triangle.
    let bc = small ? P(0.62, 0.34) : P(0.635, 0.325), br = s * (small ? 0.20 : 0.155)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.016), blur: s * (small ? 0.024 : 0.044), color: col(0.07, 0.02, 0.32, 0.55))
    ctx.setFillColor(col(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2)); ctx.clip()
    ctx.drawLinearGradient(gradient([col(1, 1, 1), col(0.90, 0.90, 1.0)], [0, 1]), start: CGPoint(x: bc.x, y: bc.y + br), end: CGPoint(x: bc.x, y: bc.y - br), options: [])
    ctx.restoreGState()
    let th = br * 0.50, tw = br * 0.86
    let left = bc.x - tw / 3
    let tri = roundedTriangle([CGPoint(x: left, y: bc.y + th), CGPoint(x: left, y: bc.y - th), CGPoint(x: left + tw, y: bc.y)], r: br * 0.13)
    ctx.saveGState()
    ctx.addPath(tri); ctx.clip()
    ctx.drawLinearGradient(gradient([col(0.20, 0.52, 1.0), col(0.56, 0.24, 0.92)], [0, 1]), start: CGPoint(x: left, y: bc.y + th), end: CGPoint(x: left + tw, y: bc.y - th), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { throw CocoaError(.fileWriteUnknown) }
}

let fm = FileManager.default
let set = "build/AppIcon.iconset"
try? fm.removeItem(atPath: set)
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try writePNG(render(px), to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
