import Foundation

public enum FileStatus: Equatable, Sendable {
    /// The file is where it was.
    case present
    /// The file is gone, and it is certain: the drive is connected and a folder above it can be read. It was deleted or moved away.
    case deleted
    /// Nothing can be said: the drive is not connected, or nothing above the file can be read (an unplugged disk, a share that is down).
    case unknown
}

/// Telling "this file was deleted" from "this disk is not here right now". Removing a video from a list is only right in the first case:
/// a playlist on an external drive must survive the drive being unplugged.
public enum MissingFiles {
    public static func status(of path: String, fs: FileSystem, driveConnected: (String) -> Bool = { _ in true }) -> FileStatus {
        if fs.exists(path) { return .present }
        guard driveConnected(path) else { return .unknown }
        // The nearest folder above the file that still exists. If the file's own folder was deleted too, a higher one stands in.
        var dir = PathUtil.directory(of: path)
        while !dir.isEmpty, dir != "/", !fs.exists(dir) { dir = PathUtil.directory(of: dir) }
        // Reaching the top (or only the folder that holds drives) means the whole location is missing, not just the file.
        guard !dir.isEmpty, dir != "/", dir != "/Volumes", fs.isDirectory(dir), (try? fs.contents(ofDirectory: dir)) != nil else { return .unknown }
        return .deleted
    }

    /// A file that was only moved to the Trash is gone as far as a playlist is concerned.
    public static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/") || path.hasSuffix("/.Trash")
    }
}
