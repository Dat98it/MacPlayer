import Foundation
import Testing
@testable import MacPlayerCore

struct MediaLinkTests {
    private func ok(_ s: String) -> MediaLink.Link? { if case .ok(let l) = MediaLink.check(s) { return l }; return nil }

    @Test func directFilesAreRecognisedByTheirExtension() {
        #expect(ok("https://example.com/videos/bai-tap-01.mp4")?.kind == .video)
        #expect(ok("https://cdn.example.com/clip/intro.MOV")?.kind == .video)
        #expect(ok("https://stream.example.com/live/kenh1/index.m3u8")?.kind == .stream)
        #expect(ok("https://example.com/anh/san-bong.jpg")?.kind == .photo)
        #expect(ok("https://i.example.com/logo.png?w=200")?.kind == .photo, "a query does not hide the extension")
        #expect(ok("https://example.com/song.mp3")?.kind == .video, "sound files play like videos")
        #expect(ok("https://example.com/watch?id=12")?.kind == .unknown, "no extension: the server is asked")
    }

    @Test func pastedTextIsCleanedUp() {
        #expect(ok("  https://example.com/a.mp4 \n")?.url.absoluteString == "https://example.com/a.mp4")
        #expect(ok("<https://example.com/a.mp4>")?.kind == .video)
        #expect(ok("\"https://example.com/a.mp4\"")?.kind == .video)
        #expect(ok("example.com/a.mp4")?.url.absoluteString == "https://example.com/a.mp4", "an address without https:// gets it")
        #expect(ok("https://example.com/Đà Lạt.mp4")?.url.absoluteString.contains("%20") == true, "spaces are escaped")
        #expect(ok("https://example.com/Đà Lạt.mp4")?.displayName == "Đà Lạt", "and read back for the name")
        #expect(ok("https://example.com/a%20b.mp4")?.url.absoluteString == "https://example.com/a%20b.mp4", "escapes already there are kept")
        #expect(ok("https://example.com/a.mp4\nhttps://example.com/b.mp4")?.url.lastPathComponent == "a.mp4", "only the first line")
        #expect(ok("HTTPS://Example.COM/a.mp4")?.url.host == "example.com")
        #expect(ok("http://192.168.1.20:8080/cam/index.m3u8")?.kind == .stream, "a camera on the local network")
        #expect(ok("example.com:8080/a.mp4")?.url.port == 8080)
    }

    @Test func emptyAndNotWebAddresses() {
        #expect(MediaLink.check("") == .empty)
        #expect(MediaLink.check("   ") == .empty)
        #expect(MediaLink.check("/Users/a/video.mp4") == .problem(.notWeb))
        #expect(MediaLink.check("~/Movies/a.mov") == .problem(.notWeb))
        #expect(MediaLink.check("file:///Users/a/video.mp4") == .problem(.notWeb))
        #expect(MediaLink.check("ftp://example.com/a.mp4") == .problem(.notWeb))
        #expect(MediaLink.check("mailto:a@b.com") == .problem(.notWeb))
        #expect(MediaLink.check("hello") == .problem(.malformed))
        #expect(MediaLink.check("https://") == .problem(.malformed))
        #expect(MediaLink.check("https://nohost/a.mp4") == .problem(.malformed))
    }

    @Test func watchPagesOfSitesAreNamed() {
        #expect(MediaLink.check("https://www.youtube.com/watch?v=abc123") == .page(.youtube))
        #expect(MediaLink.check("https://youtu.be/abc123") == .page(.youtube))
        #expect(MediaLink.check("https://m.youtube.com/shorts/abc") == .page(.youtube))
        #expect(MediaLink.check("https://www.facebook.com/watch/?v=123456") == .page(.facebook))
        #expect(MediaLink.check("https://fb.watch/abc/") == .page(.facebook))
        #expect(MediaLink.check("https://www.tiktok.com/@ten/video/7300000000") == .page(.tiktok))
        #expect(MediaLink.check("https://vm.tiktok.com/ZM123/") == .page(.tiktok))
        #expect(MediaLink.check("https://drive.google.com/file/d/xxxx/view") == .page(.googleDrive))
        #expect(MediaLink.check("https://www.instagram.com/reel/abc/") == .page(.instagram))
        #expect(MediaLink.check("https://x.com/a/status/1") == .page(.x))
        #expect(MediaLink.check("https://notyoutube.com/a.mp4") != .page(.youtube), "only the site itself, not a name that ends the same")
    }

    @Test func dropboxShareLinksBecomeDirect() {
        let l = ok("https://www.dropbox.com/s/abc123/clip.mp4?dl=0")
        #expect(l?.kind == .video)
        #expect(l?.url.query == "raw=1")
        #expect(l?.notes.contains(.dropboxMadeDirect) == true)
        #expect(ok("https://www.dropbox.com/scl/fi/xyz/photo.jpg?rlkey=k&dl=0")?.url.query == "rlkey=k&raw=1")
    }

    @Test func formatsThisMacCannotPlayAreSaidAtOnce() {
        #expect(MediaLink.check("https://example.com/film.mkv") == .problem(.unsupported("MKV")))
        #expect(MediaLink.check("https://example.com/clip.webm") == .problem(.unsupported("WEBM")))
        #expect(MediaLink.check("https://example.com/old.avi") == .problem(.unsupported("AVI")))
    }

    @Test func plainHTTPIsNoted() {
        #expect(ok("http://example.com/a.mp4")?.notes == [.notEncrypted])
        #expect(ok("https://example.com/a.mp4")?.notes == [])
    }

    @Test func whatTheServerSaysDecidesALinkWithoutExtension() {
        #expect(MediaLink.kind(ofContentType: "video/mp4") == .video)
        #expect(MediaLink.kind(ofContentType: "video/quicktime; charset=binary") == .video)
        #expect(MediaLink.kind(ofContentType: "application/vnd.apple.mpegurl") == .stream)
        #expect(MediaLink.kind(ofContentType: "application/x-mpegURL") == .stream)
        #expect(MediaLink.kind(ofContentType: "image/jpeg") == .photo)
        #expect(MediaLink.kind(ofContentType: "audio/mpeg") == .video)
        #expect(MediaLink.kind(ofContentType: "application/octet-stream") == .unknown)
        #expect(MediaLink.kind(ofContentType: "text/html; charset=utf-8") == nil, "a web page")
        #expect(MediaLink.kind(ofContentType: "video/webm") == nil)
        #expect(MediaLink.kind(ofContentType: "image/svg+xml") == nil)
    }

    @Test func theFirstBytesSayWhatAFileIs() {
        func b(_ s: String, at i: Int = 0) -> [UInt8] { Array(repeating: 0, count: i) + Array(s.utf8) + Array(repeating: 0, count: 8) }
        #expect(MediaLink.sniff(b("ftypisom", at: 4))?.mime == "video/mp4")
        #expect(MediaLink.sniff(b("ftypqt  ", at: 4))?.mime == "video/quicktime")
        #expect(MediaLink.sniff(b("#EXTM3U\n#EXT-X-VERSION:3"))?.kind == .stream)
        #expect(MediaLink.sniff([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])?.kind == .photo)
        #expect(MediaLink.sniff([0x89] + Array("PNG\r\n".utf8))?.mime == "image/png")
        #expect(MediaLink.sniff(b("ID3"))?.mime == "audio/mpeg")
        #expect(MediaLink.sniff(b("<!DOCTYPE html>")) == nil)
        #expect(MediaLink.sniff([]) == nil)
    }

    @Test func namesToShowAndToSave() {
        #expect(MediaLink.displayName(of: URL(string: "https://example.com/videos/B%C3%A0i%20t%E1%BA%ADp.mp4")!) == "Bài tập")
        #expect(MediaLink.displayName(of: URL(string: "https://stream.example.com/live/index.m3u8")!) == "stream.example.com")
        #expect(MediaLink.displayName(of: URL(string: "https://example.com/")!) == "example.com")
        #expect(MediaLink.suggestedFileName(for: URL(string: "https://example.com/v/clip.mp4")!, kind: .video) == "clip.mp4")
        #expect(MediaLink.suggestedFileName(for: URL(string: "https://example.com/watch")!, kind: .unknown, contentType: "video/quicktime") == "watch.mov")
        #expect(MediaLink.suggestedFileName(for: URL(string: "https://example.com/")!, kind: .photo) == "example.com.jpg")
        #expect(MediaLink.suggestedFileName(for: URL(string: "https://example.com/a%3Ab.png")!, kind: .photo) == "a-b.png", "no characters Finder refuses")
    }

    @Test func recentLinksAreNewestFirstWithoutRepeats() {
        var list: [String] = []
        list = RecentLinks.adding("https://a/1.mp4", to: list)
        list = RecentLinks.adding("https://a/2.mp4", to: list)
        list = RecentLinks.adding(" https://a/1.mp4 ", to: list)
        #expect(list == ["https://a/1.mp4", "https://a/2.mp4"])
        for i in 0..<30 { list = RecentLinks.adding("https://a/x\(i).mp4", to: list) }
        #expect(list.count == RecentLinks.limit && list.first == "https://a/x29.mp4")
        #expect(RecentLinks.removing("https://a/x29.mp4", from: list).first == "https://a/x28.mp4")
        #expect(RecentLinks.adding("  ", to: ["a"]) == ["a"])
    }

    @Test func aPlayerWindowFitsThePictureAndTheScreen() {
        let screen = CGSize(width: 1728, height: 1080), minimum = CGSize(width: 420, height: 300)
        // A 4K video: limited by the screen, at the video's shape.
        let big = PlayerWindowSizing.contentSize(media: CGSize(width: 3840, height: 2160), chrome: 120, screen: screen, minimum: minimum)
        #expect(big.width <= screen.width * 0.8 + 1 && big.height <= screen.height)
        #expect(abs(big.width / (big.height - 120) - 16.0 / 9) < 0.02)
        // A phone video standing up: tall and narrow, still within the screen.
        let tall = PlayerWindowSizing.contentSize(media: CGSize(width: 1080, height: 1920), chrome: 120, screen: screen, minimum: minimum)
        #expect(tall.height <= screen.height && tall.width < tall.height)
        #expect(abs(tall.width / (tall.height - 120) - 9.0 / 16) < 0.03)
        // A small video opens at its own size (a pixel a point), as in QuickTime Player.
        let small640 = PlayerWindowSizing.contentSize(media: CGSize(width: 640, height: 360), chrome: 120, screen: screen, minimum: minimum)
        #expect(small640.width == 640 && small640.height == 480)
        // A tiny picture: never smaller than the window's minimum.
        let tiny = PlayerWindowSizing.contentSize(media: CGSize(width: 160, height: 90), chrome: 120, screen: screen, minimum: minimum)
        #expect(tiny.width >= minimum.width && tiny.height >= minimum.height)
        // Nothing known about the picture: 16:9.
        let none = PlayerWindowSizing.contentSize(media: nil, chrome: 120, screen: screen, minimum: minimum)
        #expect(none.width > minimum.width && abs(none.width / (none.height - 120) - 16.0 / 9) < 0.02)
        // A small screen: the window fits on it.
        let small = PlayerWindowSizing.contentSize(media: CGSize(width: 3840, height: 2160), chrome: 120, screen: CGSize(width: 1280, height: 700), minimum: minimum)
        #expect(small.width <= 1280 && small.height <= 700)
    }
}
