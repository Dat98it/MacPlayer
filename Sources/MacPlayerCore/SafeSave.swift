import Foundation

public enum SaveError: Error, Equatable, CustomStringConvertible {
    case sourceMissing(String)
    case sourceNotWritable(String)
    /// The save-as-copy target is the file being read: this must go through the explicit "replace original" flow.
    case destinationIsSource
    case destinationExists(String)
    case destinationFolderMissing(String)
    case destinationFolderNotWritable(String)
    /// Another app changed or replaced the source since it was opened.
    case sourceChanged
    case notEnoughSpace(needed: Int64, available: Int64)
    case extensionWouldChange(from: String, to: String)
    case backupFailed(String)
    case produceFailed(String)
    case verificationFailed(String)
    case cancelled
    /// The swap failed. `restored` says whether the original is back at its path.
    case swapFailed(String, restored: Bool)

    public var description: String {
        switch self {
        case .sourceMissing(let p): return "The original file is gone: \(p)"
        case .sourceNotWritable(let p): return "MacPlayer cannot write to the original: \(p)"
        case .destinationIsSource: return "The destination is the original file. Use “Apply changes to the original” and confirm."
        case .destinationExists(let p): return "A file already exists at \(p). Nothing was overwritten."
        case .destinationFolderMissing(let p): return "The destination folder does not exist: \(p)"
        case .destinationFolderNotWritable(let p): return "MacPlayer cannot write to the folder: \(p)"
        case .sourceChanged: return "The original was changed by another app after it was opened. Nothing was replaced. Save a copy, or reopen the file."
        case .notEnoughSpace(let n, let a): return "Not enough free space: about \(n) bytes needed, \(a) available. Nothing was changed."
        case .extensionWouldChange(let f, let t): return "Replacing the original would change “.\(f)” to “.\(t)”. Save a copy instead."
        case .backupFailed(let m): return "The backup could not be made, so nothing was replaced: \(m)"
        case .produceFailed(let m):
            let body = m.hasPrefix("Export failed: ") ? String(m.dropFirst("Export failed: ".count)) : m
            return "Export failed: \(body)\(body.hasSuffix(".") ? "" : ".") The original is untouched."
        case .verificationFailed(let m): return "The new file did not pass the check (\(m)). The original is untouched."
        case .cancelled: return "Cancelled. The original is untouched."
        case .swapFailed(let m, let restored): return "Replacing failed: \(m). " + (restored ? "The original was restored." : "Recovery will run at next launch.")
        }
    }
}

public struct SaveOutcome: Equatable, Sendable {
    public var finalPath: String
    /// Where the pre-replace copy of the original was kept, if a backup was made.
    public var backupPath: String?
}

/// Replace the original video: what to check and where the safety copy goes.
public struct ReplacePlan: Sendable {
    public var sourcePath: String
    /// Fingerprint taken when the file was opened. A different one at save time stops the replace.
    public var expected: FileFingerprint
    /// Folder for the backup copy. nil = the user switched the backup off (default is on).
    public var backupFolder: String?
    public var newExtension: String

    public init(sourcePath: String, expected: FileFingerprint, backupFolder: String?, newExtension: String) {
        self.sourcePath = sourcePath; self.expected = expected; self.backupFolder = backupFolder; self.newExtension = newExtension
    }
}

/// One in-flight replacement. Written to disk BEFORE anything else happens, and deleted only when the save is
/// finished. It records paths only; recovery decides what to do by looking at which files exist, never by
/// trusting a "state" that a crash may have left one step behind.
struct ReplaceJournal: Codable, Equatable {
    var id: String
    var source: String
    var temp: String
    var aside: String
    var backup: String?
}

public struct RecoveryReport: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case discardedPartialExport
        case restoredOriginal
        case finishedCleanup
        case needsAttention(String)
    }
    public var path: String
    public var action: Action
}

/// Every write of a video goes through here. Rules (design sections 6 and 11):
/// * the output is written to a temp file next to its destination, never onto a file being read;
/// * it is checked before anything is replaced;
/// * the original is only touched by a rename, with a journal so an interrupted swap can be undone;
/// * a copy never overwrites unless told to.
public final class SafeSaver {
    private let fs: FileSystem
    private let journalFolder: String
    private let now: () -> Date
    private let makeID: () -> String

    public init(fs: FileSystem, journalFolder: String, now: @escaping () -> Date = Date.init, makeID: @escaping () -> String = { UUID().uuidString.prefix(8).lowercased().description }) {
        self.fs = fs; self.journalFolder = journalFolder; self.now = now; self.makeID = makeID
    }

    public typealias Produce = (_ tempPath: String) async throws -> Void
    public typealias Verify = (_ tempPath: String) async throws -> Void

    /// Space margin so a nearly-full disk is refused before work starts.
    static let spaceMargin = 1.05

    // MARK: Save as a new copy

    public func saveCopy(sourcePath: String?, destination: String, overwrite: Bool, estimatedBytes: Int64,
                         produce: Produce, verify: Verify) async throws -> SaveOutcome {
        if let s = sourcePath, Self.samePath(s, destination) { throw SaveError.destinationIsSource }
        let dir = PathUtil.directory(of: destination)
        guard fs.isDirectory(dir) else { throw SaveError.destinationFolderMissing(dir) }
        guard fs.isWritable(dir) else { throw SaveError.destinationFolderNotWritable(dir) }
        if fs.exists(destination), !overwrite { throw SaveError.destinationExists(destination) }
        try requireSpace(in: dir, needed: estimatedBytes)

        let temp = tempPath(near: destination)
        do {
            try await run(produce: produce, verify: verify, temp: temp)
        } catch {
            try? fs.remove(temp)
            throw error
        }
        do {
            if fs.exists(destination) {
                // Overwrite was confirmed: park the old file, move the new one in, then drop the old one.
                let aside = tempPath(near: destination, tag: "old")
                try fs.move(from: destination, to: aside)
                do { try fs.move(from: temp, to: destination) } catch {
                    try? fs.move(from: aside, to: destination)
                    try? fs.remove(temp)
                    throw SaveError.swapFailed("\(error)", restored: fs.exists(destination))
                }
                try? fs.remove(aside)
            } else {
                try fs.move(from: temp, to: destination)
            }
        } catch let e as SaveError {
            throw e
        } catch {
            try? fs.remove(temp)
            throw SaveError.swapFailed("\(error)", restored: true)
        }
        return SaveOutcome(finalPath: destination, backupPath: nil)
    }

    // MARK: Apply changes to the original

    public func replaceOriginal(plan: ReplacePlan, estimatedBytes: Int64, produce: Produce, verify: Verify) async throws -> SaveOutcome {
        let source = plan.sourcePath
        guard fs.exists(source) else { throw SaveError.sourceMissing(source) }
        let dir = PathUtil.directory(of: source)
        guard fs.isWritable(source), fs.isWritable(dir) else { throw SaveError.sourceNotWritable(source) }
        let oldExt = PathUtil.ext(of: source).lowercased(), newExt = plan.newExtension.lowercased()
        guard oldExt == newExt else { throw SaveError.extensionWouldChange(from: oldExt, to: newExt) }
        guard try fs.fingerprint(source) == plan.expected else { throw SaveError.sourceChanged }

        let sourceSize = plan.expected.size
        // Temp output + (backup, when it lands on the same volume) must fit at the same time.
        try requireSpace(in: dir, needed: estimatedBytes + (plan.backupFolder == nil ? 0 : sourceSize))

        // 0. Journal first: from here on, a crash at any point can be undone at next launch.
        let id = makeID()
        let temp = tempPath(near: source, id: id)
        let aside = tempPath(near: source, tag: "old", id: id)
        var plannedBackup: String?
        if let folder = plan.backupFolder {
            plannedBackup = uniquePath(PathUtil.join(folder, "\(PathUtil.stem(of: source)).original-\(Self.stamp(now())).\(oldExt)"))
        }
        let journal = ReplaceJournal(id: id, source: source, temp: temp, aside: aside, backup: plannedBackup)
        do { try writeJournal(journal) } catch { throw SaveError.produceFailed("could not write the recovery journal: \(error)") }

        /// Undo everything this attempt made, for failures we know about (a crash is left to `recoverInterrupted`).
        func abort(removeBackup: Bool) {
            try? fs.remove(temp)
            if removeBackup, let b = plannedBackup { try? fs.remove(b) }
            removeJournal(journal)
        }

        // 1. Backup. If it cannot be made, stop: nothing has been touched.
        var backupPath: String?
        if let folder = plan.backupFolder, let dest = plannedBackup {
            do {
                if !fs.exists(folder) { try fs.createDirectory(folder) }
                try fs.copy(from: source, to: dest)
                guard try fs.fingerprint(dest).size == sourceSize else { throw SaveError.backupFailed("the copy has a different size") }
                backupPath = dest
            } catch {
                abort(removeBackup: true)
                throw error as? SaveError ?? SaveError.backupFailed("\(error)")
            }
        }

        // 2. Produce and check the new file next to the original.
        do {
            try await run(produce: produce, verify: verify, temp: temp)
        } catch {
            abort(removeBackup: true)
            throw error
        }

        // 3. Another app may have touched the original while we were exporting.
        do {
            guard try fs.fingerprint(source) == plan.expected else { throw SaveError.sourceChanged }
        } catch {
            abort(removeBackup: true)
            throw error as? SaveError ?? SaveError.sourceMissing(source)
        }

        // 4. The swap: two renames.
        do {
            try fs.move(from: source, to: aside)
        } catch {
            abort(removeBackup: true)
            throw SaveError.swapFailed("\(error)", restored: fs.exists(source))
        }
        do {
            try fs.move(from: temp, to: source)
        } catch {
            // Put the original back. If that fails too, the journal stays for recovery at next launch.
            if (try? fs.move(from: aside, to: source)) != nil {
                abort(removeBackup: true)
                throw SaveError.swapFailed("\(error)", restored: true)
            }
            throw SaveError.swapFailed("\(error)", restored: false)
        }
        try? fs.remove(aside)
        removeJournal(journal)
        return SaveOutcome(finalPath: source, backupPath: backupPath)
    }

    // MARK: Recovery after a crash or power loss

    /// Run at launch. Undoes or finishes any replace that was interrupted. The original is never left missing.
    /// Decides from which files exist (the journal only names them):
    /// * source gone, aside present      -> the swap was cut in half: put the original back;
    /// * source and aside both present   -> the swap finished: drop the aside;
    /// * source present, no aside        -> the swap never started: drop the unfinished temp.
    /// A backup is never deleted here: it is harmless if unused and precious if the save had completed.
    @discardableResult
    public func recoverInterrupted() -> [RecoveryReport] {
        guard let entries = try? fs.contents(ofDirectory: journalFolder) else { return [] }
        var reports: [RecoveryReport] = []
        for e in entries where e.name.hasSuffix(".journal.json") {
            let path = PathUtil.join(journalFolder, e.name)
            guard let data = try? fs.read(path), let j = try? JSONDecoder().decode(ReplaceJournal.self, from: data) else {
                reports.append(RecoveryReport(path: path, action: .needsAttention("unreadable journal"))); continue
            }
            let hasSource = fs.exists(j.source), hasAside = fs.exists(j.aside), hasTemp = fs.exists(j.temp)
            switch (hasSource, hasAside) {
            case (false, true):
                if (try? fs.move(from: j.aside, to: j.source)) != nil {
                    try? fs.remove(j.temp); try? fs.remove(path)
                    reports.append(RecoveryReport(path: j.source, action: .restoredOriginal))
                } else {
                    reports.append(RecoveryReport(path: j.source, action: .needsAttention("could not move \(j.aside) back to \(j.source)")))
                }
            case (true, true):
                try? fs.remove(j.aside); try? fs.remove(j.temp); try? fs.remove(path)
                reports.append(RecoveryReport(path: j.source, action: .finishedCleanup))
            case (true, false):
                try? fs.remove(j.temp); try? fs.remove(path)
                reports.append(RecoveryReport(path: j.source, action: hasTemp ? .discardedPartialExport : .finishedCleanup))
            case (false, false):
                var hint = "the original is missing"
                if hasTemp { hint += "; the new export is at \(j.temp)" }
                if let b = j.backup, fs.exists(b) { hint += "; a backup is at \(b)" }
                reports.append(RecoveryReport(path: j.source, action: .needsAttention(hint)))
            }
        }
        return reports
    }

    /// Hidden partial files that a crash left next to a "save as copy" destination. Safe to delete: nothing
    /// refers to them. Only names MacPlayer itself makes are touched.
    @discardableResult
    public func cleanStalePartials(inFolder folder: String) -> [String] {
        guard let entries = try? fs.contents(ofDirectory: folder) else { return [] }
        var removed: [String] = []
        for e in entries where !e.isDirectory && e.name.hasPrefix(".") && (e.name.contains(".macplayer-partial-") || e.name.contains(".macvideo-partial-")) {
            let p = PathUtil.join(folder, e.name)
            if (try? fs.remove(p)) != nil { removed.append(p) }
        }
        return removed
    }

    // MARK: Helpers

    private func run(produce: Produce, verify: Verify, temp: String) async throws {
        do { try await produce(temp) }
        catch is CancellationError { throw SaveError.cancelled }
        catch let e as SaveError { throw e }
        catch { if Task.isCancelled { throw SaveError.cancelled }; throw SaveError.produceFailed("\(error)") }
        if Task.isCancelled { throw SaveError.cancelled }
        guard fs.exists(temp) else { throw SaveError.verificationFailed("no output file was written") }
        do { try await verify(temp) }
        catch let e as SaveError { throw e }
        catch { throw SaveError.verificationFailed("\(error)") }
    }

    private func requireSpace(in dir: String, needed: Int64) throws {
        guard needed > 0, let avail = try? fs.freeSpace(atPath: dir) else { return }
        let required = Int64(Double(needed) * Self.spaceMargin)
        if avail < required { throw SaveError.notEnoughSpace(needed: required, available: avail) }
    }

    func tempPath(near path: String, tag: String = "partial", id: String? = nil) -> String {
        let dir = PathUtil.directory(of: path), stem = PathUtil.stem(of: path), ext = PathUtil.ext(of: path)
        let name = ".\(stem).macplayer-\(tag)-\(id ?? makeID())" + (ext.isEmpty ? "" : ".\(ext)")
        return PathUtil.join(dir, name)
    }

    private func uniquePath(_ path: String) -> String {
        guard fs.exists(path) else { return path }
        let dir = PathUtil.directory(of: path), stem = PathUtil.stem(of: path), ext = PathUtil.ext(of: path)
        var n = 2
        while true {
            let p = PathUtil.join(dir, "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !fs.exists(p) { return p }
            n += 1
        }
    }

    private func journalPath(_ j: ReplaceJournal) -> String { PathUtil.join(journalFolder, "\(j.id).journal.json") }

    private func writeJournal(_ j: ReplaceJournal) throws {
        if !fs.exists(journalFolder) { try fs.createDirectory(journalFolder) }
        try fs.writeAtomically(try JSONEncoder().encode(j), to: journalPath(j))
    }

    private func removeJournal(_ j: ReplaceJournal) { try? fs.remove(journalPath(j)) }

    static func samePath(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }
}
