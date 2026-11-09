import Foundation
import Testing
@testable import MacPlayerCore

struct PlaylistOrderTests {
    func item(_ title: String, modified: Double? = nil, length: Double? = nil) -> PlaylistItem {
        PlaylistItem(path: "/V/\(title).mp4", title: title, duration: length.map { MediaTime(seconds: $0) },
                     modified: modified.map { Date(timeIntervalSinceReferenceDate: $0) })
    }
    func titles(_ items: [PlaylistItem]) -> [String] { items.map(\.title) }

    @Test func byNameBothWaysWithNumbersInOrder() {
        let items = [item("clip 10"), item("Clip 1"), item("clip 2")]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .naturalName))) == ["Clip 1", "clip 2", "clip 10"])
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .naturalName, descending: true))) == ["clip 10", "clip 2", "Clip 1"])
    }

    @Test func byDateNewestOrOldestFirstWithUndatedLast() {
        let items = [item("old", modified: 100), item("none"), item("new", modified: 900), item("mid", modified: 500)]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .modified))) == ["old", "mid", "new", "none"])
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .modified, descending: true))) == ["new", "mid", "old", "none"],
                "a video with no date is last whichever way it goes")
    }

    @Test func byLengthWithUnknownLengthsLast() {
        let items = [item("b", length: 30), item("unknown"), item("a", length: 10), item("c", length: 20)]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .duration))) == ["a", "c", "b", "unknown"])
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .duration, descending: true))) == ["b", "c", "a", "unknown"])
    }

    @Test func equalKeysFallBackToTheNameAndEqualNamesKeepTheirPlace() {
        let same = [item("b", length: 5), item("a", length: 5)]
        #expect(titles(PlaylistEditor.sorted(same, by: PlaylistOrder(key: .duration))) == ["a", "b"])
        let twins = [PlaylistItem(path: "/X/same.mp4", title: "same"), PlaylistItem(path: "/Y/same.mp4", title: "same")]
        #expect(PlaylistEditor.sorted(twins, by: PlaylistOrder(key: .naturalName)).map(\.path) == ["/X/same.mp4", "/Y/same.mp4"])
        #expect(PlaylistEditor.sorted(twins, by: PlaylistOrder(key: .naturalName, descending: true)).map(\.path) == ["/X/same.mp4", "/Y/same.mp4"])
    }

    @Test func aManualOrderLeavesTheListAlone() {
        let items = [item("z"), item("a"), item("m")]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder.manual)) == ["z", "a", "m"])
        #expect(!PlaylistOrder.manual.isAutomatic && PlaylistOrder(key: .duration).isAutomatic)
    }

    @Test func theOrderIsSavedWithThePlaylistAndOlderFilesAreManual() throws {
        var p = Playlist(name: "P"); p.items = [item("a"), item("b")]
        #expect(p.order == .manual)
        p.order = PlaylistOrder(key: .modified, descending: true)
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(Playlist.self, from: data).order == PlaylistOrder(key: .modified, descending: true))
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "order")
        let old = try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.order == .manual && old.items.count == 2)
    }

    @Test func theSortWithoutADirectionIsStillAvailableAndAscending() {
        let items = [item("b"), item("a")]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistSort.naturalName)) == ["a", "b"])
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistSort.manual)) == ["b", "a"])
    }
}

struct PlaylistCreatedAndSizeTests {
    func item(_ title: String, created: Double? = nil, size: Int64? = nil) -> PlaylistItem {
        PlaylistItem(path: "/V/\(title).mp4", title: title, created: created.map { Date(timeIntervalSinceReferenceDate: $0) }, fileSize: size)
    }
    func titles(_ items: [PlaylistItem]) -> [String] { items.map(\.title) }

    @Test func byDateCreatedNewestOrOldestFirstWithUnknownLast() {
        let items = [item("old", created: 100), item("none"), item("new", created: 900), item("mid", created: 500)]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .created))) == ["old", "mid", "new", "none"])
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .created, descending: true))) == ["new", "mid", "old", "none"])
    }

    @Test func byFileSizeSmallestOrLargestFirstWithUnknownLast() {
        let items = [item("b", size: 300), item("unknown"), item("a", size: 100), item("c", size: 200)]
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .size))) == ["a", "c", "b", "unknown"])
        #expect(titles(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .size, descending: true))) == ["b", "c", "a", "unknown"])
    }

    @Test func aPlaylistSavedBeforeTheseFieldsStillLoadsAndKeepsItsOrder() throws {
        var p = Playlist(name: "old")
        p.items = [item("x"), item("y")]
        p.order = PlaylistOrder(key: .created, descending: true)
        let data = try JSONEncoder().encode(p)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try #require(obj["items"] as? [[String: Any]])
        for i in items.indices { items[i].removeValue(forKey: "created"); items[i].removeValue(forKey: "fileSize") }
        obj["items"] = items
        let back = try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.items.count == 2 && back.items[0].created == nil && back.items[0].fileSize == nil)
        #expect(back.order == PlaylistOrder(key: .created, descending: true))
    }

    @Test func aFolderScanCanBeOrderedBySize() {
        let v = [ScannedVideo(path: "/a/b.mp4", name: "b.mp4", size: 5, modified: .distantPast), ScannedVideo(path: "/a/a.mp4", name: "a.mp4", size: 9, modified: .distantPast)]
        #expect(FolderScanner.sort(v, by: .size).map(\.name) == ["b.mp4", "a.mp4"])
    }
}
