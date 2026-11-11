import Foundation
import Testing
@testable import MacPlayerCore

@Suite struct MediaBinTests {
    @Test func filesAreSortedIntoVideosPhotosAndSounds() {
        #expect(MediaBin.kind(of: "/a/clip.MOV") == .video)
        #expect(MediaBin.kind(of: "/a/b.heic") == .photo)
        #expect(MediaBin.kind(of: "/a/song.mp3") == .audio)
        #expect(MediaBin.kind(of: "/a/voice.m4a") == .audio)
        #expect(MediaBin.kind(of: "/a/notes.txt") == nil)
        #expect(MediaBin.kind(of: "/a/p.macplayer") == nil)
    }

    @Test func addingKeepsOrderAndSkipsDuplicatesAndOtherFiles() {
        var items: [BinItem] = []
        let added = MediaBin.add(["/v/a.mp4", "/v/b.jpg", "/v/a.mp4", "/v/x.pdf", "/v/c.wav"], to: &items)
        #expect(added.map(\.path) == ["/v/a.mp4", "/v/b.jpg", "/v/c.wav"])
        #expect(items.map(\.kind) == [.video, .photo, .audio])
        // The same file written differently (decomposed accents) is the same file.
        let again = MediaBin.add(["/v/a.mp4", "/v/Đà Lạt.mp4".decomposedStringWithCanonicalMapping], to: &items)
        #expect(again.count == 1)
        #expect(MediaBin.add(["/v/Đà Lạt.mp4".precomposedStringWithCanonicalMapping], to: &items).isEmpty)
        #expect(items.first?.name == "a")
    }

    @Test func aProjectShowsWhatItUsesEvenWithoutALibrary() throws {
        var p = Project(name: "P", kind: .video)
        let sid = p.addSource(SourceRef(path: "/m/one.mp4"))
        p.timeline = [TimelineClip(sourceID: sid, sourceStart: .zero, sourceEnd: MediaTime(seconds: 2))]
        p.soundClips = [SoundClip(name: "song", path: "/m/song.mp3", start: .zero, duration: MediaTime(seconds: 1), fileDuration: MediaTime(seconds: 1))]
        #expect(p.mediaBin.isEmpty)
        #expect(p.libraryItems.map(\.path) == ["/m/one.mp4", "/m/song.mp3"])
        #expect(p.uses(path: "/m/one.mp4") && p.uses(path: "/m/song.mp3") && !p.uses(path: "/m/other.mp4"))
        // Brought in, not used.
        MediaBin.add(["/m/later.mov"], to: &p.mediaBin)
        #expect(p.libraryItems.map(\.path) == ["/m/later.mov", "/m/one.mp4", "/m/song.mp3"])
        #expect(!p.uses(path: "/m/later.mov"))
        // A source no clip uses any more is not "used".
        p.timeline = []
        #expect(!p.uses(path: "/m/one.mp4"))
    }

    @Test func theLibraryIsSavedAndAnEmptyOneIsLeftOutOfTheFile() throws {
        var p = Project(name: "P", kind: .video)
        let plain = try #require(String(data: try ProjectCodec.encode(p), encoding: .utf8))
        #expect(!plain.contains("binStore"), "an empty library writes nothing, so older MacPlayers read the file as before")
        MediaBin.add(["/m/a.mp4", "/m/b.png"], to: &p.mediaBin)
        let back = try ProjectCodec.decode(try ProjectCodec.encode(p))
        #expect(back.mediaBin.map(\.path) == ["/m/a.mp4", "/m/b.png"] && back.mediaBin.map(\.kind) == [.video, .photo])
        // A file written before the library existed opens with an empty one.
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(p)) as? [String: Any])
        obj["binStore"] = nil
        let old = try ProjectCodec.decode(try JSONSerialization.data(withJSONObject: obj))
        #expect(old.mediaBin.isEmpty)
    }

    @Test func aPhotoClipIsShownAndCountedAsItsPhoto() throws {
        var p = Project(name: "P", kind: .video)
        let sid = p.addSource(SourceRef(path: "/Support/Stills/abc.mov", stillOf: "/Photos/beach.jpg"))
        p.timeline = [TimelineClip(sourceID: sid, sourceStart: .zero, sourceEnd: MediaTime(seconds: 5))]
        #expect(p.source(sid)?.mediaPath == "/Photos/beach.jpg")
        #expect(p.libraryItems.map(\.path) == ["/Photos/beach.jpg"] && p.libraryItems.first?.kind == .photo, "the library shows the photo, not its little video")
        #expect(p.uses(path: "/Photos/beach.jpg") && !p.uses(path: "/Support/Stills/abc.mov"))
        let back = try ProjectCodec.decode(try ProjectCodec.encode(p))
        #expect(back.sources.first?.stillOf == "/Photos/beach.jpg")
        // Sources written before photo clips existed have no `stillOf`.
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(p)) as? [String: Any])
        var srcs = try #require(obj["sources"] as? [[String: Any]]); srcs[0]["stillOf"] = nil; obj["sources"] = srcs
        let old = try ProjectCodec.decode(try JSONSerialization.data(withJSONObject: obj))
        #expect(old.sources.first?.stillOf == nil && old.sources.first?.mediaPath == "/Support/Stills/abc.mov")
    }

    @Test func filesInUseKeepTheSameIdEveryTime() {
        var p = Project(name: "P", kind: .video)
        let sid = p.addSource(SourceRef(path: "/m/Đà Lạt.mp4".decomposedStringWithCanonicalMapping))
        p.timeline = [TimelineClip(sourceID: sid, sourceStart: .zero, sourceEnd: MediaTime(seconds: 1))]
        #expect(p.libraryItems.map(\.id) == p.libraryItems.map(\.id), "the same ids at every look (a new one each time made the tiles flicker)")
        #expect(BinItem.stableID(for: "/m/Đà Lạt.mp4".precomposedStringWithCanonicalMapping) == p.libraryItems[0].id, "the same file in either Unicode form")
        #expect(BinItem.stableID(for: "/m/a.mp4") != BinItem.stableID(for: "/m/b.mp4"))
    }
}

