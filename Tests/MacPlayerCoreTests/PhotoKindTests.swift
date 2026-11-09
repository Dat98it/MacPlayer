import Foundation
import Testing
@testable import MacPlayerCore

struct PhotoKindTests {
    @Test func filesAreToldApartByTheirExtension() {
        #expect(MediaFiles.kind(of: "/a/IMG_0001.HEIC") == .image && MediaFiles.kind(of: "/a/x.jpg") == .image && MediaFiles.kind(of: "/a/raw.DNG") == .image)
        #expect(MediaFiles.kind(of: "/a/clip.MOV") == .video && MediaFiles.kind(of: "/a/clip.mp4") == .video)
        #expect(MediaFiles.kind(of: "/a/notes.txt") == nil && MediaFiles.kind(of: "/a/noextension") == nil)
        #expect(PlaylistItem(path: "/a/p.png").isImage && !PlaylistItem(path: "/a/v.mp4").isImage)
    }

    @Test func aPlaylistTakesPicturesAndVideosAndRefusesTheRest() {
        var p = Playlist(name: "mix")
        let r = PlaylistEditor.add([PlaylistItem(path: "/x/a.jpg"), PlaylistItem(path: "/x/b.mp4"), PlaylistItem(path: "/x/c.pdf")], to: &p)
        #expect(p.items.map(\.title) == ["a", "b"] && r.unsupported == ["/x/c.pdf"])
    }

    @Test func aFolderScanFindsPicturesToo() {
        let fs = FakeFileSystem()
        fs.directories.formUnion(["/M"])
        for n in ["a.jpg", "b.PNG", "c.mov", "d.txt"] { fs.put("/M/\(n)", "x") }
        let r = FolderScanner.scan(folder: "/M", includeSubfolders: false, fs: fs)
        #expect(Set(r.videos.map(\.name)) == ["a.jpg", "b.PNG", "c.mov"] && r.skippedOther == 1)
    }

    @Test func formatsKnowTheirExtensionsAndWhichOnesLoseQuality() {
        #expect(PhotoFormat.jpeg.fileExtension == "jpg" && PhotoFormat.heic.fileExtension == "heic" && PhotoFormat.tiff.fileExtension == "tiff")
        #expect(PhotoFormat.jpeg.isLossy && PhotoFormat.heic.isLossy && !PhotoFormat.png.isLossy && !PhotoFormat.tiff.isLossy)
        #expect(PhotoFormat.matching(extension: "JPEG") == .jpeg && PhotoFormat.matching(extension: "heif") == .heic && PhotoFormat.matching(extension: "dng") == nil)
    }

    @Test func aSizeLimitShrinksTheLongSideAndNeverEnlarges() {
        #expect(PhotoSizing.fit(width: 4000, height: 3000, maxLongEdge: 2000) == (2000, 1500))
        #expect(PhotoSizing.fit(width: 3000, height: 4000, maxLongEdge: 2000) == (1500, 2000))
        #expect(PhotoSizing.fit(width: 800, height: 600, maxLongEdge: 2000) == (800, 600))
        #expect(PhotoSizing.fit(width: 800, height: 600, maxLongEdge: nil) == (800, 600))
    }

    @Test func oldPlaylistsStillLoadAndNewSettingsHaveDefaults() {
        let store = MemoryDefaults()
        let prefs = AppPreferences(store: store)
        #expect(prefs.photoSlideSeconds == 5)
        prefs.photoSlideSeconds = 500
        #expect(prefs.photoSlideSeconds == 60, "kept within a sensible range")
    }
}

private final class MemoryDefaults: PreferenceStoring {
    var d: [String: Any] = [:]
    func object(forKey key: String) -> Any? { d[key] }
    func set(_ value: Any?, forKey key: String) { d[key] = value }
}
