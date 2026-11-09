import Foundation
import Testing
@testable import MacPlayerCore

/// Folders a playlist follows, and what taking videos out of such a playlist means.
struct PlaylistFolderTests {
    let src = PlaylistFolderSource(path: "/Media", includeSubfolders: false, follow: true)

    func playlist() -> Playlist {
        var p = Playlist(name: "P", folderSources: [src])
        p.items = [PlaylistItem(path: "/Media/clip 1.mp4", folderSourceID: src.id), PlaylistItem(path: "/Media/clip 2.mp4", folderSourceID: src.id),
                   PlaylistItem(path: "/Elsewhere/own.mp4")]
        return p
    }

    func scan(_ names: [String]) -> FolderScanResult {
        var r = FolderScanResult()
        r.videos = names.map { ScannedVideo(path: "/Media/\($0)", name: $0, size: 1, modified: Date()) }
        return r
    }

    @Test func aVideoTakenOutOfAFollowedFolderIsNotBroughtBack() {
        var p = playlist()
        let gone = p.items[1]
        PlaylistEditor.remove([gone.id], from: &p)
        #expect(p.excludedPaths == ["/Media/clip 2.mp4"])
        let s = scan(["clip 1.mp4", "clip 2.mp4", "clip 3.mp4"])
        #expect(FolderScanner.followChanges(items: p.items, sourceID: src.id, scan: s).newVideos.map(\.name) == ["clip 2.mp4", "clip 3.mp4"], "without the memory it would come back")
        #expect(FolderScanner.followChanges(items: p.items, sourceID: src.id, scan: s, excluded: Set(p.excludedPaths)).newVideos.map(\.name) == ["clip 3.mp4"])
    }

    @Test func takingOutAnOrdinaryEntryRemembersNothing() {
        var p = playlist()
        PlaylistEditor.remove([p.items[2].id], from: &p)
        #expect(p.excludedPaths.isEmpty)
    }

    @Test func addingAVideoOnPurposeLiftsItsExclusion() {
        var p = playlist()
        PlaylistEditor.remove([p.items[0].id], from: &p)
        #expect(p.excludedPaths == ["/Media/clip 1.mp4"])
        PlaylistEditor.add([PlaylistItem(path: "/Media/clip 1.mp4")], to: &p)
        #expect(p.excludedPaths.isEmpty && p.items.contains { $0.path == "/Media/clip 1.mp4" })
    }

    @Test func stoppingUsingAFolderForgetsItsExclusionsAndKeepsOtherFolders() {
        var p = playlist()
        let other = PlaylistFolderSource(path: "/Media2", includeSubfolders: false, follow: true)
        p.folderSources.append(other)
        p.items.append(PlaylistItem(path: "/Media2/x.mp4", folderSourceID: other.id))
        PlaylistEditor.remove([p.items[0].id, p.items[3].id], from: &p)
        #expect(Set(p.excludedPaths) == ["/Media/clip 1.mp4", "/Media2/x.mp4"])
        let ids = PlaylistEditor.itemIDs(ofSource: src.id, in: p)
        #expect(ids == [p.items[0].id], "the one remaining video of /Media")
        PlaylistEditor.removeFolderSource(src.id, from: &p)
        #expect(p.folderSources.map(\.path) == ["/Media2"])
        #expect(p.excludedPaths == ["/Media2/x.mp4"], "a folder with a similar name (/Media2) is not mistaken for /Media's contents")
        #expect(p.items.count == 2, "stopping does not remove videos by itself")
    }

    @Test func aFolderAddedToOnePlaylistDoesNotTouchAnother() {
        var a = playlist(), b = Playlist(name: "B")
        PlaylistEditor.add([PlaylistItem(path: "/New/v.mp4")], to: &b)
        PlaylistEditor.remove([a.items[0].id], from: &a)
        #expect(b.items.map(\.path) == ["/New/v.mp4"] && b.excludedPaths.isEmpty && b.folderSources.isEmpty)
    }

    @Test func playlistsSavedByAnOlderVersionStillLoadAndNewOnesRoundTrip() throws {
        var p = playlist()
        PlaylistEditor.remove([p.items[1].id], from: &p)
        let enc = JSONEncoder(), dec = JSONDecoder()
        let data = try enc.encode(p)
        #expect(try dec.decode(Playlist.self, from: data) == p)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "excludedPaths")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try dec.decode(Playlist.self, from: old)
        #expect(back.excludedPaths.isEmpty && back.items.count == p.items.count && back.folderSources == p.folderSources)
    }

    @Test func rememberedWindowStateRoundTripsWithSafeDefaults() {
        final class Dict: PreferenceStoring {
            var d: [String: Any] = [:]
            func object(forKey key: String) -> Any? { d[key] }
            func set(_ value: Any?, forKey key: String) { if let value { d[key] = value } else { d.removeValue(forKey: key) } }
        }
        let store = Dict(); let prefs = AppPreferences(store: store)
        #expect(prefs.lastPlaylistID == nil && !prefs.sidebarShowsRecent && !prefs.playlistPanelHidden && !prefs.toolsPanelHidden)
        let id = UUID()
        prefs.lastPlaylistID = id; prefs.sidebarShowsRecent = true; prefs.playlistPanelHidden = true; prefs.toolsPanelHidden = true
        let again = AppPreferences(store: store)
        #expect(again.lastPlaylistID == id && again.sidebarShowsRecent && again.playlistPanelHidden && again.toolsPanelHidden)
        prefs.lastPlaylistID = nil
        #expect(AppPreferences(store: store).lastPlaylistID == nil)
    }
}
