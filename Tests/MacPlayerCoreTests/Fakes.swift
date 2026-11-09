import Foundation
@testable import MacPlayerCore

struct InjectedFailure: Error, Equatable { var op: String }

/// In-memory file system. Can fail a chosen operation, or "crash": after the crash point every change throws,
/// like a process that has died, so clean-up code that would not have run in real life does not run here either.
final class FakeFileSystem: FileSystem {
    struct File { var data: Data; var modified: Date; var id: UInt64 }
    var files: [String: File] = [:]
    var directories: Set<String> = ["/"]
    var unwritable: Set<String> = []
    var free: Int64 = 1_000_000_000
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var nextID: UInt64 = 1

    /// Called before every change; throw to fail it. Receives operation name and the main path.
    var hook: ((String, String) throws -> Void)?
    /// Number of changing operations so far (for "crash at step N" loops).
    private(set) var changeCount = 0
    var crashAfter: Int?
    private(set) var crashed = false

    private func change(_ op: String, _ path: String) throws {
        if crashed { throw InjectedFailure(op: "dead:\(op)") }
        if let n = crashAfter, changeCount >= n { crashed = true; throw InjectedFailure(op: "crash:\(op)") }
        changeCount += 1
        try hook?(op, path)
    }

    /// After a "crash", bring the machine back up (the disk keeps what it had).
    func reboot() { crashed = false; crashAfter = nil; hook = nil }

    func put(_ path: String, _ text: String) {
        directories.insert(PathUtil.directory(of: path))
        nextID += 1
        files[path] = File(data: Data(text.utf8), modified: clock, id: nextID)
    }
    func text(_ path: String) -> String? { files[path].map { String(decoding: $0.data, as: UTF8.self) } }

    func exists(_ path: String) -> Bool { files[path] != nil || directories.contains(path) }
    func fingerprint(_ path: String) throws -> FileFingerprint {
        guard let f = files[path] else { throw CocoaError(.fileNoSuchFile) }
        return FileFingerprint(size: Int64(f.data.count), modified: f.modified, fileID: f.id)
    }
    func isWritable(_ path: String) -> Bool { !unwritable.contains(path) && exists(path) }
    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func freeSpace(atPath path: String) throws -> Int64 { free }
    func createDirectory(_ path: String) throws {
        try change("mkdir", path)
        var p = path
        while p != "/" && !p.isEmpty { directories.insert(p); p = PathUtil.directory(of: p) }
    }
    func copy(from: String, to: String) throws {
        try change("copy", to)
        guard var f = files[from] else { throw CocoaError(.fileNoSuchFile) }
        guard files[to] == nil else { throw CocoaError(.fileWriteFileExists) }
        nextID += 1; f.id = nextID
        files[to] = f
    }
    func move(from: String, to: String) throws {
        try change("move", to)
        guard let f = files[from] else { throw CocoaError(.fileNoSuchFile) }
        guard files[to] == nil else { throw CocoaError(.fileWriteFileExists) }
        files[to] = f; files[from] = nil
    }
    func remove(_ path: String) throws {
        try change("remove", path)
        files[path] = nil
    }
    func contents(ofDirectory path: String) throws -> [DirectoryEntry] {
        guard directories.contains(path) else { throw CocoaError(.fileNoSuchFile) }
        var out: [DirectoryEntry] = []
        for (p, f) in files where PathUtil.directory(of: p) == path {
            out.append(DirectoryEntry(name: PathUtil.fileName(of: p), isDirectory: false, size: Int64(f.data.count), modified: f.modified))
        }
        for d in directories where d != path && PathUtil.directory(of: d) == path {
            out.append(DirectoryEntry(name: PathUtil.fileName(of: d), isDirectory: true))
        }
        return out.sorted { $0.name < $1.name }
    }
    func read(_ path: String) throws -> Data {
        guard let f = files[path] else { throw CocoaError(.fileNoSuchFile) }
        return f.data
    }
    func writeAtomically(_ data: Data, to path: String) throws {
        try change("write", path)
        directories.insert(PathUtil.directory(of: path))
        nextID += 1
        files[path] = File(data: data, modified: clock, id: nextID)
    }

    /// Simulates another app rewriting a file.
    func touchExternally(_ path: String, _ text: String) {
        clock = clock.addingTimeInterval(5)
        nextID += 1
        files[path] = File(data: Data(text.utf8), modified: clock, id: nextID)
    }

    /// All files whose name looks like a MacPlayer temp (should be none after a finished or recovered save).
    var leftovers: [String] { files.keys.filter { PathUtil.fileName(of: $0).contains(".macplayer-") }.sorted() }
}
