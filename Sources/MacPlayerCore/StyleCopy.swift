import Foundation

// MARK: Copying the look of one clip or text to others (0.21)

/// The look of a clip, copied to be pasted on others, part by part.
public struct ClipStyle: Equatable, Sendable {
    public enum Part: String, CaseIterable, Sendable { case color, effects, frame, speed, transition, motion }
    public var look: VideoLook
    public init(_ look: VideoLook) { self.look = look }

    /// The parts that differ from an untouched clip (what is worth pasting).
    public var changedParts: Set<Part> {
        let n = VideoLook()
        var s: Set<Part> = []
        if look.color != n.color { s.insert(.color) }
        if look.effects != n.effects { s.insert(.effects) }
        if look.canvas != n.canvas || look.clipCanvas != nil || look.fit != n.fit || look.backdropHex != nil { s.insert(.frame) }
        if look.speed != 1 { s.insert(.speed) }
        if look.transitionIn != nil { s.insert(.transition) }
        if !look.motion.isEmpty { s.insert(.motion) }
        return s
    }

    public func apply(_ parts: Set<Part>, to l: inout VideoLook) {
        if parts.contains(.color) { l.color = look.color }
        if parts.contains(.effects) { l.effects = look.effects }
        if parts.contains(.frame) { l.canvas = look.canvas; l.clipCanvas = look.clipCanvas; l.fit = look.fit; l.backdropHex = look.backdropHex }
        if parts.contains(.speed) { l.speed = look.speed }
        if parts.contains(.transition) { l.transitionIn = look.transitionIn }
        if parts.contains(.motion) { l.motion = look.motion }
    }

    /// Pastes on clips `ids`. A new speed changes a clip's length: with `ripple`, what lies over the timeline follows (as when the speed
    /// is set by hand). Returns how many clips changed.
    @discardableResult
    public func paste(_ parts: Set<Part>, to ids: Set<UUID>, in p: inout Project, ripple: Bool) -> Int {
        var changed = 0
        for id in p.timeline.map(\.id) where ids.contains(id) {
            guard let i = p.timeline.firstIndex(where: { $0.id == id }) else { continue }
            let before = p.timeline
            var l = p.timeline[i].look
            apply(parts, to: &l)
            guard l != p.timeline[i].look else { continue }
            p.timeline[i].look = l
            if ripple, before[i].look.speed != l.speed { TimelineRipple.followSpeed(of: id, before: before, in: &p) }
            changed += 1
        }
        return changed
    }
}

/// The look of a text (or a shape), copied to be pasted on others: never its words, place, size on the timeline or shape kind.
public struct TextStyle: Equatable, Sendable {
    public var source: TextOverlay
    public init(_ o: TextOverlay) { source = o }

    /// Pastes on `o`. Text to text: font, size, colours, background, alignment, style (outline, shadow, spacing, capitals), arrive/leave
    /// animations and motion. Shape to shape: fill, outline and the animations. Between a text and a shape only the animations.
    public func apply(to o: inout TextOverlay) {
        let s = source
        o.animationIn = s.animationIn; o.animationOut = s.animationOut; o.loop = s.loop; o.fade = s.fade
        switch (s.shape, o.shape) {
        case (nil, nil):
            o.fontName = s.fontName; o.sizeFraction = s.sizeFraction; o.colorHex = s.colorHex; o.backgroundHex = s.backgroundHex
            o.alignment = s.alignment; o.flair = s.flair
        case (let a?, var b?):
            b.fillHex = a.fillHex; b.strokeHex = a.strokeHex; b.strokeWidth = a.strokeWidth
            o.shape = b
        default: break
        }
    }

    @discardableResult
    public func paste(to ids: Set<UUID>, in p: inout Project) -> Int {
        var changed = 0
        for i in p.overlays.indices where ids.contains(p.overlays[i].id) && p.overlays[i].id != source.id {
            var o = p.overlays[i]
            apply(to: &o)
            if o != p.overlays[i] { p.overlays[i] = o; changed += 1 }
        }
        return changed
    }
}
