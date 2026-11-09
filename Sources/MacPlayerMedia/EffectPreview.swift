import CoreImage
import Foundation
import MacPlayerCore

/// Small pictures for the interface: how a frame would look with a set of effects. Drawn by the same recipes as the export.
public enum EffectPreview {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public static func image(from frame: CGImage, effects: LookEffects) -> CGImage? {
        let source = CIImage(cgImage: frame)
        let out = LookEffectsRenderer.apply(effects, to: source, frame: source.extent)
        return context.createCGImage(out, from: source.extent)
    }

    /// How a frame would look with a set of colour settings (the same recipes as the export).
    public static func image(from frame: CGImage, colour: ColorAdjust) -> CGImage? {
        let source = CIImage(cgImage: frame)
        return context.createCGImage(ColorGradeRenderer.apply(colour, to: source), from: source.extent)
    }

    /// A small picture of a transition part way through, between two frames (the second is scaled to the first's size).
    public static func transition(from a: CGImage, to b: CGImage, kind: TransitionKind, progress: Double) -> CGImage? {
        let ia = CIImage(cgImage: a)
        var ib = CIImage(cgImage: b)
        let frame = ia.extent
        if ib.extent.size != frame.size {
            ib = ib.transformed(by: CGAffineTransform(scaleX: frame.width / ib.extent.width, y: frame.height / ib.extent.height))
        }
        let out = TransitionRenderer.blend(outgoing: ia, incoming: ib, kind: kind, progress: progress, frame: frame)
        return context.createCGImage(out, from: frame)
    }
}

/// A small picture of how a text template looks, on a dark card.
public enum TextPreview {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public static func image(for template: TextTemplate, sample: String = "Aa", size: CGSize = CGSize(width: 240, height: 135)) -> CGImage? {
        var o = TextOverlay(text: sample, start: .zero, end: MediaTime(seconds: 1), x: 0.5, y: 0.5, fade: 0)
        template.apply(to: &o)
        o.x = 0.5; o.y = 0.5; o.alignment = .center
        o.sizeFraction = min(0.34, max(0.18, o.sizeFraction * 3))
        guard let text = OverlayRenderer.render(OverlayRenderer.box(for: o), size: size) else { return nil }
        let card = CIImage(color: CIColor(red: 0.16, green: 0.17, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: size))
        return context.createCGImage(CIImage(cgImage: text).composited(over: card), from: card.extent)
    }
}
