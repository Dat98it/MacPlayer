import Foundation

public enum SaveError: Error, Equatable, CustomStringConvertible {
    /// The target is the file being read. MacPlayer never writes over an original.
    case destinationIsSource
    case destinationExists(String)
    case destinationFolderMissing(String)
    case destinationFolderNotWritable(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case produceFailed(String)
    case verificationFailed(String)
    case cancelled
    /// Moving the finished file into place failed. `restored` says whether a file that was there before is back.
    case swapFailed(String, restored: Bool)

    public var description: String {
        switch self {
        case .destinationIsSource: return "The destination is the original file. MacPlayer never writes over an original; choose another name."
        case .destinationExists(let p): return "A file already exists at \(p). Nothing was overwritten."
        case .destinationFolderMissing(let p): return "The destination folder does not exist: \(p)"
        case .destinationFolderNotWritable(let p): return "MacPlayer cannot write to the folder: \(p)"
        case .notEnoughSpace(let n, let a): return "Not enough free space: about \(n) bytes needed, \(a) available. Nothing was changed."
        case .produceFailed(let m):
            let body = m.hasPrefix("Export failed: ") ? String(m.dropFirst("Export failed: ".count)) : m
            return "Export failed: \(body)\(body.hasSuffix(".") ? "" : ".") The original is untouched."
        case .verificationFailed(let m): return "The new file did not pass the check (\(m)). The original is untouched."
        case .cancelled: return "Cancelled. The original is untouched."
        case .swapFailed(let m, let restored): return "Saving failed: \(m). " + (restored ? "Nothing was changed." : "Check the destination folder.")
        }
    }
}

public struct SaveOutcome: Equatable, Sendable {
    public var finalPath: String
    public init(finalPath: String) { self.finalPath = finalPath }
}

/// A "replace the original" that MacPlayer 0.7 or older started and never finished (the app was stopped half way).
/// MacPlayer no longer replaces originals, but such a journal may still be on disk after an update: it is read once at
/// launch so the original is put back where it belongs. Nothing in the app writes these any more.
struct LegacyReplaceJournal: Codable, Equatable {
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

/// Every write of a video or photo goes through here. Rules:
/// * MacPlayer never modifies, overwrites or replaces an original: every result is a NEW file;
/// * the output is written to a temp file next to its destination, never onto a file being read;
/// * it is checked before it is moved into place;
/// * a copy never overwrites unless told to (and never the source).
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
        return SaveOutcome(finalPath: destination)
    }

    // MARK: Recovery after a crash or power loss

    /// Run at launch. Undoes or finishes a "replace the original" that MacPlayer 0.7 or older left half done, so the original is
    /// never left missing after an update. Decides from which files exist (the journal only names them):
    /// * source gone, aside present      -> the swap was cut in half: put the original back;
    /// * source and aside both present   -> the swap finished: drop the aside;
    /// * source present, no aside        -> the swap never started: drop the unfinished temp.
    /// A backup is never deleted here: it is harmless if unused and precious if the save had completed.
    @discardableResult
    public func recoverLegacyReplaceJournals() -> [RecoveryReport] {
        guard let entries = try? fs.contents(ofDirectory: journalFolder) else { return [] }
        var reports: [RecoveryReport] = []
        for e in entries where e.name.hasSuffix(".journal.json") {
            let path = PathUtil.join(journalFolder, e.name)
            guard let data = try? fs.read(path), let j = try? JSONDecoder().decode(LegacyReplaceJournal.self, from: data) else {
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

    static func samePath(_ a: String, _ b: String) -> Bool {
        PathUtil.same(a, b)
    }
}
