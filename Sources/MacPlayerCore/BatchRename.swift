import Foundation

/// How several files are given new names at once. Every rule works on the name without its extension, which each file keeps.
public struct BatchRenameRule: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        /// "Trip 01", "Trip 02", … in the order the files are listed.
        case numbered
        /// Replace some text in each name.
        case findReplace
        /// Put text before and/or after each name.
        case prefixSuffix
    }

    public var mode: Mode = .numbered
    // numbered
    public var baseName = ""
    public var startNumber = 1
    /// At least this many digits: 3 gives 001, 002 … (1...9).
    public var digits = 2
    public var separator = " "
    // find and replace
    public var find = ""
    public var replacement = ""
    public var ignoreCase = true
    // prefix and suffix
    public var prefix = ""
    public var suffix = ""

    public init() {}

    /// The new name (without extension) for the file in position `index` of the list. A rule that has nothing to do (no text to find)
    /// gives the old name back.
    public func newStem(from stem: String, index: Int) -> String {
        switch mode {
        case .numbered:
            let n = String(max(0, startNumber + index))
            let number = String(repeating: "0", count: max(0, min(9, digits) - n.count)) + n
            return baseName.isEmpty ? number : baseName + separator + number
        case .findReplace:
            guard !find.isEmpty else { return stem }
            return stem.replacingOccurrences(of: find, with: replacement, options: ignoreCase ? [.caseInsensitive] : [])
        case .prefixSuffix:
            return prefix + stem + suffix
        }
    }
}

public struct BatchRenameEntry: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Will get `newName`.
        case willRename
        /// Already has that name.
        case unchanged
        /// Left out: the file is in use (an export, a video with unsaved edits). The text says why.
        case blocked(String)
        /// The new name cannot be used (see `RenameError`); a batch with one of these is not carried out.
        case problem(RenameError)
    }

    public var path: String
    public var oldName: String
    /// The whole new file name, extension included.
    public var newName: String
    public var status: Status
    public var id: String { path }

    public var newPath: String { PathUtil.join(PathUtil.directory(of: path), newName) }
}

public enum BatchRename {
    private static func key(_ path: String) -> String { (path as NSString).standardizingPath.lowercased() }

    /// What each file would be called, and whether that works. `paths` is in the order the files are listed (numbering follows it).
    /// Two files that would get the same name in one folder are both refused, and so is a name another file already has, except a name that
    /// file gives up in this same batch (so "1 → 2, 2 → 3" is fine).
    public static func plan(paths: [String], rule: BatchRenameRule, blocked: [String: String] = [:], fs: FileSystem) -> [BatchRenameEntry] {
        var entries: [BatchRenameEntry] = []
        for (index, path) in paths.enumerated() {
            let old = PathUtil.fileName(of: path)
            let typed = rule.newStem(from: PathUtil.stem(of: path), index: index)
            let new = FileOps.newFileName(forTyped: typed, oldPath: path)
            var status: BatchRenameEntry.Status = .willRename
            if let why = blocked[path] { status = .blocked(why) }
            else if !fs.exists(path) { status = .problem(.sourceMissing) }
            else if let problem = FileOps.problem(withTyped: typed, oldPath: path) { status = problem == .sameName ? .unchanged : .problem(problem) }
            entries.append(BatchRenameEntry(path: path, oldName: old, newName: new, status: status))
        }
        // Names taken twice inside the batch, or by a file that stays. Marking one entry can make another's old name stay put, so repeat.
        var changed = true
        while changed {
            changed = false
            var leaving = Set<String>()
            var wanted: [String: Int] = [:]
            for e in entries where e.status == .willRename { leaving.insert(key(e.path)); wanted[key(e.newPath), default: 0] += 1 }
            for i in entries.indices where entries[i].status == .willRename {
                let target = key(entries[i].newPath)
                let clash = (wanted[target] ?? 0) > 1 || (fs.exists(entries[i].newPath) && target != key(entries[i].path) && !leaving.contains(target))
                if clash { entries[i].status = .problem(.exists); changed = true }
            }
        }
        return entries
    }

    public static func hasProblem(_ plan: [BatchRenameEntry]) -> Bool {
        plan.contains { if case .problem = $0.status { return true } else { return false } }
    }

    public struct Renamed: Equatable, Sendable { public var old: String; public var new: String }

    /// Renames the files that `plan` says will be renamed. All or nothing: if the disk refuses one, the ones already done are put back.
    /// Nothing is overwritten. A file whose new name is still taken at that moment (another file gives it up later in the batch, or only
    /// the capital letters change) goes through a temporary name, so shifting names around works.
    public static func apply(_ plan: [BatchRenameEntry], fs: FileSystem) throws -> [Renamed] {
        guard !hasProblem(plan) else { throw RenameError.exists }
        var log: [(from: String, to: String)] = []
        func move(_ a: String, _ b: String) throws { try fs.move(from: a, to: b); log.append((a, b)) }
        var done: [Renamed] = []
        do {
            var pending: [(temp: String, dest: String, entry: BatchRenameEntry)] = []
            for e in plan where e.status == .willRename {
                let dest = e.newPath
                guard fs.exists(e.path) else { throw RenameError.sourceMissing }
                if fs.exists(dest) || key(dest) == key(e.path) {
                    let temp = PathUtil.join(PathUtil.directory(of: e.path), ".\(UUID().uuidString.prefix(8)).macplayer-rename")
                    try move(e.path, temp)
                    pending.append((temp, dest, e))
                } else {
                    try move(e.path, dest)
                    done.append(Renamed(old: e.path, new: dest))
                }
            }
            for p in pending {
                try move(p.temp, p.dest)
                done.append(Renamed(old: p.entry.path, new: p.dest))
            }
        } catch {
            for step in log.reversed() { try? fs.move(from: step.to, to: step.from) }
            if let e = error as? RenameError { throw e }
            throw RenameError.failed(error.localizedDescription)
        }
        return done
    }
}
