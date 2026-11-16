import CoreImage
import ImageIO
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// 0.20: captions drawn with the word being said marked, the same in every frame that shows the same word.
@Suite(.serialized) struct CaptionRenderTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let size = CGSize(width: 540, height: 960)

    /// "MỘT HAI BA" from 0 to 3 s, a word a second.
    private func cue() -> SubtitleCue {
        var c = SubtitleCue(start: .zero, end: MediaTime(seconds: 3), text: "một hai ba")
        c.words = [CaptionWord(text: "một", start: 0, end: 0.9), CaptionWord(text: "hai", start: 1, end: 1.9), CaptionWord(text: "ba", start: 2, end: 2.9)]
        return c
    }

    private func layer(_ look: CaptionLook) -> OverlayLayer {
        var st = SubtitleStyle(); st.caption = CaptionStyle(look: look, highlightHex: "#FFE000")
        return OverlayLayer(overlays: [], cues: [cue()], style: st)
    }

    /// The pixels of the caption at `t`: how many are yellow, and the left and right ends of the yellow ones.
    private func yellow(_ l: OverlayLayer, at t: Double) -> (count: Int, minX: Int, maxX: Int, inked: Int) {
        guard let (img, _, _) = l.visible(at: t, size: size).first else { return (0, 0, 0, 0) }
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(img, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        var n = 0, lo = w, hi = 0, inked = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if px[i + 3] > 200 { inked += 1 }
            if px[i + 3] > 200, px[i] > 200, px[i + 1] > 180, px[i + 2] < 80 { n += 1; lo = min(lo, x); hi = max(hi, x) }
        } }
        return (n, lo, hi, inked)
    }

    @Test func theWordBeingSaidIsInTheHighlightColour() {
        let l = layer(.highlight)
        let first = yellow(l, at: 0.5), second = yellow(l, at: 1.5), third = yellow(l, at: 2.5)
        #expect(first.count > 200 && second.count > 200 && third.count > 200, "\(first) \(second) \(third)")
        #expect(first.maxX < second.minX && second.maxX < third.minX, "the mark moves from word to word, left to right")
        #expect(yellow(layer(.bold), at: 1.5).count < 20, "the bold look marks no word")
    }

    @Test func theBoxLookFillsABoxBehindTheWord() {
        let box = yellow(layer(.box), at: 1.5), plain = yellow(layer(.highlight), at: 1.5)
        #expect(box.count > plain.count * 2, "a filled box has far more colour than the letters alone: \(box.count) vs \(plain.count)")
    }

    @Test func oneWordShowsOnlyThatWordAndPopsIn() {
        let l = layer(.oneWord)
        let early = yellow(l, at: 1.01), settled = yellow(l, at: 1.5)
        #expect(settled.count > 200)
        #expect(early.maxX - early.minX < settled.maxX - settled.minX, "smaller while it pops in")
        #expect(l.visible(at: 1.5, size: size).count == 1)
    }

    @Test func framesWithTheSameWordAreTheSamePicture() {
        let l = layer(.highlight)
        let a = l.captionState(cue(), CaptionStyle(look: .highlight), at: 1.2), b = l.captionState(cue(), CaptionStyle(look: .highlight), at: 1.8)
        #expect(a.word == b.word && a.scale == b.scale)
        #expect(l.captionState(cue(), CaptionStyle(look: .highlight), at: 2.1).word == 2)
    }
}

extension CaptionRenderTests {
    /// With MACPLAYER_SHOTS=<dir>: a picture of every look, to look at (not a check).
    @Test func picturesOfEveryLook() throws {
        guard let dir = ProcessInfo.processInfo.environment["MACPLAYER_SHOTS"] else { return }
        let size = CGSize(width: 1080, height: 1920)
        var c = SubtitleCue(start: .zero, end: MediaTime(seconds: 3), text: "Hôm nay mình sẽ hướng dẫn")
        c.words = (0..<5).map { CaptionWord(text: ["Hôm", "nay", "mình", "sẽ", "hướng"][$0], start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.45) }
        c.text = "Hôm nay mình sẽ hướng"
        for look in CaptionLook.allCases {
            var st = SubtitleStyle(); st.caption = CaptionStyle(look: look)
            let l = OverlayLayer(overlays: [], cues: [c], style: st)
            let bg = CIImage(color: CIColor(red: 0.3, green: 0.45, blue: 0.6)).cropped(to: CGRect(origin: .zero, size: size))
            let img = (l.visible(at: 1.2, size: size).first?.0 ?? bg).composited(over: bg)
            let cg = ctx.createCGImage(img, from: CGRect(origin: .zero, size: size))!
            let url = URL(fileURLWithPath: dir).appendingPathComponent("caption-\(look.rawValue).png")
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
        }
    }
}
