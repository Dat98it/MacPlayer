import Foundation

/// What is shown about a file when the pointer rests on it in a playlist: the facts, and the short names for them.
public struct ItemDetails: Equatable, Sendable {
    public var name: String
    public var folder: String
    /// False when the file is not where the playlist says it is.
    public var exists: Bool
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    public var duration: Double?
    public var width: Int?, height: Int?
    public var frameRate: Double?
    public var videoCodec: String?
    public var bitrate: Double?
    public var isHDR = false, isDolbyVision = false
    public var audioCodec: String?
    public var audioChannels: Int?
    /// A picture: no length and no sound to tell about.
    public var isImage = false

    public init(name: String, folder: String, exists: Bool) { self.name = name; self.folder = folder; self.exists = exists }

    /// "avc1" → "H.264" and so on; a codec that is not known is shown as it is, without the padding spaces of a four-letter code.
    public static func codecName(_ fourCC: String) -> String {
        let code = fourCC.trimmingCharacters(in: .whitespaces).lowercased()
        switch code {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC (H.265)"
        case "dvh1", "dvhe": return "HEVC (Dolby Vision)"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "ProRes"
        case "mp4v": return "MPEG-4"
        case "jpeg", "mjpa", "mjpb": return "Motion JPEG"
        case "aac", "mp4a": return "AAC"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "lpcm", "sowt", "twos", "in24", "in32": return "PCM"
        case "alac": return "Apple Lossless"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        default: return fourCC.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    public static func resolutionLabel(width: Int, height: Int) -> String { "\(width)×\(height)" }

    /// "30 fps", "29.97 fps": no needless zeros.
    public static func frameRateLabel(_ fps: Double) -> String {
        var s = String(format: "%.2f", fps)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " fps"
    }

    /// "4.99 Mb/s", "320 kb/s".
    public static func bitrateLabel(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000) }
        return String(format: "%.0f kb/s", bitsPerSecond / 1000)
    }
}
