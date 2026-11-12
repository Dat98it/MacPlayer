import Foundation
import Testing
@testable import MacPlayerCore

/// 0.16: sounds play on their own and start projects; animations keep moving when saved as PNG.
struct SoundMediaTests {
    @Test func soundsAreMediaOfTheirOwnKind() {
        for p in ["/m/a.mp3", "/m/b.M4A", "/m/c.flac", "/m/d.wav", "/m/e.aiff", "/m/f.caf", "/m/g.aac", "/m/h.m4b"] {
            #expect(MediaFiles.kind(of: p) == .audio, "\(p)")
            #expect(MediaFiles.isCandidate(p))
        }
        #expect(MediaFiles.kind(of: "/m/a.mp4") == .video && MediaFiles.kind(of: "/m/a.gif") == .image && MediaFiles.kind(of: "/m/a.txt") == nil)
        #expect(MediaBin.kind(of: "/m/a.mp3") == .audio && MediaBin.kind(of: "/m/a.mov") == .video && MediaBin.kind(of: "/m/a.png") == .photo)
        let item = PlaylistItem(path: "/m/song.mp3")
        #expect(item.isAudio && !item.isImage)
    }

    @Test func aFolderScanAndAPlaylistTakeSounds() {
        var p = Playlist(name: "Mixed")
        let report = PlaylistEditor.add(["/m/a.mp4", "/m/b.mp3", "/m/c.jpg", "/m/notes.txt"].map { PlaylistItem(path: $0) }, to: &p)
        #expect(p.items.map(\.path) == ["/m/a.mp4", "/m/b.mp3", "/m/c.jpg"])
        #expect(report.unsupported == ["/m/notes.txt"])
    }

    @Test func aVideoProjectTakesSoundsOnItsMainTrackAndAPhotoProjectDoesNot() {
        let video = Project(name: "v", kind: .video)
        #expect(ProjectRules.canAdd(paths: ["/m/a.mp3"], to: video) == .ok)
        #expect(ProjectRules.canAdd(paths: ["/m/a.mp4", "/m/a.m4a"], to: video) == .ok)
        #expect(ProjectRules.canAdd(paths: ["/m/a.mp3"], to: Project(name: "p", kind: .photo)) == .wrongKind(project: .photo))
        #expect(ProjectRules.canAdd(paths: ["/m/a.txt"], to: video) == .notMedia)
    }

    @Test func aSoundSourceShowsTheSoundAndOldProjectsStillOpen() throws {
        let s = SourceRef(path: "/tmp/covers/123.mov", soundOf: "/m/Song.mp3")
        #expect(s.mediaPath == "/m/Song.mp3" && s.isMade)
        #expect(SourceRef(path: "/tmp/stills/1.mov", stillOf: "/m/p.jpg").isMade && !SourceRef(path: "/m/v.mp4").isMade)
        // Written and read back.
        let back = try JSONDecoder().decode(SourceRef.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        // A 0.15 file has no `soundOf`.
        let old = #"{"id":"7B1F3A52-6C1E-4E59-9E0B-0A4B8F2B9C11","path":"/m/v.mp4"}"#
        let ref = try JSONDecoder().decode(SourceRef.self, from: Data(old.utf8))
        #expect(ref.soundOf == nil && ref.mediaPath == "/m/v.mp4")
    }

    @Test func gifAndPNGKeepAnAnimation() {
        #expect(PhotoFormat.gif.keepsAnimation && PhotoFormat.png.keepsAnimation)
        #expect(!PhotoFormat.jpeg.keepsAnimation && !PhotoFormat.heic.keepsAnimation && !PhotoFormat.tiff.keepsAnimation)
    }

    @Test func soundsAreRecognisedFromTheirFirstBytes() {
        func b(_ s: String, at: Int = 0) -> [UInt8] { Array(repeating: 0, count: at) + Array(s.utf8) + Array(repeating: 0, count: 16) }
        #expect(MediaLink.sniff(b("fLaC"))?.mime == "audio/flac")
        #expect(MediaLink.sniff(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8))?.mime == "audio/wav")
        #expect(MediaLink.sniff(Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFFCOMM".utf8))?.mime == "audio/aiff")
        #expect(MediaLink.sniff([0, 0, 0, 0x20] + Array("ftypM4A ".utf8))?.mime == "audio/mp4")
        #expect(MediaLink.sniff([0, 0, 0, 0x20] + Array("ftypisom".utf8))?.mime == "video/mp4")
        #expect(MediaLink.sniff(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBPVP8 ".utf8))?.kind == .photo)
    }

    @Test func oggPlaysAndWMAIsTurnedAwayEvenAsALink() {
        #expect(MediaFiles.kind(of: "/m/a.opus") == .audio && MediaFiles.kind(of: "/m/a.ogg") == .audio && MediaFiles.kind(of: "/m/a.wma") == nil)
        if case .ok(let l) = MediaLink.check("https://example.com/a.opus") { #expect(l.kind == .video) } else { Issue.record("an .opus link is accepted") }
        if case .problem(.unsupported(let what)) = MediaLink.check("https://example.com/a.wma") { #expect(what == "WMA") } else { Issue.record("a .wma link is turned away") }
        #expect(MediaLink.kind(ofContentType: "audio/ogg") == .video && MediaLink.kind(ofContentType: "audio/x-ms-wma") == nil)
        #expect(MediaLink.sniff(Array("OggS".utf8) + [0, 2, 0, 0, 0, 0, 0, 0])?.mime == "audio/ogg")
    }

    @Test func aPictureSlowerThanOneASecondNeverBreaksTheTimecode() {
        // The cover video of a sound: one picture every 5 s.
        let slow = FrameRate(numerator: 200, denominator: 1000)
        #expect(!Timecode.format(MediaTime(value: 1422, timescale: 600), frameRate: slow).isEmpty)
        #expect(Timecode.parse("00:00:02:00", frameRate: slow) != nil)
        let info = MediaInfo(duration: MediaTime(seconds: 60), fileExtension: "mov", fileSize: 1,
                             video: [.init(trackID: 1, codec: "avc1", width: 1920, height: 1080, frameRate: slow)], audio: [])
        #expect(info.frameRateForStepping.framesPerSecond == 30)
    }

    @Test func aSongsTitleAndArtistAreTextsThatCanBeChanged() {
        let t = SoundTitles.overlays(title: " Bài hát ", artist: "Nghệ sĩ", album: "Album 1", start: .zero, end: MediaTime(seconds: 200))
        #expect(t.count == 2)
        #expect(t[0].text == "Bài hát" && t[0].x == 0.5 && t[0].y == SoundTitles.titleY && t[0].end == MediaTime(seconds: 200) && !t[0].isShape)
        #expect(t[1].text == "Nghệ sĩ · Album 1" && t[1].sizeFraction < t[0].sizeFraction && t[1].y > t[0].y)
        // Seen from the first frame: no fade in at 0:00 (it left them see-through when the project opened).
        #expect(t.allSatisfy { $0.fade == 0 && $0.animationIn == nil })
        #expect(t.allSatisfy(SoundTitles.isSongText) && !SoundTitles.isSongText(TextOverlay(text: "x", start: .zero, end: MediaTime(seconds: 1))))
        // Under the cover tile (which ends at 65% of the height) and inside the picture.
        #expect(t.allSatisfy { $0.y > 0.7 && $0.y < 0.95 })
        // No artist: the title only; no album: the artist alone; an empty title: nothing for it.
        #expect(SoundTitles.overlays(title: "Song", artist: nil, album: "Album", start: .zero, end: MediaTime(seconds: 1)).map(\.text) == ["Song"])
        #expect(SoundTitles.overlays(title: "Song", artist: "A", album: nil, start: .zero, end: MediaTime(seconds: 1)).map(\.text) == ["Song", "A"])
        #expect(SoundTitles.overlays(title: "  ", artist: nil, album: nil, start: .zero, end: MediaTime(seconds: 1)).isEmpty)
    }
}
