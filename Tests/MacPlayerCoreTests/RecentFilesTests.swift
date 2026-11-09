import Foundation
import Testing
@testable import MacPlayerCore

struct RecentFilesTests {
    let urls = [
        URL(fileURLWithPath: "/Users/a/Videos/Bài giảng 1.mp4"),
        URL(fileURLWithPath: "/Users/a/Videos/Đêm Hà Nội.mov"),
        URL(fileURLWithPath: "/Volumes/Ổ ngoài/Photos-1-001/IMG_0510.MOV"),
        URL(fileURLWithPath: "/Users/a/Projects/Phỏng vấn.macplayer"),
    ]

    @Test func emptyQueryKeepsEverythingInOrder() {
        #expect(RecentFiles.search(urls, query: "") == urls)
        #expect(RecentFiles.search(urls, query: "   ") == urls)
    }

    @Test func ignoresCaseAndVietnameseAccents() {
        #expect(RecentFiles.search(urls, query: "bai giang").map(\.lastPathComponent) == ["Bài giảng 1.mp4"])
        #expect(RecentFiles.search(urls, query: "PHONG VAN").map(\.lastPathComponent) == ["Phỏng vấn.macplayer"])
        #expect(RecentFiles.search(urls, query: "dem ha noi").map(\.lastPathComponent) == ["Đêm Hà Nội.mov"])
        #expect(RecentFiles.search(urls, query: "đêm").count == 1)
    }

    @Test func everyWordMustMatchInAnyOrder() {
        #expect(RecentFiles.search(urls, query: "noi dem").count == 1)
        #expect(RecentFiles.search(urls, query: "dem xyz").isEmpty)
    }

    @Test func matchesTheFolderToo() {
        #expect(RecentFiles.search(urls, query: "photos-1-001").map(\.lastPathComponent) == ["IMG_0510.MOV"])
        #expect(RecentFiles.search(urls, query: "o ngoai img").count == 1)
        #expect(RecentFiles.search(urls, query: "videos").count == 2)
    }

    @Test func aFileNameMatchBeatsTheFolder() {
        let tmp = [URL(fileURLWithPath: "/private/var/2024/work/clip 1.mp4"), URL(fileURLWithPath: "/private/var/2024/work/clip 2.mp4"),
                   URL(fileURLWithPath: "/private/var/2024/work/clip 10.mp4")]
        #expect(RecentFiles.search(tmp, query: "clip 2").map(\.lastPathComponent) == ["clip 2.mp4"])
        #expect(RecentFiles.search(tmp, query: "2024").count == 3)      // no name has it, so the folder is searched
    }

    @Test func extensionIsSearchableAndNoMatchGivesEmpty() {
        #expect(RecentFiles.search(urls, query: ".macplayer").count == 1)
        #expect(RecentFiles.search(urls, query: "không có").isEmpty)
    }
}
