import Foundation
import Testing
@testable import MacPlayerCore

private let src = "/Videos/talk.mp4"
private let journals = "/Support/journals"

private func makeSaver(_ fs: FakeFileSystem) -> SafeSaver {
    var n = 0
    return SafeSaver(fs: fs, journalFolder: journals, now: { Date(timeIntervalSince1970: 1_700_000_000) },
                     makeID: { n += 1; return "id\(n)" })
}

private func produceNew(_ fs: FakeFileSystem, _ content: String = "NEW") -> SafeSaver.Produce {
    { temp in fs.put(temp, content) }
}
private let verifyOK: SafeSaver.Verify = { _ in }

private func plan(_ fs: FakeFileSystem, backup: String? = "/Videos/Backups", ext: String = "mp4") throws -> ReplacePlan {
    ReplacePlan(sourcePath: src, expected: try fs.fingerprint(src), backupFolder: backup, newExtension: ext)
}

private func setup() -> FakeFileSystem {
    let fs = FakeFileSystem()
    fs.put(src, "OLD")
    fs.directories.insert("/Videos")
    return fs
}

@Suite struct SaveCopyTests {
    @Test func copyKeepsOriginalAndCreatesNewFile() async throws {
        let fs = setup()
        let out = try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/talk-edited.mp4", overwrite: false,
                                                   estimatedBytes: 100, produce: produceNew(fs), verify: verifyOK)
        #expect(out.finalPath == "/Videos/talk-edited.mp4")
        #expect(fs.text(src) == "OLD")
        #expect(fs.text("/Videos/talk-edited.mp4") == "NEW")
        #expect(fs.leftovers.isEmpty)
    }

    @Test func destinationEqualToSourceIsRefused() async throws {
        let fs = setup()
        var produced = false
        await #expect(throws: SaveError.destinationIsSource) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/../Videos/talk.mp4", overwrite: true, estimatedBytes: 1,
                                             produce: { _ in produced = true }, verify: verifyOK)
        }
        #expect(!produced)
        #expect(fs.text(src) == "OLD")
    }

    @Test func existingDestinationIsNotOverwrittenWithoutConfirmation() async throws {
        let fs = setup()
        fs.put("/Videos/out.mp4", "PRECIOUS")
        await #expect(throws: SaveError.destinationExists("/Videos/out.mp4")) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/out.mp4", overwrite: false, estimatedBytes: 1,
                                             produce: produceNew(fs), verify: verifyOK)
        }
        #expect(fs.text("/Videos/out.mp4") == "PRECIOUS")
    }

    @Test func confirmedOverwriteReplacesAtomically() async throws {
        let fs = setup()
        fs.put("/Videos/out.mp4", "OLDOUT")
        _ = try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/out.mp4", overwrite: true, estimatedBytes: 1,
                                             produce: produceNew(fs), verify: verifyOK)
        #expect(fs.text("/Videos/out.mp4") == "NEW")
        #expect(fs.leftovers.isEmpty)
    }

    @Test func notEnoughSpaceStopsBeforeAnyWork() async throws {
        let fs = setup()
        fs.free = 50
        var produced = false
        await #expect(throws: (any Error).self) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/o.mp4", overwrite: false, estimatedBytes: 1000,
                                             produce: { _ in produced = true }, verify: verifyOK)
        }
        #expect(!produced)
        #expect(fs.leftovers.isEmpty)
    }

    @Test func failedExportLeavesNoPartialFile() async throws {
        let fs = setup()
        struct Boom: Error {}
        await #expect(throws: (any Error).self) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/o.mp4", overwrite: false, estimatedBytes: 1,
                                             produce: { temp in fs.put(temp, "HALF"); throw Boom() }, verify: verifyOK)
        }
        #expect(!fs.exists("/Videos/o.mp4"))
        #expect(fs.leftovers.isEmpty)
    }

    @Test func cancelledExportLeavesNothing() async throws {
        let fs = setup()
        await #expect(throws: SaveError.cancelled) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/o.mp4", overwrite: false, estimatedBytes: 1,
                                             produce: { temp in fs.put(temp, "HALF"); throw CancellationError() }, verify: verifyOK)
        }
        #expect(fs.leftovers.isEmpty && !fs.exists("/Videos/o.mp4"))
    }

    @Test func failedVerificationDiscardsOutput() async throws {
        let fs = setup()
        await #expect(throws: (any Error).self) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/o.mp4", overwrite: false, estimatedBytes: 1,
                                             produce: produceNew(fs), verify: { _ in throw SaveError.verificationFailed("unreadable") })
        }
        #expect(!fs.exists("/Videos/o.mp4") && fs.leftovers.isEmpty)
    }

    @Test func missingOrReadOnlyFolderIsReported() async throws {
        let fs = setup()
        await #expect(throws: SaveError.destinationFolderMissing("/Nope")) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Nope/o.mp4", overwrite: false, estimatedBytes: 1, produce: produceNew(fs), verify: verifyOK)
        }
        fs.unwritable.insert("/Videos")
        await #expect(throws: SaveError.destinationFolderNotWritable("/Videos")) {
            try await makeSaver(fs).saveCopy(sourcePath: src, destination: "/Videos/o.mp4", overwrite: false, estimatedBytes: 1, produce: produceNew(fs), verify: verifyOK)
        }
    }
}

@Suite struct ReplaceOriginalTests {
    @Test func replaceSwapsContentAndKeepsBackup() async throws {
        let fs = setup()
        let out = try await makeSaver(fs).replaceOriginal(plan: plan(fs), estimatedBytes: 10, produce: produceNew(fs), verify: verifyOK)
        #expect(fs.text(src) == "NEW")
        let backup = try #require(out.backupPath)
        #expect(fs.text(backup) == "OLD")
        #expect(backup.hasPrefix("/Videos/Backups/talk.original-"))
        #expect(fs.leftovers.isEmpty)
        #expect(try fs.contents(ofDirectory: journals).isEmpty)
    }

    @Test func replaceWithoutBackupWhenSwitchedOff() async throws {
        let fs = setup()
        let out = try await makeSaver(fs).replaceOriginal(plan: plan(fs, backup: nil), estimatedBytes: 10, produce: produceNew(fs), verify: verifyOK)
        #expect(out.backupPath == nil)
        #expect(fs.text(src) == "NEW")
        #expect(fs.leftovers.isEmpty)
    }

    @Test func changedBeforeStartIsRefusedWithoutWork() async throws {
        let fs = setup()
        let p = try plan(fs)
        fs.touchExternally(src, "EDITED BY OTHER APP")
        var produced = false
        await #expect(throws: SaveError.sourceChanged) {
            try await makeSaver(fs).replaceOriginal(plan: p, estimatedBytes: 1, produce: { _ in produced = true }, verify: verifyOK)
        }
        #expect(!produced)
        #expect(fs.text(src) == "EDITED BY OTHER APP")
        #expect(!fs.exists("/Videos/Backups"))
    }

    @Test func changedDuringExportKeepsTheOtherAppsVersion() async throws {
        let fs = setup()
        let p = try plan(fs)
        await #expect(throws: SaveError.sourceChanged) {
            try await makeSaver(fs).replaceOriginal(plan: p, estimatedBytes: 1,
                produce: { temp in fs.put(temp, "NEW"); fs.touchExternally(src, "EDITED WHILE EXPORTING") }, verify: verifyOK)
        }
        #expect(fs.text(src) == "EDITED WHILE EXPORTING")
        #expect(fs.leftovers.isEmpty)
        #expect(fs.files.keys.filter { $0.hasPrefix("/Videos/Backups/") }.isEmpty)
    }

    @Test func extensionChangeIsRefused() async throws {
        let fs = setup()
        await #expect(throws: SaveError.extensionWouldChange(from: "mp4", to: "mov")) {
            try await makeSaver(fs).replaceOriginal(plan: plan(fs, ext: "mov"), estimatedBytes: 1, produce: produceNew(fs), verify: verifyOK)
        }
        #expect(fs.text(src) == "OLD")
    }

    @Test func backupFailureStopsEverything() async throws {
        let fs = setup()
        fs.hook = { op, _ in if op == "copy" { throw InjectedFailure(op: "copy") } }
        var produced = false
        await #expect(throws: (any Error).self) {
            try await makeSaver(fs).replaceOriginal(plan: plan(fs), estimatedBytes: 1, produce: { _ in produced = true }, verify: verifyOK)
        }
        #expect(!produced)
        #expect(fs.text(src) == "OLD")
    }

    @Test func notEnoughSpaceForBackupAndOutput() async throws {
        let fs = setup()
        fs.free = 5
        await #expect(throws: (any Error).self) {
            try await makeSaver(fs).replaceOriginal(plan: plan(fs), estimatedBytes: 1000, produce: produceNew(fs), verify: verifyOK)
        }
        #expect(fs.text(src) == "OLD" && fs.leftovers.isEmpty)
    }

    @Test func failedOrCancelledExportKeepsOriginalAndLeavesNoBackupClutter() async throws {
        for failure in [CancellationError() as Error, InjectedFailure(op: "encode")] {
            let fs = setup()
            await #expect(throws: (any Error).self) {
                try await makeSaver(fs).replaceOriginal(plan: plan(fs), estimatedBytes: 1,
                    produce: { temp in fs.put(temp, "HALF"); throw failure }, verify: verifyOK)
            }
            #expect(fs.text(src) == "OLD")
            #expect(fs.leftovers.isEmpty)
            #expect(fs.files.keys.filter { $0.hasPrefix("/Videos/Backups/") }.isEmpty)
        }
    }

    @Test func failedVerificationKeepsOriginal() async throws {
        let fs = setup()
        await #expect(throws: (any Error).self) {
            try await makeSaver(fs).replaceOriginal(plan: plan(fs), estimatedBytes: 1, produce: produceNew(fs),
                                                    verify: { _ in throw SaveError.verificationFailed("duration is 0") })
        }
        #expect(fs.text(src) == "OLD" && fs.leftovers.isEmpty)
    }

    @Test func secondRenameFailingRestoresOriginal() async throws {
        let fs = setup()
        var moves = 0
        fs.hook = { op, _ in if op == "move" { moves += 1; if moves == 2 { throw InjectedFailure(op: "move2") } } }
        await #expect(throws: SaveError.self) {
            try await makeSaver(fs).replaceOriginal(plan: plan(fs), estimatedBytes: 1, produce: produceNew(fs), verify: verifyOK)
        }
        #expect(fs.text(src) == "OLD")
        #expect(fs.leftovers.isEmpty)
    }

    /// The core guarantee: whatever step the machine dies at, after recovery the path holds the old or the new
    /// video, never nothing, and the pre-replace copy exists whenever the new video is in place.
    @Test func interruptionAtEveryStepNeverLosesTheVideo() async throws {
        var step = 0
        var sawSwapped = false, sawOriginal = false
        while step < 40 {
            let fs = setup()
            let p = try plan(fs)
            fs.crashAfter = step
            var finished = false
            do {
                _ = try await makeSaver(fs).replaceOriginal(plan: p, estimatedBytes: 10, produce: produceNew(fs), verify: verifyOK)
                finished = true
            } catch {}
            fs.reboot()
            makeSaver(fs).recoverInterrupted()

            let now = try #require(fs.text(src), "video missing after crash at step \(step)")
            #expect(now == "OLD" || now == "NEW", "unexpected content at step \(step)")
            if now == "NEW" {
                sawSwapped = true
                let backups = fs.files.filter { $0.key.hasPrefix("/Videos/Backups/") }
                #expect(backups.values.contains { String(decoding: $0.data, as: UTF8.self) == "OLD" }, "no backup of the old video at step \(step)")
            } else { sawOriginal = true }
            #expect(fs.leftovers.isEmpty, "temp files left at step \(step): \(fs.leftovers)")
            if finished { break }
            step += 1
        }
        #expect(step < 40, "the save never finished")
        #expect(sawSwapped && sawOriginal, "crash points should cover both outcomes")
    }

    @Test func recoveryRestoresWhenSourceWasMovedAside() throws {
        let fs = FakeFileSystem()
        fs.directories.insert("/Videos")
        fs.put("/Videos/.talk.macplayer-old-x.mp4", "OLD")
        fs.put("/Videos/.talk.macplayer-partial-y.mp4", "HALF")
        let j = ReplaceJournal(id: "x", source: src, temp: "/Videos/.talk.macplayer-partial-y.mp4", aside: "/Videos/.talk.macplayer-old-x.mp4", backup: nil)
        try fs.writeAtomically(JSONEncoder().encode(j), to: "\(journals)/x.journal.json")
        fs.directories.insert(journals)
        let reports = makeSaver(fs).recoverInterrupted()
        #expect(reports.map(\.action) == [.restoredOriginal])
        #expect(fs.text(src) == "OLD")
        #expect(fs.leftovers.isEmpty)
    }

    @Test func recoveryReportsWhenNothingCanBeRestored() throws {
        let fs = FakeFileSystem()
        fs.directories.insert("/Videos")
        fs.put("/Videos/Backups/talk.original-1.mp4", "OLD")
        let j = ReplaceJournal(id: "z", source: src, temp: "/Videos/t", aside: "/Videos/a", backup: "/Videos/Backups/talk.original-1.mp4")
        fs.directories.insert(journals)
        try fs.writeAtomically(JSONEncoder().encode(j), to: "\(journals)/z.journal.json")
        let reports = makeSaver(fs).recoverInterrupted()
        guard case .needsAttention(let m) = reports.first?.action else { Issue.record("expected needsAttention"); return }
        #expect(m.contains("backup"))
    }
}
