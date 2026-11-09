import Foundation
import Testing
@testable import MacPlayerCore

final class SeededRandomizer: Randomizer {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    func next(upTo upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(upperBound))
    }
}

private func item(_ name: String, available: Availability = .available) -> PlaylistItem {
    PlaylistItem(path: "/Videos/\(name).mp4", availability: available)
}

private func list(_ names: [String], mode: PlayMode = .sequential, rep: RepeatMode = .off, auto: Bool = true) -> Playlist {
    Playlist(name: "T", items: names.map { item($0) }, playMode: mode, repeatMode: rep, autoAdvance: auto)
}

private func cursor(_ p: Playlist, seed: UInt64 = 1) -> PlaylistCursor { PlaylistCursor(playlist: p, random: SeededRandomizer(seed)) }
private let allPlayable: (PlaylistItem) -> Bool = { _ in true }

private func title(_ c: PlaylistCursor, _ id: UUID) -> String { c.items.first { $0.id == id }!.title }

@Suite struct PlaylistCursorTests {
    @Test func sequentialPlaysInOrderThenStops() {
        let p = list(["a", "b", "c"])
        let c = cursor(p)
        c.select(p.items[0].id)
        var played: [String] = []
        while case .play(let id) = c.next(userInitiated: false, isPlayable: allPlayable) { played.append(title(c, id)) }
        #expect(played == ["b", "c"])
        #expect(c.next(userInitiated: false, isPlayable: allPlayable) == .stop(.endOfList))
    }

    @Test func repeatAllWraps() {
        let p = list(["a", "b"], rep: .all)
        let c = cursor(p); c.select(p.items[1].id)
        guard case .play(let id) = c.next(userInitiated: false, isPlayable: allPlayable) else { Issue.record("no wrap"); return }
        #expect(title(c, id) == "a")
    }

    @Test func repeatOneRepeatsOnAutoButNextButtonMovesOn() {
        let p = list(["a", "b"], rep: .one)
        let c = cursor(p); c.select(p.items[0].id)
        #expect(c.next(userInitiated: false, isPlayable: allPlayable) == .play(p.items[0].id))
        #expect(c.next(userInitiated: true, isPlayable: allPlayable) == .play(p.items[1].id))
    }

    @Test func autoAdvanceOffStopsAfterEachVideo() {
        let p = list(["a", "b"], auto: false)
        let c = cursor(p); c.select(p.items[0].id)
        #expect(c.next(userInitiated: false, isPlayable: allPlayable) == .stop(.autoAdvanceOff))
        #expect(c.next(userInitiated: true, isPlayable: allPlayable) == .play(p.items[1].id))
    }

    @Test func unavailableItemsAreSkipped() {
        let p = list(["a", "b", "c", "d"])
        let c = cursor(p); c.select(p.items[0].id)
        let bad: Set<UUID> = [p.items[1].id, p.items[2].id]
        #expect(c.next(userInitiated: false, isPlayable: { !bad.contains($0.id) }) == .play(p.items[3].id))
    }

    @Test func allItemsBrokenStopsInsteadOfLooping() {
        for rep in [RepeatMode.off, .all, .one] {
            let p = list(["a", "b", "c"], rep: rep)
            let c = cursor(p); c.select(p.items[0].id)
            let r = c.next(userInitiated: false, isPlayable: { _ in false })
            guard case .stop = r else { Issue.record("must stop, got \(r) with repeat \(rep)"); return }
        }
        let p = list(["a", "b"], mode: .shuffle, rep: .all)
        let c = cursor(p)
        guard case .stop = c.next(userInitiated: false, isPlayable: { _ in false }) else { Issue.record("shuffle must stop"); return }
    }

    @Test func shufflePlaysEveryItemOncePerRound() {
        let names = (1...20).map { "v\($0)" }
        let p = list(names, mode: .shuffle, rep: .all)
        let c = cursor(p, seed: 7)
        c.select(p.items[0].id)
        var seen = [p.items[0].id]
        for _ in 0..<19 {
            guard case .play(let id) = c.next(userInitiated: false, isPlayable: allPlayable) else { Issue.record("ended early"); return }
            seen.append(id)
        }
        #expect(Set(seen).count == 20, "a round must cover all items exactly once")
        // The next round starts and does not repeat the last item immediately.
        let last = seen.last!
        guard case .play(let nextID) = c.next(userInitiated: false, isPlayable: allPlayable) else { Issue.record("no new round"); return }
        #expect(nextID != last)
    }

    @Test func shuffleWithoutRepeatEndsAfterOneRound() {
        let p = list(["a", "b", "c"], mode: .shuffle, rep: .off)
        let c = cursor(p, seed: 3); c.select(p.items[0].id)
        var n = 0
        while case .play = c.next(userInitiated: false, isPlayable: allPlayable) { n += 1; if n > 10 { break } }
        #expect(n == 2)
    }

    @Test func previousInShuffleFollowsRealHistory() {
        let p = list((1...8).map { "v\($0)" }, mode: .shuffle, rep: .all)
        let c = cursor(p, seed: 5); c.select(p.items[0].id)
        var trail = [p.items[0].id]
        for _ in 0..<4 { if case .play(let id) = c.next(userInitiated: true, isPlayable: allPlayable) { trail.append(id) } }
        for expected in trail.dropLast().reversed() {
            #expect(c.previous(isPlayable: allPlayable) == .play(expected))
        }
    }

    @Test func previousInSequentialStepsBack() {
        let p = list(["a", "b", "c"])
        let c = cursor(p); c.select(p.items[2].id)
        #expect(c.previous(isPlayable: allPlayable) == .play(p.items[1].id))
        #expect(c.previous(isPlayable: allPlayable) == .play(p.items[0].id))
        #expect(c.previous(isPlayable: allPlayable) == .stop(.endOfList))
    }

    @Test func removingTheCurrentItemDoesNotStopItAndNextGoesToItsSuccessor() {
        var p = list(["a", "b", "c", "d"])
        let c = cursor(p); c.select(p.items[1].id)
        let current = c.current
        PlaylistEditor.remove([p.items[1].id], from: &p)
        c.itemsChanged(p.items)
        #expect(c.current == current, "the cursor still names what is playing")
        #expect(c.next(userInitiated: false, isPlayable: allPlayable) == .play(p.items[1].id), "plays c, the item after b")
    }

    @Test func removingEverythingStopsAfterTheCurrentVideo() {
        var p = list(["a", "b"])
        let c = cursor(p); c.select(p.items[0].id)
        PlaylistEditor.remove(Set(p.items.map(\.id)), from: &p)
        c.itemsChanged(p.items)
        #expect(c.next(userInitiated: false, isPlayable: allPlayable) == .stop(.emptyList))
    }

    @Test func removingTheLastItemWhilePlayingEndsTheList() {
        var p = list(["a", "b"])
        let c = cursor(p); c.select(p.items[1].id)
        PlaylistEditor.remove([p.items[1].id], from: &p)
        c.itemsChanged(p.items)
        #expect(c.next(userInitiated: false, isPlayable: allPlayable) == .stop(.endOfList))
    }

    @Test func addingOrReorderingNeverChangesWhatIsPlaying() {
        var p = list(["a", "b", "c"])
        let c = cursor(p); c.select(p.items[1].id)
        let before = c.current
        PlaylistEditor.add([item("z")], to: &p, at: 0)
        c.itemsChanged(p.items)
        PlaylistEditor.move(fromOffsets: [0], toOffset: 4, in: &p)
        c.itemsChanged(p.items)
        #expect(c.current == before)
    }

    @Test func itemsAddedDuringShuffleJoinTheRound() {
        var p = list(["a", "b"], mode: .shuffle, rep: .off)
        let c = cursor(p, seed: 2); c.select(p.items[0].id)
        let extra = item("new")
        PlaylistEditor.add([extra], to: &p)
        c.itemsChanged(p.items)
        var got = Set<UUID>()
        while case .play(let id) = c.next(userInitiated: false, isPlayable: allPlayable) { got.insert(id) }
        #expect(got == [p.items[1].id, extra.id])
    }

    @Test func thousandItemListIsCheap() {
        let names = (1...1000).map { "clip \($0)" }
        var p = list(names, mode: .shuffle, rep: .all)
        let start = Date()
        let c = cursor(p, seed: 11)
        c.select(p.items[0].id)
        var seen = Set<UUID>([p.items[0].id])
        for _ in 0..<999 { if case .play(let id) = c.next(userInitiated: false, isPlayable: allPlayable) { seen.insert(id) } }
        #expect(seen.count == 1000)
        let sorted = PlaylistEditor.sorted(p.items.shuffled(), by: .naturalName)
        #expect(sorted.first?.title == "clip 1" && sorted.last?.title == "clip 1000")
        _ = PlaylistEditor.search(p.items, query: "clip 99")
        PlaylistEditor.move(fromOffsets: [0, 1, 2], toOffset: 900, in: &p)
        #expect(Date().timeIntervalSince(start) < 3, "1,000 items must not be slow")
    }
}

@Suite struct PlaylistEditingTests {
    @Test func naturalOrderPutsVideo2BeforeVideo10() {
        let names = ["video 10", "video 2", "Video 1", "video 20", "video 3"]
        let sorted = PlaylistEditor.sorted(names.map { item($0) }, by: .naturalName).map(\.title)
        #expect(sorted == ["Video 1", "video 2", "video 3", "video 10", "video 20"])
    }

    @Test func duplicatesAreSkippedByDefaultAndAllowedOnPurpose() {
        var p = list(["a"])
        let r1 = PlaylistEditor.add([item("a"), item("b")], to: &p)
        #expect(r1.duplicates == ["/Videos/a.mp4"] && r1.added.count == 1 && p.count == 2)
        let r2 = PlaylistEditor.add([item("a")], to: &p, allowDuplicates: true)
        #expect(r2.added.count == 1 && p.count == 3)
        #expect(Set(p.items.map(\.id)).count == 3, "the same source twice still has its own item ids")
    }

    @Test func nonVideoFilesAreReportedNotAdded() {
        var p = list([])
        let r = PlaylistEditor.add([PlaylistItem(path: "/x/notes.txt"), item("ok")], to: &p)
        #expect(r.unsupported == ["/x/notes.txt"] && p.count == 1)
    }

    @Test func insertAtDropPositionKeepsOrder() {
        var p = list(["a", "b", "c"])
        PlaylistEditor.add([item("x"), item("y")], to: &p, at: 1)
        #expect(p.items.map(\.title) == ["a", "x", "y", "b", "c"])
    }

    @Test func dragReorderMovesMultipleItems() {
        var p = list(["a", "b", "c", "d", "e"])
        PlaylistEditor.move(fromOffsets: [0, 1], toOffset: 4, in: &p)
        #expect(p.items.map(\.title) == ["c", "d", "a", "b", "e"])
        PlaylistEditor.move(fromOffsets: [4], toOffset: 0, in: &p)
        #expect(p.items.map(\.title) == ["e", "c", "d", "a", "b"])
    }

    @Test func searchIgnoresCaseAndVietnameseAccents() {
        let items = [PlaylistItem(path: "/v/Bài giảng 1.mp4"), PlaylistItem(path: "/v/Phỏng vấn.mp4")]
        #expect(PlaylistEditor.search(items, query: "bai giang").count == 1)
        #expect(PlaylistEditor.search(items, query: "PHONG").count == 1)
        #expect(PlaylistEditor.search(items, query: "").count == 2)
    }

    @Test func duplicatedPlaylistGetsFreshIdsAndKeepsSources() {
        var p = list(["a", "b"]); p.currentItemID = p.items[0].id
        let c = PlaylistEditor.duplicate(p, newName: "Copy")
        #expect(c.id != p.id && c.items.map(\.path) == p.items.map(\.path))
        #expect(Set(c.items.map(\.id)).isDisjoint(with: p.items.map(\.id)))
        #expect(c.currentItemID == nil)
    }

    @Test func playlistRoundTripsThroughJSON() throws {
        var p = list(["a", "b"], mode: .shuffle, rep: .all, auto: false)
        p.currentItemID = p.items[1].id
        p.resumePosition = MediaTime(value: 12345, timescale: 600)
        p.folderSources = [PlaylistFolderSource(path: "/Videos", bookmark: Data([1, 2, 3]), includeSubfolders: true, follow: true)]
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(back == p)
    }

    @Test func totalsShowDurationAndUnknowns() {
        var p = list(["a", "b", "c"])
        p.items[0].duration = MediaTime(seconds: 60); p.items[1].duration = MediaTime(seconds: 30)
        #expect(p.totalDuration.seconds == 90 && p.unknownDurationCount == 1)
    }
}

@Suite struct FolderScanTests {
    private func fsWithFolder() -> FakeFileSystem {
        let fs = FakeFileSystem()
        fs.directories.formUnion(["/Media", "/Media/sub", "/Media/sub/deep", "/Media/.hidden"])
        for n in ["clip 10.mp4", "clip 2.mp4", "notes.txt", "report.pdf", ".DS_Store", ".x.macplayer-partial-1.mp4"] { fs.put("/Media/\(n)", "x") }
        fs.put("/Media/sub/in sub.mov", "x"); fs.put("/Media/sub/deep/deeper.mkv", "x"); fs.put("/Media/.hidden/secret.mp4", "x")
        return fs
    }

    @Test func topLevelOnlyByDefault() {
        let r = FolderScanner.scan(folder: "/Media", includeSubfolders: false, fs: fsWithFolder())
        #expect(Set(r.videos.map(\.name)) == ["clip 10.mp4", "clip 2.mp4"])
        #expect(r.skippedOther == 2, "notes.txt and report.pdf")
    }

    @Test func subfoldersOnlyWhenAsked_hiddenAlwaysSkipped() {
        let r = FolderScanner.scan(folder: "/Media", includeSubfolders: true, fs: fsWithFolder())
        #expect(Set(r.videos.map(\.name)) == ["clip 10.mp4", "clip 2.mp4", "in sub.mov", "deeper.mkv"])
    }

    @Test func scanSortsNaturally() {
        let r = FolderScanner.scan(folder: "/Media", includeSubfolders: false, fs: fsWithFolder())
        #expect(FolderScanner.sort(r.videos, by: .naturalName).map(\.name) == ["clip 2.mp4", "clip 10.mp4"])
    }

    @Test func cancelStopsTheScan() {
        var calls = 0
        let r = FolderScanner.scan(folder: "/Media", includeSubfolders: true, fs: fsWithFolder(), isCancelled: { calls += 1; return calls > 1 })
        #expect(r.cancelled)
    }

    @Test func unreadableFolderIsReportedNotFatal() {
        let fs = fsWithFolder()
        let r = FolderScanner.scan(folder: "/Gone", includeSubfolders: true, fs: fs)
        #expect(r.videos.isEmpty && r.unreadableFolders == ["/Gone"])
    }

    @Test func followingAFolderAppendsNewVideosAndFlagsMissingOnes() {
        let fs = fsWithFolder()
        let src = UUID()
        var items = [
            PlaylistItem(path: "/Media/clip 2.mp4", folderSourceID: src),
            PlaylistItem(path: "/Media/removed.mp4", folderSourceID: src),
            PlaylistItem(path: "/Elsewhere/other.mp4"),
        ]
        let scan = FolderScanner.scan(folder: "/Media", includeSubfolders: false, fs: fs)
        let change = FolderScanner.followChanges(items: items, sourceID: src, scan: scan)
        #expect(change.newVideos.map(\.name) == ["clip 10.mp4"])
        #expect(change.nowMissing == [items[1].id], "only this source's items, and only the vanished one")
        items[1].availability = .missing
        fs.put("/Media/removed.mp4", "x")
        let again = FolderScanner.followChanges(items: items, sourceID: src, scan: FolderScanner.scan(folder: "/Media", includeSubfolders: false, fs: fs))
        #expect(again.backAgain == [items[1].id])
    }

    @Test func anUnreadableFolderNeverMarksItsFilesMissing() {
        let src = UUID()
        let items = [PlaylistItem(path: "/Media/a.mp4", folderSourceID: src)]
        var scan = FolderScanResult(); scan.unreadableFolders = ["/Media"]
        #expect(FolderScanner.followChanges(items: items, sourceID: src, scan: scan).nowMissing.isEmpty, "drive unplugged is not 'file deleted'")
    }
}

@Suite struct PlaylistStoreTests {
    @Test func savesLoadsAndDeletesOnlyItsOwnFile() throws {
        let fs = FakeFileSystem()
        fs.put("/Videos/a.mp4", "VIDEO")
        let store = PlaylistStore(fs: fs, folder: "/Support/Playlists")
        var p = Playlist(name: "Một", items: [PlaylistItem(path: "/Videos/a.mp4")])
        p.playMode = .shuffle; p.currentItemID = p.items[0].id; p.resumePosition = MediaTime(seconds: 42)
        try store.save(p)
        try store.save(Playlist(name: "Hai"))
        let r = store.loadAll()
        #expect(r.playlists.count == 2 && r.playlists.first == p && r.damaged.isEmpty)
        store.delete(p.id)
        #expect(store.loadAll().playlists.map(\.name) == ["Hai"])
        #expect(fs.text("/Videos/a.mp4") == "VIDEO", "deleting a playlist never touches the video")
    }

    @Test func aDamagedFileIsReportedNotDeletedAndOthersStillLoad() throws {
        let fs = FakeFileSystem()
        let store = PlaylistStore(fs: fs, folder: "/P")
        try store.save(Playlist(name: "ok"))
        fs.put("/P/broken.playlist.json", "{ nope")
        let r = store.loadAll()
        #expect(r.playlists.count == 1 && r.damaged == ["/P/broken.playlist.json"] && fs.exists("/P/broken.playlist.json"))
    }
}
