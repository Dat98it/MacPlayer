import Foundation

/// What is known about a file at one moment. Compared later to see whether another app changed it.
public struct FileFingerprint: Codable, Equatable, Sendable {
    public var size: Int64
    public var modified: Date
    /// Inode / file ID, so a file replaced by another with the same size and time is still noticed.
    public var fileID: UInt64?

    public init(size: Int64, modified: Date, fileID: UInt64? = nil) {
        self.size = size; self.modified = modified; self.fileID = fileID
    }
}

public struct DirectoryEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modified: Date

    public init(name: String, isDirectory: Bool, isSymlink: Bool = false, size: Int64 = 0, modified: Date = .distantPast) {
        self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink; self.size = size; self.modified = modified
    }
}

/// The only way Core touches disk. Paths are plain strings. `move` and `copy` never overwrite.
/// The real implementation is `RealFileSystem` in MacPlayerMedia; tests use an in-memory fake.
public protocol FileSystem: AnyObject {
    func exists(_ path: String) -> Bool
    func fingerprint(_ path: String) throws -> FileFingerprint
    func isWritable(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    func freeSpace(atPath path: String) throws -> Int64
    /// Creates the folder and any missing parents. Succeeds if it already exists.
    func createDirectory(_ path: String) throws
    /// Fails if `to` exists.
    func copy(from: String, to: String) throws
    /// Atomic rename on one volume. Fails if `to` exists.
    func move(from: String, to: String) throws
    func remove(_ path: String) throws
    func contents(ofDirectory path: String) throws -> [DirectoryEntry]
    func read(_ path: String) throws -> Data
    /// Writes to a sibling temp name, then renames over `path` (so a crash never leaves half a file).
    func writeAtomically(_ data: Data, to path: String) throws
}

public enum PathUtil {
    /// The same file can arrive with its name in either Unicode form (Finder and the command line give "ệ" composed or not):
    /// paths are compared through this.
    public static func key(_ path: String) -> String { (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping }
    public static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }
    public static func directory(of path: String) -> String { (path as NSString).deletingLastPathComponent }
    public static func fileName(of path: String) -> String { (path as NSString).lastPathComponent }
    public static func stem(of path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    public static func ext(of path: String) -> String { (path as NSString).pathExtension }
    public static func join(_ dir: String, _ name: String) -> String { (dir as NSString).appendingPathComponent(name) }
}
