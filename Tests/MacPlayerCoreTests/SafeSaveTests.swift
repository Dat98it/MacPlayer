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

/// MacPlayer no longer replaces originals, but a replace that MacPlayer 0.7 left half done must still be put right after an update.
@Suite struct LegacyReplaceRecoveryTests {
    @Test func recoveryRestoresWhenSourceWasMovedAside() throws {
        let fs = FakeFileSystem()
        fs.directories.insert("/Videos")
        fs.put("/Videos/.talk.macplayer-old-x.mp4", "OLD")
        fs.put("/Videos/.talk.macplayer-partial-y.mp4", "HALF")
        let j = LegacyReplaceJournal(id: "x", source: src, temp: "/Videos/.talk.macplayer-partial-y.mp4", aside: "/Videos/.talk.macplayer-old-x.mp4", backup: nil)
        try fs.writeAtomically(JSONEncoder().encode(j), to: "\(journals)/x.journal.json")
        fs.directories.insert(journals)
        let reports = makeSaver(fs).recoverLegacyReplaceJournals()
        #expect(reports.map(\.action) == [.restoredOriginal])
        #expect(fs.text(src) == "OLD")
        #expect(fs.leftovers.isEmpty)
    }

    @Test func recoveryReportsWhenNothingCanBeRestored() throws {
        let fs = FakeFileSystem()
        fs.directories.insert("/Videos")
        fs.put("/Videos/Backups/talk.original-1.mp4", "OLD")
        let j = LegacyReplaceJournal(id: "z", source: src, temp: "/Videos/t", aside: "/Videos/a", backup: "/Videos/Backups/talk.original-1.mp4")
        fs.directories.insert(journals)
        try fs.writeAtomically(JSONEncoder().encode(j), to: "\(journals)/z.journal.json")
        let reports = makeSaver(fs).recoverLegacyReplaceJournals()
        guard case .needsAttention(let m) = reports.first?.action else { Issue.record("expected needsAttention"); return }
        #expect(m.contains("backup"))
    }

    @Test func aFinishedSwapIsOnlyCleanedUp() throws {
        let fs = setup()
        fs.put("/Videos/.talk.macplayer-old-x.mp4", "OLD")
        let j = LegacyReplaceJournal(id: "x", source: src, temp: "/Videos/.talk.macplayer-partial-x.mp4", aside: "/Videos/.talk.macplayer-old-x.mp4", backup: nil)
        fs.directories.insert(journals)
        try fs.writeAtomically(JSONEncoder().encode(j), to: "\(journals)/x.journal.json")
        #expect(makeSaver(fs).recoverLegacyReplaceJournals().map(\.action) == [.finishedCleanup])
        #expect(fs.text(src) == "OLD" && fs.leftovers.isEmpty && !fs.exists("\(journals)/x.journal.json"))
    }

    @Test func aSwapThatNeverStartedDropsItsPartialFile() throws {
        let fs = setup()
        fs.put("/Videos/.talk.macplayer-partial-y.mp4", "HALF")
        let j = LegacyReplaceJournal(id: "y", source: src, temp: "/Videos/.talk.macplayer-partial-y.mp4", aside: "/Videos/.talk.macplayer-old-y.mp4", backup: nil)
        fs.directories.insert(journals)
        try fs.writeAtomically(JSONEncoder().encode(j), to: "\(journals)/y.journal.json")
        #expect(makeSaver(fs).recoverLegacyReplaceJournals().map(\.action) == [.discardedPartialExport])
        #expect(fs.text(src) == "OLD" && fs.leftovers.isEmpty)
    }
}
