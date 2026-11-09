import Foundation

public struct ScannedVideo: Equatable, Sendable {
    public var path: String
    public var name: String
    public var size: Int64
    public var modified: Date
}

public struct FolderScanResult: Equatable, Sendable {
    public var videos: [ScannedVideo] = []
    /// Files that were skipped because they are not video types we recognise.
    public var skippedOther = 0
    /// Folders that could not be read (permissions, drive gone). Reported, never fatal.
    public var unreadableFolders: [String] = []
    public var cancelled = false
}

/// Finds videos in folders the user chose. Reads only that folder (and its subfolders when asked), skips hidden
/// files, and does not follow symbolic links into folders, so it cannot wander outside the permission it was given.
public enum FolderScanner {
    public static func scan(folder: String, includeSubfolders: Bool, fs: FileSystem,
                            isCancelled: () -> Bool = { false }, progress: ((Int) -> Void)? = nil) -> FolderScanResult {
        var result = FolderScanResult()
        var stack = [folder]
        var visited = 0
        while let dir = stack.popLast() {
            if isCancelled() { result.cancelled = true; break }
            guard let entries = try? fs.contents(ofDirectory: dir) else { result.unreadableFolders.append(dir); continue }
            for e in entries {
                if e.name.hasPrefix(".") { continue }
                let full = PathUtil.join(dir, e.name)
                if e.isDirectory {
                    if includeSubfolders, !e.isSymlink { stack.append(full) }
                    continue
                }
                if MediaFiles.isCandidate(full) {
                    result.videos.append(ScannedVideo(path: full, name: e.name, size: e.size, modified: e.modified))
                    visited += 1
                    if visited % 50 == 0 { progress?(visited) }
                } else { result.skippedOther += 1 }
            }
        }
        progress?(result.videos.count)
        return result
    }

    /// Orders scan results. Duration needs probing, so it is applied by the caller after metadata is read.
    public static func sort(_ videos: [ScannedVideo], by sort: PlaylistSort) -> [ScannedVideo] {
        switch sort {
        case .naturalName, .duration, .manual, .folder: return videos.sorted { NaturalSort.less($0.name, $1.name) }
        case .modified, .created: return videos.sorted { ($0.modified, $1.name) < ($1.modified, $0.name) }
        case .size: return videos.sorted { ($0.size, $1.name) < ($1.size, $0.name) }
        }
    }

    /// "Follow folder": what a new scan changes. New videos go at the END (existing order is kept); items whose
    /// file is gone are flagged missing, not removed.
    public struct FollowChange: Equatable, Sendable {
        public var newVideos: [ScannedVideo]
        public var nowMissing: [UUID]
        public var backAgain: [UUID]
    }

    /// `excluded`: standardised paths the person took out of the list on purpose; they are not brought back as "new".
    public static func followChanges(items: [PlaylistItem], sourceID: UUID, scan: FolderScanResult, excluded: Set<String> = []) -> FollowChange {
        let known = Dictionary(items.filter { $0.folderSourceID == sourceID }.map { (PlaylistEditor.key($0.path), $0) }, uniquingKeysWith: { a, _ in a })
        let scanned = Set(scan.videos.map { PlaylistEditor.key($0.path) })
        let newVideos = FolderScanner.sort(scan.videos.filter { known[PlaylistEditor.key($0.path)] == nil && !excluded.contains(PlaylistEditor.key($0.path)) }, by: .naturalName)
        // Only mark things missing when the folder itself could be read; an unreadable folder says nothing about its files.
        let canJudge = scan.unreadableFolders.isEmpty && !scan.cancelled
        let missing = canJudge ? known.values.filter { !scanned.contains(PlaylistEditor.key($0.path)) && $0.availability != .missing }.map(\.id) : []
        let back = known.values.filter { scanned.contains(PlaylistEditor.key($0.path)) && $0.availability == .missing }.map(\.id)
        return FollowChange(newVideos: newVideos, nowMissing: missing, backAgain: back)
    }
}
