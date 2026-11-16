import Foundation

/// Which thing over the picture is drawn above which (0.20): texts, shapes, stickers, and picture/video layers share one stack.
///
/// Until 0.20 every text was drawn above every layer, and layers only by lane. Each thing now has a key: a layer's lane (0–2), a text 1000, or
/// the place it was given with Bring Forward / Send Backward. Given places are negative (−n … −1), so anything added afterwards, which has no
/// place yet, lands on top, as people expect. Equal keys keep the old order: layers before texts, each in the order they were added.
public enum LayerOrder {
    public enum Move: String, CaseIterable, Sendable { case toFront, forward, backward, toBack }

    /// Where texts go when they have no place of their own: above the layers.
    public static let textKey = 1000.0

    public static func key(_ o: TextOverlay) -> Double { o.z ?? textKey }
    public static func key(_ c: OverlayClip) -> Double { c.z ?? Double(c.lane) }

    public struct Item: Equatable, Sendable {
        public var id: UUID
        public var isText: Bool
        public var span: TimeSpan
    }

    /// Everything over the picture, bottom first, as the renderer draws it.
    public static func stack(_ p: Project) -> [Item] {
        let layers = p.overlayClips.enumerated().map { (key: key($0.element), seq: $0.offset, item: Item(id: $0.element.id, isText: false, span: $0.element.span)) }
        let texts = p.overlays.enumerated().map { (key: key($0.element), seq: 100_000 + $0.offset, item: Item(id: $0.element.id, isText: true, span: TimeSpan(start: $0.element.start, end: $0.element.end))) }
        return (layers + texts).sorted { $0.key != $1.key ? $0.key < $1.key : $0.seq < $1.seq }.map(\.item)
    }

    /// Moves `ids` in the stack. `timed`: only things on screen at the same time count as neighbours (a video project); in a photo
    /// everything is on screen. Returns false when nothing could move (already on top, nothing above it at that time…).
    @discardableResult
    public static func move(_ ids: Set<UUID>, _ m: Move, in p: inout Project, timed: Bool) -> Bool {
        var order = stack(p)
        let moving = order.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return false }
        func meets(_ a: Item, _ b: Item) -> Bool { !timed || (a.span.start < b.span.end && b.span.start < a.span.end) || a.span.start == b.span.start }
        /// Something not being moved that is on screen with one of the moving things.
        func neighbour(_ o: Item) -> Bool { !ids.contains(o.id) && moving.contains { meets($0, o) } }
        let before = order.map(\.id)
        switch m {
        case .toFront, .toBack:
            let rest = order.filter { !ids.contains($0.id) }
            // Placed just above the topmost (or below the lowest) neighbour, which looks the same and keeps unrelated things where they are.
            if m == .toFront {
                guard let top = rest.lastIndex(where: neighbour) else { return false }
                order = Array(rest[...top]) + moving + Array(rest[(top + 1)...])
            } else {
                guard let low = rest.firstIndex(where: neighbour) else { return false }
                order = Array(rest[..<low]) + moving + Array(rest[low...])
            }
        case .forward:
            // One step: above the next neighbour over the topmost moving thing.
            guard let last = order.lastIndex(where: { ids.contains($0.id) }),
                  let next = order.indices.first(where: { $0 > last && neighbour(order[$0]) }) else { return false }
            let rest = order.filter { !ids.contains($0.id) }
            let at = rest.firstIndex { $0.id == order[next].id }! + 1
            order = Array(rest[..<at]) + moving + Array(rest[at...])
        case .backward:
            guard let first = order.firstIndex(where: { ids.contains($0.id) }),
                  let prev = order.indices.last(where: { $0 < first && neighbour(order[$0]) }) else { return false }
            let rest = order.filter { !ids.contains($0.id) }
            let at = rest.firstIndex { $0.id == order[prev].id }!
            order = Array(rest[..<at]) + moving + Array(rest[at...])
        }
        guard order.map(\.id) != before else { return false }
        apply(order.map(\.id), to: &p)
        return true
    }

    /// Whether `move` would change anything (for the buttons and menu items).
    public static func canMove(_ ids: Set<UUID>, _ m: Move, in p: Project, timed: Bool) -> Bool {
        var copy = p
        return move(ids, m, in: &copy, timed: timed)
    }

    /// Writes places −n … −1 in this order (bottom first).
    static func apply(_ ids: [UUID], to p: inout Project) {
        let n = ids.count
        var place: [UUID: Double] = [:]
        for (i, id) in ids.enumerated() { place[id] = Double(i - n) }
        for i in p.overlays.indices { if let z = place[p.overlays[i].id] { p.overlays[i].z = z } }
        for i in p.overlayClips.indices { if let z = place[p.overlayClips[i].id] { p.overlayClips[i].z = z } }
    }
}
