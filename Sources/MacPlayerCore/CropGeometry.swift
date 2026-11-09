import Foundation

/// The arithmetic behind the crop frame drawn on a photo.
///
/// A crop is stored in the picture as it came (upright, before any turning), because that is where the renderer cuts it. The frame on the screen
/// is drawn on the picture as it is shown, after the quarter turns and flips. These functions carry a rectangle from one to the other, and turn
/// mouse movement into a new rectangle. Everything is in fractions of the picture, from the top left.
public enum CropGeometry {
    // MARK: Between the picture as it came and as it is shown

    /// Where a point of the original picture is on the shown one: turned clockwise by `rotation` degrees, then flipped.
    static func forward(_ p: (x: Double, y: Double), rotation: Int, flipH: Bool, flipV: Bool) -> (x: Double, y: Double) {
        var q = p
        switch ((rotation % 360) + 360) % 360 {
        case 90: q = (1 - p.y, p.x)
        case 180: q = (1 - p.x, 1 - p.y)
        case 270: q = (p.y, 1 - p.x)
        default: break
        }
        if flipH { q.x = 1 - q.x }
        if flipV { q.y = 1 - q.y }
        return q
    }

    /// The other way: a point of the shown picture, back on the original.
    static func backward(_ p: (x: Double, y: Double), rotation: Int, flipH: Bool, flipV: Bool) -> (x: Double, y: Double) {
        var q = p
        if flipV { q.y = 1 - q.y }
        if flipH { q.x = 1 - q.x }
        switch ((rotation % 360) + 360) % 360 {
        case 90: q = (q.y, 1 - q.x)
        case 180: q = (1 - q.x, 1 - q.y)
        case 270: q = (1 - q.y, q.x)
        default: break
        }
        return q
    }

    private static func rect(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> CropRect {
        CropRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A crop of the original picture, as it appears on the shown (turned, flipped) one.
    public static func toDisplay(_ r: CropRect, rotation: Int, flipH: Bool, flipV: Bool) -> CropRect {
        rect(forward((r.x, r.y), rotation: rotation, flipH: flipH, flipV: flipV), forward((r.x + r.width, r.y + r.height), rotation: rotation, flipH: flipH, flipV: flipV))
    }

    /// A frame drawn on the shown picture, as a crop of the original.
    public static func toSource(_ r: CropRect, rotation: Int, flipH: Bool, flipV: Bool) -> CropRect {
        rect(backward((r.x, r.y), rotation: rotation, flipH: flipH, flipV: flipV), backward((r.x + r.width, r.y + r.height), rotation: rotation, flipH: flipH, flipV: flipV))
    }

    /// The pixel size of the shown picture (the sides swap for a quarter turn).
    public static func shownSize(width: Double, height: Double, rotation: Int) -> (width: Double, height: Double) {
        let r = ((rotation % 360) + 360) % 360
        return r == 90 || r == 270 ? (height, width) : (width, height)
    }

    // MARK: Dragging

    public enum Handle: CaseIterable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move }

    /// The frame after the mouse moved by (`dx`, `dy`) — fractions of the shown picture, y growing downward — while holding `handle`.
    /// - Parameters:
    ///   - ratio: keeps the frame at this width / height in pixels when given.
    ///   - pictureAspect: the shown picture's width / height in pixels (it turns a pixel ratio into a ratio of fractions).
    public static func drag(_ handle: Handle, from start: CropRect, dx: Double, dy: Double, ratio: Double? = nil, pictureAspect: Double = 1, minSize: Double = 0.04) -> CropRect {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        if handle == .move {
            return CropRect(x: clamp(start.x + dx, 0, 1 - start.width), y: clamp(start.y + dy, 0, 1 - start.height), width: start.width, height: start.height)
        }
        var l = start.x, t = start.y, r = start.x + start.width, b = start.y + start.height
        switch handle {
        case .topLeft: l += dx; t += dy
        case .top: t += dy
        case .topRight: r += dx; t += dy
        case .right: r += dx
        case .bottomRight: r += dx; b += dy
        case .bottom: b += dy
        case .bottomLeft: l += dx; b += dy
        case .left: l += dx
        case .move: break
        }
        guard let ratio, ratio > 0 else {
            // Only the side being dragged moves; the other stays where it was, and they never get closer than `minSize`.
            let oldR = start.x + start.width, oldB = start.y + start.height
            if [.topLeft, .left, .bottomLeft].contains(handle) { l = clamp(l, 0, oldR - minSize); r = oldR } else if [.topRight, .right, .bottomRight].contains(handle) { r = clamp(r, start.x + minSize, 1); l = start.x }
            if [.topLeft, .top, .topRight].contains(handle) { t = clamp(t, 0, oldB - minSize); b = oldB } else if [.bottomLeft, .bottom, .bottomRight].contains(handle) { b = clamp(b, start.y + minSize, 1); t = start.y }
            return CropRect(x: l, y: t, width: r - l, height: b - t)
        }
        // With a fixed shape: width / height in fractions is k.
        let k = ratio / max(0.0001, pictureAspect)
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle), movesTop = [.topLeft, .top, .topRight].contains(handle)
        let horizontalOnly = handle == .left || handle == .right, verticalOnly = handle == .top || handle == .bottom
        // The side opposite the handle stays; the dragged corner (or edge) decides the size.
        let anchorX = movesLeft ? start.x + start.width : (handle == .top || handle == .bottom ? start.x + start.width / 2 : start.x)
        let anchorY = movesTop ? start.y + start.height : (handle == .left || handle == .right ? start.y + start.height / 2 : start.y)
        var w = abs((movesLeft ? l : r) - anchorX), h = abs((movesTop ? t : b) - anchorY)
        if verticalOnly { w = h * k } else if horizontalOnly { h = w / k }
        else if w / max(h, 0.0001) > k { h = w / k } else { w = h * k }          // follow whichever side moved further
        // As large as the picture allows from that anchor.
        let roomW = horizontalOnly || !verticalOnly ? (movesLeft ? anchorX : (handle == .top || handle == .bottom ? 2 * min(anchorX, 1 - anchorX) : 1 - anchorX)) : 2 * min(anchorX, 1 - anchorX)
        let roomH = verticalOnly || !horizontalOnly ? (movesTop ? anchorY : (handle == .left || handle == .right ? 2 * min(anchorY, 1 - anchorY) : 1 - anchorY)) : 2 * min(anchorY, 1 - anchorY)
        let maxW = min(roomW, roomH * k)
        w = min(max(w, minSize), max(minSize, maxW)); h = w / k
        let x = movesLeft ? anchorX - w : (handle == .top || handle == .bottom ? anchorX - w / 2 : anchorX)
        let y = movesTop ? anchorY - h : (handle == .left || handle == .right ? anchorY - h / 2 : anchorY)
        return CropRect(x: x, y: y, width: w, height: h)
    }

    /// The largest frame of this shape that fits the shown picture, centred on `around` when it can be.
    public static func largest(ratio: Double, pictureAspect: Double, around: CropRect? = nil) -> CropRect {
        let k = ratio / max(0.0001, pictureAspect)           // width / height in fractions
        var w = 1.0, h = 1.0
        if k > 1 { h = 1 / k } else { w = k }
        let cx = around.map { $0.x + $0.width / 2 } ?? 0.5, cy = around.map { $0.y + $0.height / 2 } ?? 0.5
        return CropRect(x: min(max(0, cx - w / 2), 1 - w), y: min(max(0, cy - h / 2), 1 - h), width: w, height: h)
    }
}
