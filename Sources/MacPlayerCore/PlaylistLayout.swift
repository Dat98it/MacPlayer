import Foundation

/// How a playlist is shown: one video per line, a grid of pictures (fewer scrolls when the list is long), or a tree of the folders
/// the files are in (parents above children, each folder opened or closed).
public enum PlaylistLayout: String, CaseIterable, Sendable { case list, grid, tree }

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
