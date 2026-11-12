import Foundation

/// What a file in a playlist or on disk is for the player: something that plays, a picture to look at and edit, or a sound (music, a
/// recording) that plays without a picture (0.16).
public enum MediaKind: String, Codable, Sendable { case video, image, audio }

public enum ImageFiles {
    /// Extensions treated as "might be a picture". Whether the system can really read one is decided when it is opened; this list only keeps
    /// other files out. The camera RAW formats are read by the system's own RAW decoder.
    public static let candidateExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif", "jp2", "ico",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef",
    ]
    public static func isCandidate(_ path: String) -> Bool { candidateExtensions.contains(PathUtil.ext(of: path).lowercased()) }
}

public enum MediaFiles {
    /// A video, a picture or a sound; nil for anything else.
    public static func kind(of path: String) -> MediaKind? {
        if VideoFiles.isCandidate(path) { return .video }
        if ImageFiles.isCandidate(path) { return .image }
        if AudioFiles.isCandidate(path) { return .audio }
        return nil
    }
    public static func isCandidate(_ path: String) -> Bool { kind(of: path) != nil }
}

public extension PlaylistItem {
    var kind: MediaKind { MediaFiles.kind(of: path) ?? .video }
    var isImage: Bool { kind == .image }
    var isAudio: Bool { kind == .audio }
}

/// The picture formats a photo can be saved in, and how big the result may be.
public enum PhotoFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, gif
    public var fileExtension: String {
        switch self { case .jpeg: return "jpg"; case .png: return "png"; case .heic: return "heic"; case .tiff: return "tiff"; case .gif: return "gif" }
    }
    /// Quality applies to the formats that compress with loss.
    public var isLossy: Bool { self == .jpeg || self == .heic }
    /// The formats that keep an animation's frames (GIF, and PNG as an animated PNG, 0.16); the others keep its first frame.
    public var keepsAnimation: Bool { self == .gif || self == .png }
    /// The format a file of this extension is already in, when it is one of ours.
    public static func matching(extension ext: String) -> PhotoFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        default: return nil
        }
    }
}

public struct PhotoExportOptions: Equatable, Codable, Sendable {
    public var format: PhotoFormat = .jpeg
    /// 0.3...1, for JPEG and HEIC.
    public var quality: Double = 0.9
    /// The longest side of the result in pixels; nil keeps the size the edit gives.
    public var maxLongEdge: Int?
    /// Leave out where and with what the picture was taken (GPS position, camera and lens details).
    public var removeLocation = false
    public init() {}
}

public enum PhotoSizing {
    /// The size a picture of `width`×`height` becomes when its longest side may be at most `maxLongEdge` (never enlarged).
    public static func fit(width: Int, height: Int, maxLongEdge: Int?) -> (width: Int, height: Int) {
        guard let limit = maxLongEdge, limit > 0, max(width, height) > limit else { return (width, height) }
        let k = Double(limit) / Double(max(width, height))
        return (max(1, Int((Double(width) * k).rounded())), max(1, Int((Double(height) * k).rounded())))
    }
}
