import Foundation
import Testing
@testable import MacPlayerCore

struct MissingFilesTests {
    func fs() -> FakeFileSystem {
        let f = FakeFileSystem()
        f.directories.formUnion(["/Users", "/Users/me", "/Users/me/Videos", "/Volumes"])
        f.put("/Users/me/Videos/here.mp4", "x")
        return f
    }

    @Test func aFileThatIsThereIsPresent() {
        #expect(MissingFiles.status(of: "/Users/me/Videos/here.mp4", fs: fs()) == .present)
    }

    @Test func aFileMissingFromAFolderThatIsThereWasDeleted() {
        #expect(MissingFiles.status(of: "/Users/me/Videos/gone.mp4", fs: fs()) == .deleted)
    }

    @Test func aFileWhoseWholeFolderWasDeletedIsDeletedToo() {
        #expect(MissingFiles.status(of: "/Users/me/Videos/old trip/part 1/clip.mp4", fs: fs()) == .deleted, "a folder higher up still exists")
    }

    @Test func aDriveThatIsNotConnectedIsNeverDeleted() {
        let f = fs()
        // The mount point is an empty folder that macOS left behind: the folder is there, the drive is not.
        f.directories.insert("/Volumes/Backup")
        #expect(MissingFiles.status(of: "/Volumes/Backup/clips/a.mp4", fs: f, driveConnected: { !$0.hasPrefix("/Volumes/Backup") }) == .unknown)
        // And with no leftover folder at all.
        #expect(MissingFiles.status(of: "/Volumes/Other/clips/a.mp4", fs: f) == .unknown, "nothing above the file but the folder of drives")
    }

    @Test func aLocationWithNothingReadableAboveItIsUnknown() {
        #expect(MissingFiles.status(of: "/Nowhere/at/all.mp4", fs: fs()) == .unknown)
    }

    @Test func theTrashCountsAsGone() {
        #expect(MissingFiles.isInTrash("/Users/me/.Trash/clip.mp4") && MissingFiles.isInTrash("/Volumes/X/.Trashes/501/clip.mp4"))
        #expect(!MissingFiles.isInTrash("/Users/me/Videos/Trash talk.mp4"))
    }

    @Test func videosGoneFromTheDiskLeaveWithoutBeingRememberedAsTakenOut() {
        let src = PlaylistFolderSource(path: "/Users/me/Videos", includeSubfolders: false, follow: true)
        var p = Playlist(name: "P", folderSources: [src])
        p.items = [PlaylistItem(path: "/Users/me/Videos/here.mp4", folderSourceID: src.id), PlaylistItem(path: "/Users/me/Videos/gone.mp4", folderSourceID: src.id)]
        PlaylistEditor.remove([p.items[1].id], from: &p, remembering: false)
        #expect(p.items.map(\.path) == ["/Users/me/Videos/here.mp4"] && p.excludedPaths.isEmpty, "if the file comes back, following picks it up again")
        PlaylistEditor.remove([p.items[0].id], from: &p)
        #expect(p.excludedPaths == ["/Users/me/Videos/here.mp4"], "a video the person took out on purpose is still remembered")
    }
}
