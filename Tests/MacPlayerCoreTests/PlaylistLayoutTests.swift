import Foundation
import Testing
@testable import MacPlayerCore

struct PlaylistLayoutTests {
    final class Dict: PreferenceStoring {
        var d: [String: Any] = [:]
        func object(forKey key: String) -> Any? { d[key] }
        func set(_ value: Any?, forKey key: String) { d[key] = value }
    }

    @Test func layoutDefaultsToListAndIsRemembered() {
        let store = Dict()
        let p = AppPreferences(store: store)
        #expect(p.playlistLayout == .list)
        p.playlistLayout = .grid
        #expect(AppPreferences(store: store).playlistLayout == .grid, "a new run of the app reads it back")
        store.d["playlistLayout"] = "something else"
        #expect(AppPreferences(store: store).playlistLayout == .list, "an unknown value falls back to the list")
    }

    let ids = (0..<6).map { _ in UUID() }

    @Test func plainClickSelectsOnlyThatItem() {
        let r = ItemSelection.apply(.plain, on: ids[2], order: ids, selected: [ids[0], ids[1]], anchor: ids[0])
        #expect(r.selected == [ids[2]] && r.anchor == ids[2])
    }

    @Test func commandClickAddsAndRemoves() {
        var r = ItemSelection.apply(.toggle, on: ids[3], order: ids, selected: [ids[1]], anchor: ids[1])
        #expect(r.selected == [ids[1], ids[3]])
        r = ItemSelection.apply(.toggle, on: ids[1], order: ids, selected: r.selected, anchor: r.anchor)
        #expect(r.selected == [ids[3]])
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchorEitherWay() {
        var r = ItemSelection.apply(.range, on: ids[4], order: ids, selected: [ids[1]], anchor: ids[1])
        #expect(r.selected == Set(ids[1...4]) && r.anchor == ids[1])
        r = ItemSelection.apply(.range, on: ids[0], order: ids, selected: r.selected, anchor: r.anchor)
        #expect(r.selected == Set(ids[0...1]), "the anchor stays, so the range follows the click")
    }

    @Test func shiftClickWithoutAnAnchorOrOffScreenAnchorActsAsPlain() {
        #expect(ItemSelection.apply(.range, on: ids[2], order: ids, selected: [], anchor: nil).selected == [ids[2]])
        // the anchor was filtered out of view by a search
        let visible = [ids[2], ids[3]]
        #expect(ItemSelection.apply(.range, on: ids[3], order: visible, selected: [ids[0]], anchor: ids[0]).selected == [ids[3]])
    }
}
