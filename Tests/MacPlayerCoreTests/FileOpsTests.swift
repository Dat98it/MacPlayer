import Foundation
import Testing
@testable import MacPlayerCore

struct FileOpsTests {
    func fs() -> FakeFileSystem {
        let f = FakeFileSystem()
        f.directories.formUnion(["/V"])
        f.put("/V/clip.mp4", "A"); f.put("/V/other.mp4", "B"); f.put("/V/noext", "C")
        return f
    }

    @Test func theExtensionIsKeptAndNeverDoubled() {
        #expect(FileOps.newFileName(forTyped: "holiday", oldPath: "/V/clip.mp4") == "holiday.mp4")
        #expect(FileOps.newFileName(forTyped: "holiday.mp4", oldPath: "/V/clip.mp4") == "holiday.mp4")
        #expect(FileOps.newFileName(forTyped: "  holiday.MP4 ", oldPath: "/V/clip.mp4") == "holiday.mp4")
        #expect(FileOps.newFileName(forTyped: "holiday", oldPath: "/V/noext") == "holiday")
        #expect(FileOps.newFileName(forTyped: "v1.5", oldPath: "/V/clip.mp4") == "v1.5.mp4", "a dot inside the name is a dot inside the name")
    }

    @Test func badNamesAreRefusedBeforeAnythingHappens() {
        func p(_ t: String) -> RenameError? { FileOps.problem(withTyped: t, oldPath: "/V/clip.mp4") }
        #expect(p("") == .emptyName && p("   ") == .emptyName && p(".mp4") == .emptyName)
        #expect(p("a/b") == .invalidCharacters && p("a:b") == .invalidCharacters && p("a\u{7}b") == .invalidCharacters)
        #expect(p(".secret") == .hiddenName)
        #expect(p(String(repeating: "x", count: 300)) == .tooLong)
        #expect(p(String(repeating: "đ", count: 130)) == .tooLong, "255 bytes, not 255 letters")
        #expect(p("clip") == .sameName && p("clip.mp4") == .sameName)
        #expect(p("Bài giảng 1 – bản đẹp") == nil)
    }

    @Test func renamesWithinTheFolderAndReturnsTheNewPath() throws {
        let f = fs()
        let new = try FileOps.rename("/V/clip.mp4", toTyped: "holiday", fs: f)
        #expect(new == "/V/holiday.mp4" && f.exists("/V/holiday.mp4") && !f.exists("/V/clip.mp4"))
        #expect(f.text("/V/holiday.mp4") == "A", "the same file, with the same content")
    }

    @Test func aNameThatIsTakenIsRefusedAndNothingIsOverwritten() {
        let f = fs()
        #expect(throws: RenameError.exists) { try FileOps.rename("/V/clip.mp4", toTyped: "other", fs: f) }
        #expect(f.text("/V/other.mp4") == "B" && f.text("/V/clip.mp4") == "A")
    }

    @Test func aMissingFileIsReportedNotInvented() {
        #expect(throws: RenameError.sourceMissing) { try FileOps.rename("/V/gone.mp4", toTyped: "x", fs: fs()) }
    }

    @Test func aChangeOfCapitalsOnlyWorksAndLeavesNoTemporaryFile() throws {
        let f = fs()
        let new = try FileOps.rename("/V/clip.mp4", toTyped: "Clip", fs: f)
        #expect(new == "/V/Clip.mp4" && f.exists("/V/Clip.mp4") && !f.exists("/V/clip.mp4"))
        #expect(!f.files.keys.contains { $0.contains(".macplayer-rename") })
    }

    @Test func aFailedMoveIsReportedWithItsReason() {
        let f = fs()
        f.hook = { op, _ in if op == "move" { throw CocoaError(.fileWriteNoPermission) } }
        do { try FileOps.rename("/V/clip.mp4", toTyped: "x", fs: f); Issue.record("should have failed") }
        catch let e as RenameError { if case .failed = e {} else { Issue.record("wrong error \(e)") } }
        catch { Issue.record("wrong error type") }
        #expect(f.exists("/V/clip.mp4"))
    }
}
