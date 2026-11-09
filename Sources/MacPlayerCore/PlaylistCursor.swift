import Foundation

/// A source of random numbers that tests can replace.
public protocol Randomizer: AnyObject {
    /// 0 ..< upperBound
    func next(upTo upperBound: Int) -> Int
}

public final class SystemRandomizer: Randomizer {
    public init() {}
    public func next(upTo upperBound: Int) -> Int { Int.random(in: 0..<upperBound) }
}

public enum StopReason: Equatable, Sendable {
    case endOfList
    case noPlayableItems
    /// "Auto-play next" is off: stop after each video.
    case autoAdvanceOff
    case emptyList
}

public enum Advance: Equatable, Sendable {
    case play(UUID)
    case stop(StopReason)
}

/// Decides which item plays next. Pure logic, no AVFoundation: it asks `isPlayable` about each candidate,
/// so unavailable files are skipped, and it never loops forever (each decision looks at every item at most once).
///
/// Behaviours from design section 4.1:
/// * shuffle plays every item once per round before any repeats (unless the user picks one on purpose);
/// * "previous" in shuffle follows the real play history;
/// * removing the item being played does not stop it; the next advance goes to the item that followed it;
/// * adding or reordering items never changes what is playing.
public final class PlaylistCursor {
    public private(set) var items: [PlaylistItem] { didSet { lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) } }
    /// id -> item, so a decision never scans the list (1,000-item playlists must stay instant).
    private var lookup: [UUID: PlaylistItem] = [:]
    public private(set) var current: UUID?
    public var playMode: PlayMode { didSet { if playMode != oldValue { resetShuffle() } } }
    public var repeatMode: RepeatMode
    public var autoAdvance: Bool

    private let random: Randomizer
    /// Items not yet played in this shuffle round.
    private var bag: [UUID] = []
    private var history: [UUID] = []
    /// When the current item was removed: where in `items` the next sequential item now sits.
    private var ghostNextIndex: Int?
    /// Everything played in the current shuffle round (for "all items played, new round").
    private var playedThisRound = Set<UUID>()

    public init(playlist: Playlist, random: Randomizer = SystemRandomizer()) {
        items = playlist.items
        current = playlist.currentItemID.flatMap { id in playlist.items.contains { $0.id == id } ? id : nil }
        playMode = playlist.playMode
        repeatMode = playlist.repeatMode
        autoAdvance = playlist.autoAdvance
        self.random = random
        lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        resetShuffle()
    }

    // MARK: Choosing

    /// The user picked an item (double-click, Return). Always honoured, even if it was already played this round.
    public func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if let c = current, c != id { history.append(c) }
        current = id
        ghostNextIndex = nil
        bag.removeAll { $0 == id }
        playedThisRound.insert(id)
    }

    /// The next item. `userInitiated` = the Next button/shortcut; otherwise the video ended by itself.
    public func next(userInitiated: Bool, isPlayable: (PlaylistItem) -> Bool) -> Advance {
        if items.isEmpty { return .stop(.emptyList) }
        if !userInitiated, !autoAdvance { return .stop(.autoAdvanceOff) }

        // Repeat-one: the same video again when it ended by itself (and can still be played).
        if !userInitiated, repeatMode == .one, let c = current, let item = lookup[c], isPlayable(item) {
            return .play(c)
        }

        let pick: Advance
        switch playMode {
        case .sequential: pick = nextSequential(isPlayable: isPlayable)
        case .shuffle: pick = nextShuffle(isPlayable: isPlayable)
        }
        if case .play(let id) = pick {
            if let c = current, c != id { history.append(c) }
            current = id
            ghostNextIndex = nil
            bag.removeAll { $0 == id }
            playedThisRound.insert(id)
        }
        return pick
    }

    /// The previous item: shuffle goes back through what was actually played; sequential steps back in the list.
    public func previous(isPlayable: (PlaylistItem) -> Bool) -> Advance {
        if items.isEmpty { return .stop(.emptyList) }
        if playMode == .shuffle {
            while let id = history.popLast() {
                if let item = lookup[id], isPlayable(item) {
                    current = id; ghostNextIndex = nil
                    return .play(id)
                }
            }
            return .stop(.endOfList)
        }
        let n = items.count
        let start: Int
        if let g = ghostNextIndex { start = g } else if let c = current, let i = items.firstIndex(where: { $0.id == c }) { start = i } else { start = n }
        var step = 1
        while step <= n {
            var idx = start - step
            if idx < 0 {
                guard repeatMode == .all else { return .stop(.endOfList) }
                idx += n
            }
            if isPlayable(items[idx]) {
                current = items[idx].id; ghostNextIndex = nil
                return .play(items[idx].id)
            }
            step += 1
        }
        return .stop(.noPlayableItems)
    }

    // MARK: List changes while playing

    /// Add, remove, reorder or re-sort. Playback of the current item is not interrupted.
    public func itemsChanged(_ newItems: [PlaylistItem]) {
        let oldItems = items
        let newIDs = Set(newItems.map(\.id))
        if let c = current, !newIDs.contains(c), ghostNextIndex == nil {
            // The item being played was removed. The item that followed it in the OLD order, if it still exists,
            // is what plays next.
            if let oldIdx = oldItems.firstIndex(where: { $0.id == c }) {
                var successor: UUID?
                for follower in oldItems[(oldIdx + 1)...] where newIDs.contains(follower.id) { successor = follower.id; break }
                if let s = successor, let newIdx = newItems.firstIndex(where: { $0.id == s }) { ghostNextIndex = newIdx }
                else { ghostNextIndex = newItems.count } // nothing after it: the end of the list
            }
        } else if let g = ghostNextIndex, g < oldItems.count {
            // Keep pointing at the same successor through further edits.
            let successor = oldItems[g].id
            if let newIdx = newItems.firstIndex(where: { $0.id == successor }) { ghostNextIndex = newIdx } else { ghostNextIndex = min(g, newItems.count) }
        }
        items = newItems
        history.removeAll { !newIDs.contains($0) }
        bag.removeAll { !newIDs.contains($0) }
        // New items are unplayed in this round.
        var inBag = Set(bag)
        for it in newItems where !playedThisRound.contains(it.id) && !inBag.contains(it.id) && it.id != current {
            bag.append(it.id); inBag.insert(it.id)
        }
        playedThisRound = playedThisRound.intersection(newIDs)
    }

    // MARK: Internals

    private func resetShuffle() {
        playedThisRound = current.map { [$0] } ?? []
        bag = items.map(\.id).filter { $0 != current }
    }

    private func nextSequential(isPlayable: (PlaylistItem) -> Bool) -> Advance {
        let n = items.count
        let base: Int // index of the first candidate
        if let g = ghostNextIndex { base = g }
        else if let c = current, let i = items.firstIndex(where: { $0.id == c }) { base = i + 1 }
        else { base = 0 }
        for step in 0..<n {
            var idx = base + step
            if idx >= n {
                guard repeatMode == .all || (current == nil) else { return .stop(.endOfList) }
                idx -= n
                if idx >= n { return .stop(.noPlayableItems) }
            }
            if isPlayable(items[idx]) { return .play(items[idx].id) }
        }
        // Looked at every item: none can be played.
        return .stop(repeatMode == .all || current == nil ? .noPlayableItems : .endOfList)
    }

    private func nextShuffle(isPlayable: (PlaylistItem) -> Bool) -> Advance {
        /// Random pick among playable items still in the bag. Unplayable ones are swapped out of the way for this
        /// draw (they stay in the bag), so each attempt is O(1).
        func drawFromBag() -> UUID? {
            var live = bag.count
            while live > 0 {
                let i = random.next(upTo: live)
                let id = bag[i]
                if let item = lookup[id], isPlayable(item) { return id }
                bag.swapAt(i, live - 1)
                live -= 1
            }
            return nil
        }
        if let id = drawFromBag() { return .play(id) }
        // Round finished (or the rest cannot be played).
        guard repeatMode == .all else { return .stop(.endOfList) }
        // New round: everything again, but not the item that just played (no back-to-back repeat when avoidable).
        playedThisRound = current.map { [$0] } ?? []
        bag = items.map(\.id).filter { $0 != current }
        if let id = drawFromBag() { return .play(id) }
        // Only the current item is left: it may repeat if it is the only playable one.
        if let c = current, let item = lookup[c], isPlayable(item) { return .play(c) }
        return .stop(.noPlayableItems)
    }
}
