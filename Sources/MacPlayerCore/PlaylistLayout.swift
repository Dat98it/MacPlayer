import Foundation

/// How a playlist is shown: one video per line, a grid of pictures (fewer scrolls when the list is long), or a tree of the folders
/// the files are in (parents above children, each folder opened or closed).
public enum PlaylistLayout: String, CaseIterable, Sendable { case list, grid, tree }

/// In the folder tree, how the files inside a folder are drawn: one per line, or as pictures several to a row (far less scrolling when
/// a folder holds many files).
public enum TreeFiles: String, CaseIterable, Sendable { case list, grid }

/// How big the previews (the small pictures of the files) are shown in the playlist, as a multiple of the original size: 1 is the small
/// size the app started with. The person sets it with a slider, in steps, and it is remembered.
public enum PreviewSize {
    public static let range: ClosedRange<Double> = 0.75...3.0
    public static let step = 0.25
    /// What a person who has never chosen gets (the first size was thought too small).
    public static let standard = 1.5

    /// A usable value: inside the range, on a step; anything else (not a number, far too big) becomes the standard or the nearest end.
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        let inside = min(max(value, range.lowerBound), range.upperBound)
        let snapped = (inside / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// Choosing items in the grid, where (unlike the list) the choosing is done by hand: click, ⌘-click and ⇧-click.
public enum ItemSelection {
    public enum Click: Sendable { case plain, toggle, range }

    /// The new selection and the item later ⇧-clicks measure from. `order` is what is on screen, in order.
    public static func apply(_ click: Click, on id: UUID, order: [UUID], selected: Set<UUID>, anchor: UUID?) -> (selected: Set<UUID>, anchor: UUID?) {
        switch click {
        case .plain:
            return ([id], id)
        case .toggle:
            var s = selected
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            return (s, id)
        case .range:
            guard let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) else { return ([id], id) }
            return (Set(order[min(i, j)...max(i, j)]), a)
        }
    }
}
