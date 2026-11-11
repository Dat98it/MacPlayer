import Foundation

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// How big the exported picture is. One place, used by the preview, the export and the size estimate.
public enum RenderGeometry {
    /// Size of the source after the user's crop and rotation (before it is fitted to a canvas).
    public static func editedSize(source: PixelSize, look: VideoLook) -> PixelSize {
        let c = look.crop.clamped()
        var w = Double(source.width) * c.width, h = Double(source.height) * c.height
        if look.rotation % 180 != 0 { swap(&w, &h) }
        return PixelSize(width: max(2, Int(w.rounded())), height: max(2, Int(h.rounded())))
    }

    /// Output frame size: the canvas (if one is chosen) built from the edited size's shorter side, or the edited
    /// size itself; scaled down to `maxHeight` when given (never up); always even, as video encoders require.
    ///
    /// `limitsShortSide`: the limit is for the shorter side (an export: "1080p" for a tall 9:16 video is 1080 × 1920, as every phone and social
    /// network means it; 0.14). Without it the height is limited (the preview, which stays light).
    public static func outputSize(source: PixelSize, look: VideoLook, maxHeight: Int? = nil, limitsShortSide: Bool = false) -> PixelSize {
        let edited = editedSize(source: source, look: look)
        var w = Double(edited.width), h = Double(edited.height)
        if let aspect = look.canvas.aspect {
            let short = Double(min(edited.width, edited.height))
            if aspect >= 1 { w = short * aspect; h = short } else { w = short; h = short / aspect }
        }
        let measured = limitsShortSide ? min(w, h) : h
        if let limit = maxHeight, measured > Double(limit) {
            let k = Double(limit) / measured
            w *= k; h *= k
        }
        return PixelSize(width: even(w), height: even(h))
    }

    /// Nearest even number (encoders need even sizes).
    public static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    /// Where the edited picture lands inside the canvas: scaled to fit (letterbox) or fill (cover, cropping the
    /// overflow), centred. Origin top-left.
    public static func placement(edited: PixelSize, canvas: PixelSize, fit: FitMode) -> (x: Double, y: Double, width: Double, height: Double) {
        let sx = Double(canvas.width) / Double(edited.width), sy = Double(canvas.height) / Double(edited.height)
        let k = fit == .fit ? min(sx, sy) : max(sx, sy)
        let w = Double(edited.width) * k, h = Double(edited.height) * k
        return ((Double(canvas.width) - w) / 2, (Double(canvas.height) - h) / 2, w, h)
    }
}

/// Overlays and subtitle cues are written in the source's time. A clip exported on its own starts at 0,
/// so everything is shifted and trimmed to the clip (design section 11: output matches the preview).
public enum RecipeBuilder {
    public static func recipe(look: VideoLook, audio: AudioSettings, overlays: [TextOverlay], subtitles: SubtitleDocument, burnIn: Bool, span: TimeSpan, soundClips: [SoundClip] = []) -> RenderRecipe {
        var shifted: [TextOverlay] = []
        for o in overlays where o.end > span.start && o.start < span.end {
            var n = o
            n.start = max(o.start, span.start) - span.start
            n.end = min(o.end, span.end) - span.start
            shifted.append(n)
        }
        let cues = burnIn ? subtitles.cues(in: span) : []
        let sounds = soundClips.compactMap { $0.cropped(to: span, speed: look.speed) }
        return RenderRecipe(look: look, audio: audio, overlays: shifted, subtitleStyle: subtitles.style, burnedInCues: cues, soundClips: sounds)
    }
}

extension RecipeBuilder {
    /// Several ranges joined into one file: each overlay/cue is clipped to every range it touches and moved to where that
    /// range sits in the output.
    public static func joinedRecipe(look: VideoLook, audio: AudioSettings, overlays: [TextOverlay], subtitles: SubtitleDocument, burnIn: Bool, spans: [TimeSpan], soundClips: [SoundClip] = []) -> RenderRecipe {
        var out = RenderRecipe(look: look, audio: audio, subtitleStyle: subtitles.style)
        var offset = MediaTime.zero, soundOffset = MediaTime.zero
        for span in spans {
            let part = recipe(look: look, audio: audio, overlays: overlays, subtitles: subtitles, burnIn: burnIn, span: span)
            for var o in part.overlays { o.start = o.start + offset; o.end = o.end + offset; o.id = UUID(); out.overlays.append(o) }
            for var c in part.burnedInCues { c.start = c.start + offset; c.end = c.end + offset; c.id = UUID(); out.burnedInCues.append(c) }
            for c in soundClips { if var n = c.cropped(to: span, speed: look.speed, offset: soundOffset) { n.id = UUID(); out.soundClips.append(n) } }
            soundOffset = soundOffset + MediaTime(seconds: span.duration.seconds / max(VideoLook.minimumSpeed, look.speed), timescale: 6000)
            offset = offset + span.duration
        }
        return out
    }
}
