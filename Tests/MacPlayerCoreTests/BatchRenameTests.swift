import Foundation
import Testing
@testable import MacPlayerCore

struct BatchRenameTests {
    func fs(_ names: [String] = ["a.mp4", "b.mp4", "c.mov"], in dir: String = "/V") -> FakeFileSystem {
        let f = FakeFileSystem()
        for n in names { f.put(dir + "/" + n, "content of " + n) }
        return f
    }
    func paths(_ names: [String] = ["a.mp4", "b.mp4", "c.mov"], in dir: String = "/V") -> [String] { names.map { dir + "/" + $0 } }
    func rule(_ mode: BatchRenameRule.Mode) -> BatchRenameRule { var r = BatchRenameRule(); r.mode = mode; return r }

    // MARK: The rules

    @Test func numberingFollowsTheListedOrderAndKeepsEachExtension() {
        var r = rule(.numbered); r.baseName = "Trip"; r.digits = 3; r.startNumber = 8
        let plan = BatchRename.plan(paths: paths(), rule: r, fs: fs())
        #expect(plan.map(\.newName) == ["Trip 008.mp4", "Trip 009.mp4", "Trip 010.mov"])
        #expect(plan.allSatisfy { $0.status == .willRename })
    }

    @Test func numberingWithoutABaseNameIsJustNumbers() {
        var r = rule(.numbered); r.digits = 2
        #expect(BatchRename.plan(paths: paths(), rule: r, fs: fs()).map(\.newName) == ["01.mp4", "02.mp4", "03.mov"])
    }

    @Test func findAndReplaceChangesOnlyTheNamesThatHaveTheText() {
        var r = rule(.findReplace); r.find = "IMG"; r.replacement = "Holiday"
        let names = ["IMG_1.jpg", "img_2.jpg", "other.jpg"]
        let plan = BatchRename.plan(paths: paths(names), rule: r, fs: fs(names))
        #expect(plan.map(\.newName) == ["Holiday_1.jpg", "Holiday_2.jpg", "other.jpg"], "case is ignored by default")
        #expect(plan.map(\.status) == [.willRename, .willRename, .unchanged])
        r.ignoreCase = false
        #expect(BatchRename.plan(paths: paths(names), rule: r, fs: fs(names)).map(\.status) == [.willRename, .unchanged, .unchanged])
    }

    @Test func anEmptyFindChangesNothing() {
        let plan = BatchRename.plan(paths: paths(), rule: rule(.findReplace), fs: fs())
        #expect(plan.allSatisfy { $0.status == .unchanged })
    }

    @Test func prefixAndSuffixGoAroundTheNameNotTheExtension() {
        var r = rule(.prefixSuffix); r.prefix = "2024 - "; r.suffix = " (edited)"
        #expect(BatchRename.plan(paths: paths(), rule: r, fs: fs()).map(\.newName) == ["2024 - a (edited).mp4", "2024 - b (edited).mp4", "2024 - c (edited).mov"])
    }

    @Test func vietnameseNamesWork() {
        var r = rule(.numbered); r.baseName = "Chuyến đi Đà Lạt"
        #expect(BatchRename.plan(paths: paths(["a.mp4"]), rule: r, fs: fs(["a.mp4"])).first?.newName == "Chuyến đi Đà Lạt 01.mp4")
    }

    // MARK: What is refused

    @Test func badNamesAreMarkedAndTheBatchIsNotCarriedOut() throws {
        var r = rule(.prefixSuffix); r.prefix = "a/"
        let f = fs()
        let plan = BatchRename.plan(paths: paths(), rule: r, fs: f)
        #expect(plan.allSatisfy { $0.status == .problem(.invalidCharacters) })
        #expect(BatchRename.hasProblem(plan))
        #expect(throws: RenameError.self) { try BatchRename.apply(plan, fs: f) }
        #expect(f.exists("/V/a.mp4") && f.exists("/V/b.mp4"), "nothing was touched")
    }

    @Test func aNameTakenByAFileThatStaysIsRefused() {
        var r = rule(.findReplace); r.find = "x"; r.replacement = ""
        let names = ["ax.mp4", "a.mp4"]       // ax.mp4 would become a.mp4, which a file that is not renamed already has
        let plan = BatchRename.plan(paths: paths(["ax.mp4"]), rule: r, fs: fs(names))
        #expect(plan[0].status == .problem(.exists))
    }

    @Test func twoFilesGettingTheSameNameInOneFolderAreBothRefused() {
        var r = rule(.findReplace); r.find = "x"; r.replacement = ""
        let names = ["aX.mp4", "ax.mp4"]      // both would become a.mp4
        let plan = BatchRename.plan(paths: paths(names), rule: r, fs: fs(names))
        #expect(plan.map(\.status) == [.problem(.exists), .problem(.exists)])
    }

    @Test func differentFoldersMayUseTheSameNewName() throws {
        let f = FakeFileSystem(); f.put("/V/A/a.mp4", "1"); f.put("/V/B/a.mp4", "2")
        var r = rule(.findReplace); r.find = "a"; r.replacement = "z"
        let plan = BatchRename.plan(paths: ["/V/A/a.mp4", "/V/B/a.mp4"], rule: r, fs: f)
        #expect(plan.allSatisfy { $0.status == .willRename })
        _ = try BatchRename.apply(plan, fs: f)
        #expect(f.text("/V/A/z.mp4") == "1" && f.text("/V/B/z.mp4") == "2")
    }

    @Test func aNameAnotherFileAlreadyHasIsRefusedAndNothingIsOverwritten() throws {
        let f = fs(["a.mp4", "b.mp4"])
        var r = rule(.findReplace); r.find = "a"; r.replacement = "b"
        let plan = BatchRename.plan(paths: paths(["a.mp4"]), rule: r, fs: f)
        #expect(plan[0].status == .problem(.exists))
        #expect(throws: RenameError.self) { try BatchRename.apply(plan, fs: f) }
        #expect(f.text("/V/a.mp4") == "content of a.mp4" && f.text("/V/b.mp4") == "content of b.mp4")
    }

    @Test func aFileThatIsMissingIsMarked() {
        let f = fs(["a.mp4"])
        var r = rule(.numbered); r.baseName = "n"
        let plan = BatchRename.plan(paths: ["/V/a.mp4", "/V/gone.mp4"], rule: r, fs: f)
        #expect(plan[1].status == .problem(.sourceMissing))
    }

    @Test func aFileInUseIsLeftOutNotRenamed() throws {
        let f = fs()
        var r = rule(.numbered); r.baseName = "n"
        let plan = BatchRename.plan(paths: paths(), rule: r, blocked: ["/V/b.mp4": "An export is using it"], fs: f)
        #expect(plan[1].status == .blocked("An export is using it"))
        #expect(!BatchRename.hasProblem(plan), "a blocked file does not stop the others")
        _ = try BatchRename.apply(plan, fs: f)
        #expect(f.exists("/V/b.mp4") && f.exists("/V/n 01.mp4") && f.exists("/V/n 03.mov"))
        #expect(!f.exists("/V/a.mp4") && !f.exists("/V/c.mov"))
    }

    // MARK: Doing it

    @Test func aNameAnotherFileInTheSameBatchGivesUpIsAllowed() throws {
        let f = fs(["1.mp4", "2.mp4"])
        var r = rule(.numbered); r.startNumber = 2; r.digits = 1
        let plan = BatchRename.plan(paths: paths(["1.mp4", "2.mp4"]), rule: r, fs: f)
        #expect(plan.map(\.newName) == ["2.mp4", "3.mp4"] && plan.allSatisfy { $0.status == .willRename }, "2.mp4 is taken now but is given up in the same batch")
        let done = try BatchRename.apply(plan, fs: f)
        #expect(done.count == 2)
        #expect(f.text("/V/2.mp4") == "content of 1.mp4" && f.text("/V/3.mp4") == "content of 2.mp4")
        #expect(!f.exists("/V/1.mp4"))
    }

    @Test func swappingTwoNamesWorksToo() throws {
        let f = fs(["a.mp4", "b.mp4"])
        // a -> b and b -> a, built by hand as a plan
        let plan = [BatchRenameEntry(path: "/V/a.mp4", oldName: "a.mp4", newName: "b.mp4", status: .willRename),
                    BatchRenameEntry(path: "/V/b.mp4", oldName: "b.mp4", newName: "a.mp4", status: .willRename)]
        _ = try BatchRename.apply(plan, fs: f)
        #expect(f.text("/V/b.mp4") == "content of a.mp4" && f.text("/V/a.mp4") == "content of b.mp4")
    }

    @Test func ifTheDiskRefusesOneAllTheOthersAreUndone() {
        let f = fs(["a.mp4", "b.mp4", "c.mp4"])
        var r = rule(.numbered); r.baseName = "n"
        let plan = BatchRename.plan(paths: paths(["a.mp4", "b.mp4", "c.mp4"]), rule: r, fs: f)
        f.hook = { op, path in if op == "move" && path.hasSuffix("n 03.mp4") { throw InjectedFailure(op: "refused") } }
        #expect(throws: RenameError.self) { try BatchRename.apply(plan, fs: f) }
        f.hook = nil
        #expect(f.text("/V/a.mp4") == "content of a.mp4" && f.text("/V/b.mp4") == "content of b.mp4" && f.text("/V/c.mp4") == "content of c.mp4", "all three are back")
        #expect(!f.exists("/V/n 01.mp4") && !f.exists("/V/n 02.mp4"))
    }

    @Test func aFailureInTheMiddleOfAShiftPutsEverythingBack() {
        let f = fs(["1.mp4", "2.mp4", "3.mp4"])
        var r = rule(.numbered); r.startNumber = 2; r.digits = 1
        let plan = BatchRename.plan(paths: paths(["1.mp4", "2.mp4", "3.mp4"]), rule: r, fs: f)
        #expect(plan.allSatisfy { $0.status == .willRename })
        var moves = 0
        f.hook = { op, _ in if op == "move" { moves += 1; if moves == 5 { throw InjectedFailure(op: "refused") } } }
        #expect(throws: RenameError.self) { try BatchRename.apply(plan, fs: f) }
        f.hook = nil
        #expect(["1", "2", "3"].allSatisfy { f.text("/V/\($0).mp4") == "content of \($0).mp4" }, "every file has its old name and its own content")
        #expect(f.files.keys.allSatisfy { !PathUtil.fileName(of: $0).hasPrefix(".") }, "no temporary name is left behind")
    }

    @Test func aChangeOfCapitalsOnlyWorks() throws {
        let f = fs(["clip.mp4"])
        var r = rule(.findReplace); r.find = "clip"; r.replacement = "Clip"
        let plan = BatchRename.plan(paths: paths(["clip.mp4"]), rule: r, fs: f)
        #expect(plan[0].status == .willRename)
        _ = try BatchRename.apply(plan, fs: f)
        #expect(f.exists("/V/Clip.mp4") && !f.exists("/V/clip.mp4"))
    }

    @Test func theResultListsEveryOldAndNewPath() throws {
        let f = fs()
        var r = rule(.numbered); r.baseName = "n"
        let done = try BatchRename.apply(BatchRename.plan(paths: paths(), rule: r, fs: f), fs: f)
        #expect(Set(done.map(\.old)) == Set(paths()))
        #expect(Set(done.map(\.new)) == ["/V/n 01.mp4", "/V/n 02.mp4", "/V/n 03.mov"])
    }
}
