import Foundation
import Testing
@testable import MacPlayerCore

struct FolderTreeTests {
    func item(_ path: String) -> PlaylistItem { PlaylistItem(path: path) }
    func titles(_ rows: [FolderTree.Row]) -> [String] { rows.map { String(repeating: "  ", count: $0.depth) + ($0.kind == .folder ? "[\($0.title)]" : $0.title) } }

    let sample: [PlaylistItem] = [
        PlaylistItem(path: "/V/Trips/Paris/a.jpg"), PlaylistItem(path: "/V/Trips/Paris/b.jpg"),
        PlaylistItem(path: "/V/Trips/Rome/c.jpg"), PlaylistItem(path: "/V/Trips/loose.jpg"),
        PlaylistItem(path: "/V/Family/d.mp4"),
    ]

    @Test func parentsComeAboveChildrenAndTheCommonStartIsOneRow() {
        let rows = FolderTree.rows(for: sample, order: .manual)
        // the folders of /V: Trips first (it came first in the list), then Family; folders before files
        #expect(titles(rows) == ["[V]", "  [Trips]", "    [Paris]", "      a", "      b", "    [Rome]", "      c", "    loose", "  [Family]", "    d"])
        #expect(rows.first?.title == "V" && rows.first?.depth == 0)
        #expect(rows.first { $0.title == "loose" }?.depth == 2)
    }

    @Test func aFolderRowKnowsEveryFileInsideIncludingDeeperOnes() {
        let rows = FolderTree.rows(for: sample, order: .manual)
        let trips = rows.first { $0.title == "Trips" }!
        #expect(trips.fileCount == 4 && trips.subfolderCount == 2)
        #expect(Set(trips.itemIDs) == Set(sample.prefix(4).map(\.id)))
        #expect(rows.first { $0.title == "V" }?.fileCount == 5)
    }

    @Test func aFolderThatOnlyHoldsOneFolderIsJoinedWithIt() {
        let items = [item("/V/2024/Summer/Beach/a.jpg"), item("/V/2024/Summer/Beach/b.jpg"), item("/V/Other/c.jpg")]
        let rows = FolderTree.rows(for: items, order: .manual)
        #expect(rows.filter { $0.kind == .folder }.map(\.title) == ["V", "2024/Summer/Beach", "Other"])
        #expect(rows.first { $0.title == "2024/Summer/Beach" }?.path == "/V/2024/Summer/Beach", "the row stands for the deepest folder")
    }

    @Test func aClosedFolderKeepsItsRowButHidesWhatIsInside() {
        let rows = FolderTree.rows(for: sample, order: .manual, collapsed: ["/V/Trips"])
        #expect(rows.map(\.title) == ["V", "Trips", "Family", "d"])
        #expect(rows.first { $0.title == "Trips" }?.isExpanded == false)
        #expect(rows.first { $0.title == "Trips" }?.fileCount == 4, "a closed folder still counts and selects what is in it")
        let all = FolderTree.rows(for: sample, order: .manual, collapsed: ["/V/Trips"], expandAll: true)
        #expect(all.count == 10, "opening everything, as a search does, ignores what was closed")
    }

    @Test func closingAnOuterFolderHidesTheInnerRowsToo() {
        let rows = FolderTree.rows(for: sample, order: .manual, collapsed: ["/V"])
        #expect(rows.map(\.title) == ["V"] && rows[0].fileCount == 5)
    }

    @Test func foldersAreSortedByNameUnlessTheListIsArrangedByHand() {
        let items = [item("/V/Zed/a.jpg"), item("/V/Alpha 10/b.jpg"), item("/V/Alpha 2/c.jpg")]
        let byName = FolderTree.rows(for: items, order: PlaylistOrder(key: .naturalName), collapsed: []).filter { $0.kind == .folder }.map(\.title)
        #expect(byName == ["V", "Alpha 2", "Alpha 10", "Zed"])
        let byHand = FolderTree.rows(for: items, order: .manual).filter { $0.kind == .folder }.map(\.title)
        #expect(byHand == ["V", "Zed", "Alpha 10", "Alpha 2"], "the person's own order")
    }

    @Test func filesInAFolderKeepThePlaylistsOrder() {
        let items = [item("/V/A/b.jpg"), item("/V/A/a.jpg"), item("/V/A/c.jpg")]
        #expect(FolderTree.rows(for: items, order: .manual).filter { $0.kind == .file }.map(\.title) == ["b", "a", "c"])
    }

    @Test func filesFromDifferentDrivesGetTheirOwnTopFolders() {
        let items = [item("/Volumes/Disk A/Photos/a.jpg"), item("/Users/me/Pictures/b.jpg")]
        let rows = FolderTree.rows(for: items, order: PlaylistOrder(key: .naturalName))
        #expect(rows.filter { $0.depth == 0 }.map(\.title).sorted() == ["Photos", "Pictures"])
        #expect(rows.first { $0.title == "Photos" }?.path == "/Volumes/Disk A/Photos")
    }

    @Test func theSameFileTwiceShowsTwice() {
        let a = item("/V/A/x.jpg"), b = item("/V/A/x.jpg")
        #expect(FolderTree.rows(for: [a, b], order: .manual).filter { $0.kind == .file }.count == 2)
    }

    @Test func anEmptyListHasNoRows() { #expect(FolderTree.rows(for: [], order: .manual).isEmpty) }

    @Test func folderPathsListsEveryFolderOpenOrNot() {
        #expect(Set(FolderTree.folderPaths(for: sample, order: .manual)) == ["/V", "/V/Trips", "/V/Trips/Paris", "/V/Trips/Rome", "/V/Family"])
    }

    // MARK: Sorting by folder, so playing goes down the tree

    @Test func sortingByFolderPlaysTheTreeFromTopToBottom() {
        let sorted = PlaylistEditor.sorted(sample.reversed(), by: PlaylistOrder(key: .folder))
        let shown = FolderTree.rows(for: sorted, order: PlaylistOrder(key: .folder)).filter { $0.kind == .file }.map(\.path)
        #expect(sorted.map(\.path) == shown, "the order of the list and the order of the tree are the same")
        #expect(sorted.map(\.path).first == "/V/Family/d.mp4")
    }

    @Test func sortingByFolderDescendingStillMatchesTheTree() {
        let order = PlaylistOrder(key: .folder, descending: true)
        let sorted = PlaylistEditor.sorted(sample, by: order)
        #expect(sorted.map(\.path) == FolderTree.rows(for: sorted, order: order).filter { $0.kind == .file }.map(\.path))
    }

    @Test func subfoldersComeBeforeTheFilesOfTheirParent() {
        let items = [item("/V/x.jpg"), item("/V/Sub/y.jpg")]
        #expect(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .folder)).map(\.path) == ["/V/Sub/y.jpg", "/V/x.jpg"])
    }

    @Test func naturalNumbersInFolderNamesAreOrderedAsPeopleExpect() {
        let items = [item("/V/Day 10/a.jpg"), item("/V/Day 2/b.jpg"), item("/V/Day 1/c.jpg")]
        #expect(PlaylistEditor.sorted(items, by: PlaylistOrder(key: .folder)).map(\.path) == ["/V/Day 1/c.jpg", "/V/Day 2/b.jpg", "/V/Day 10/a.jpg"])
    }

    @Test func theNewLayoutAndSortAreRememberedAndOldFilesStillLoad() throws {
        #expect(PlaylistLayout(rawValue: "tree") == .tree)
        let p = Playlist(name: "x", items: [])
        var q = p; q.order = PlaylistOrder(key: .folder, descending: true)
        let back = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(q))
        #expect(back.order == PlaylistOrder(key: .folder, descending: true))
    }

    // MARK: A big library

    @Test func aBigLibraryIsArrangedQuickly() {
        // 6 000 files in 120 folders, three levels deep: the tree is rebuilt whenever the list is drawn, so it has to be fast.
        let items = (0..<6000).map { i in PlaylistItem(path: "/Volumes/Disk/Photos/Year \(i % 6)/Month \((i / 6) % 20)/IMG_\(i).jpg") }
        let clock = ContinuousClock()
        var rows: [FolderTree.Row] = []
        let t = clock.measure { rows = FolderTree.rows(for: items, order: PlaylistOrder(key: .folder)) }
        #expect(rows.filter { $0.kind == .file }.count == 6000 && rows.filter { $0.kind == .folder }.count == 1 + 6 + 120)
        #expect(t < .milliseconds(500), "took \(t)")
        let closed = clock.measure { rows = FolderTree.rows(for: items, order: .manual, collapsed: ["/Volumes/Disk/Photos"]) }
        #expect(rows.count == 1 && rows[0].fileCount == 6000 && closed < .milliseconds(500))
    }
}
