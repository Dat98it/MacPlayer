import Foundation

/// The things on the picture that can be selected together: text, shapes and stickers (`overlays`) and layers or logos (`overlayClips`).
/// Selecting one member of a group selects the whole group; locked things are left out of moves and deletions (0.12).
public enum CanvasSelection {
    /// The ids of everything in the project that sits on the picture, with its group and lock.
    public static func items(of p: Project) -> [(id: UUID, group: UUID?, locked: Bool)] {
        p.overlays.map { ($0.id, $0.groupID, $0.locked ?? false) } + p.overlayClips.map { ($0.id, $0.groupID, $0.locked ?? false) }
    }

    /// `ids` with every other member of their groups added.
    public static func expandingGroups(_ ids: Set<UUID>, in p: Project) -> Set<UUID> {
        let all = items(of: p)
        let groups = Set(all.filter { ids.contains($0.id) }.compactMap(\.group))
        return ids.union(all.filter { $0.group.map(groups.contains) ?? false }.map(\.id))
    }

    /// The ones that may be moved, resized or deleted (not locked).
    public static func movable(_ ids: Set<UUID>, in p: Project) -> Set<UUID> {
        Set(items(of: p).filter { ids.contains($0.id) && !$0.locked }.map(\.id))
    }

    /// Puts the things in one new group (two or more), or takes them out of their groups. Returns the new group's id when one was made.
    @discardableResult
    public static func group(_ ids: Set<UUID>, in p: inout Project) -> UUID? {
        guard ids.count > 1 else { return nil }
        let g = UUID()
        for i in p.overlays.indices where ids.contains(p.overlays[i].id) { p.overlays[i].groupID = g }
        for i in p.overlayClips.indices where ids.contains(p.overlayClips[i].id) { p.overlayClips[i].groupID = g }
        return g
    }

    public static func ungroup(_ ids: Set<UUID>, in p: inout Project) {
        for i in p.overlays.indices where ids.contains(p.overlays[i].id) { p.overlays[i].groupID = nil }
        for i in p.overlayClips.indices where ids.contains(p.overlayClips[i].id) { p.overlayClips[i].groupID = nil }
    }

    public static func setLocked(_ locked: Bool, _ ids: Set<UUID>, in p: inout Project) {
        for i in p.overlays.indices where ids.contains(p.overlays[i].id) { p.overlays[i].locked = locked ? true : nil }
        for i in p.overlayClips.indices where ids.contains(p.overlayClips[i].id) { p.overlayClips[i].locked = locked ? true : nil }
    }

    /// Moves the unlocked ones by `dx`, `dy` (fractions of the picture), kept on the picture.
    public static func nudge(_ ids: Set<UUID>, dx: Double, dy: Double, in p: inout Project) {
        let ok = movable(ids, in: p)
        for i in p.overlays.indices where ok.contains(p.overlays[i].id) {
            p.overlays[i].x = min(max(p.overlays[i].x + dx, 0), 1); p.overlays[i].y = min(max(p.overlays[i].y + dy, 0), 1)
            if var ks = p.overlays[i].keyframes, !ks.isEmpty {
                for k in ks.indices { ks[k].x = min(max(ks[k].x + dx, 0), 1); ks[k].y = min(max(ks[k].y + dy, 0), 1) }
                p.overlays[i].keyframes = ks
            }
        }
        for i in p.overlayClips.indices where ok.contains(p.overlayClips[i].id) {
            p.overlayClips[i].transform.centerX = min(max(p.overlayClips[i].transform.centerX + dx, 0), 1)
            p.overlayClips[i].transform.centerY = min(max(p.overlayClips[i].transform.centerY + dy, 0), 1)
            for k in p.overlayClips[i].keyframes.indices {
                p.overlayClips[i].keyframes[k].centerX = min(max(p.overlayClips[i].keyframes[k].centerX + dx, 0), 1)
                p.overlayClips[i].keyframes[k].centerY = min(max(p.overlayClips[i].keyframes[k].centerY + dy, 0), 1)
            }
        }
    }

    /// Removes the unlocked ones; returns how many locked ones were kept.
    @discardableResult
    public static func delete(_ ids: Set<UUID>, in p: inout Project) -> Int {
        let ok = movable(ids, in: p)
        let kept = ids.count - ok.count
        p.overlays.removeAll { ok.contains($0.id) }
        p.overlayClips.removeAll { ok.contains($0.id) }
        return kept
    }
}
