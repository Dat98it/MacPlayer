import Foundation
import MacPlayerCore

/// The real disk. `move` and `copy` refuse to overwrite, as the `FileSystem` contract says.
public final class RealFileSystem: FileSystem {
    private let fm = FileManager.default
    public init() {}

    public func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fingerprint(_ path: String) throws -> FileFingerprint {
        let a = try fm.attributesOfItem(atPath: path)
        return FileFingerprint(size: (a[.size] as? NSNumber)?.int64Value ?? 0, modified: a[.modificationDate] as? Date ?? .distantPast,
                               fileID: (a[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    public func isWritable(_ path: String) -> Bool { fm.isWritableFile(atPath: path) }

    public func freeSpace(atPath path: String) throws -> Int64 {
        let url = URL(fileURLWithPath: path)
        let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        // Be conservative: purgeable space is not guaranteed to be freed in time.
        let plain = Int64(v.volumeAvailableCapacity ?? .max)
        let important = v.volumeAvailableCapacityForImportantUsage ?? .max
        return min(plain, important)
    }

    public func createDirectory(_ path: String) throws { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
    public func copy(from: String, to: String) throws { try fm.copyItem(atPath: from, toPath: to) }
    public func move(from: String, to: String) throws { try fm.moveItem(atPath: from, toPath: to) }
    public func remove(_ path: String) throws { try fm.removeItem(atPath: path) }
    public func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    public func writeAtomically(_ data: Data, to path: String) throws { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }

    public func contents(ofDirectory path: String) throws -> [DirectoryEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return DirectoryEntry(name: u.lastPathComponent, isDirectory: v?.isDirectory ?? false, isSymlink: v?.isSymbolicLink ?? false,
                                  size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast)
        }
    }
}
