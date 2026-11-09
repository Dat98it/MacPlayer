import Foundation

/// How a cut is made. See design section 11: "Nhanh, không mã hóa lại" and "Chính xác".
public enum CutMode: String, Codable, Sendable {
    /// Copies the compressed samples. Fast, and the video is untouched, but the file keeps the frames from the
    /// previous keyframe up to the cut (hidden by an edit list), and effects/crop/burned-in text are impossible.
    case fast
    /// Decodes and re-encodes, so the cut lands on the exact frame and edits are applied.
    case exact
}

public enum VideoCodecChoice: String, Codable, CaseIterable, Sendable { case h264, hevc }

public enum OutputContainer: String, Codable, CaseIterable, Sendable {
    case mp4, mov, m4v
    public var fileExtension: String { rawValue }
}

/// Output frame size limit for re-encoded exports. `.source` keeps the source size.
public enum ResolutionLimit: String, Codable, CaseIterable, Sendable {
    case source, p2160, p1080, p720, p480
    public var maxHeight: Int? {
        switch self { case .source: return nil; case .p2160: return 2160; case .p1080: return 1080; case .p720: return 720; case .p480: return 480 }
    }
}

/// Quality presets for re-encoded output: bits per pixel per frame, so size scales with resolution and fps.
public enum QualityLevel: String, Codable, CaseIterable, Sendable {
    case high, medium, small
    public var bitsPerPixel: Double {
        switch self { case .high: return 0.12; case .medium: return 0.07; case .small: return 0.04 }
    }

    /// What a re-encode is measured against: the first source's own video data rate, size and codec.
    public struct SourceVideo: Equatable, Sendable {
        public var bitrate: Double, pixels: Double, isHEVC: Bool
        public init(bitrate: Double, pixels: Double, isHEVC: Bool) { self.bitrate = bitrate; self.pixels = pixels; self.isHEVC = isHEVC }
    }

    /// Video data rate for a re-encode, in bits per second.
    /// The preset is a floor expressed per pixel. "High" also never goes below what the source itself carries (scaled to the output size and
    /// to the codec's efficiency, with a little margin): a phone records HEVC at about 0.25 bit per pixel, twice the preset, and re-encoding
    /// such a clip at the preset alone visibly softens it. Never above the source's own rate, and never above 80 Mb/s.
    public func videoBitrate(width: Double, height: Double, fps: Double, hevc: Bool, source: SourceVideo?) -> Double {
        let preset = width * height * fps * bitsPerPixel * (hevc ? 0.65 : 1.0)
        guard self == .high, let src = source, src.bitrate > 0, src.pixels > 0 else { return preset }
        var matched = src.bitrate * min(1, width * height / src.pixels)
        if src.isHEVC && !hevc { matched *= 1.5 }          // H.264 needs about half as much again for the same picture
        if !src.isHEVC && hevc { matched *= 0.65 }
        let ceiling = min(80_000_000, max(preset, src.bitrate))
        return min(ceiling, max(preset, matched * 0.9))
    }
}

public struct ExportOptions: Codable, Equatable, Sendable {
    public var mode: CutMode
    public var container: OutputContainer
    public var codec: VideoCodecChoice
    public var resolution: ResolutionLimit
    public var includeAudio: Bool
    public var quality: QualityLevel

    public init(mode: CutMode = .exact, container: OutputContainer = .mp4, codec: VideoCodecChoice = .h264,
                resolution: ResolutionLimit = .source, includeAudio: Bool = true, quality: QualityLevel = .high) {
        self.mode = mode; self.container = container; self.codec = codec; self.resolution = resolution
        self.includeAudio = includeAudio; self.quality = quality
    }

    /// Rough output size per second of video, for space checks and the size estimate shown before exporting.
    /// A fast cut copies the source's own data rate; a re-encode follows the quality preset. Always an estimate.
    public func estimatedBytesPerSecond(source: MediaInfo) -> Double {
        let srcRate = (source.primaryVideo?.bitrate ?? 8_000_000) + (source.audio.first?.bitrate ?? 160_000)
        if mode == .fast { return srcRate / 8 }
        let v = source.primaryVideo
        var w = Double(v?.width ?? 1920), h = Double(v?.height ?? 1080)
        if let limit = resolution.maxHeight, h > Double(limit) { w *= Double(limit) / h; h = Double(limit) }
        let fps = v?.frameRate?.framesPerSecond ?? 30
        let video = quality.videoBitrate(width: w, height: h, fps: fps, hevc: codec == .hevc,
                                         source: v.map { QualityLevel.SourceVideo(bitrate: $0.bitrate ?? 0, pixels: Double($0.width * $0.height), isHEVC: $0.codec == "hvc1" || $0.codec == "hev1") })
        return (video + (includeAudio && source.hasAudio ? 160_000 : 0)) / 8
    }

    /// Warnings for a project of several videos: the first one's, adjusted for what a mix does to HDR.
    public func warnings(sources: [MediaInfo]) -> [ExportWarning] {
        guard let first = sources.first else { return [] }
        var out = warnings(source: first)
        guard mode == .exact, sources.count > 1 else { return out }
        let hdr = sources.filter { $0.primaryVideo?.isHDR == true }.count
        if hdr > 0, hdr < sources.count {
            out.removeAll { $0 == .hdrKept }
            out.insert(.hdrMixedToSDR, at: 0)
        } else if hdr == 0 { out.removeAll { $0 == .hdrKept } }
        return out
    }

    /// Warnings to show before the export runs (design section 11).
    public func warnings(source: MediaInfo) -> [ExportWarning] {
        var out: [ExportWarning] = []
        guard let v = source.primaryVideo else { return out }
        if mode == .fast {
            out.append(.fastCutKeepsLeadIn)
            if container.fileExtension != source.fileExtension, !(source.fileExtension == "m4v" || container == .m4v) { out.append(.containerChange(from: source.fileExtension, to: container.fileExtension)) }
        } else {
            if let limit = resolution.maxHeight, v.height < limit, resolution != .source { out.append(.noUpscale) }
            if v.isHDR { out.append(.hdrKept) }
            if v.dolbyVision == true { out.append(.dolbyVisionMayBeLost) }
            if v.isVariableFrameRate { out.append(.variableFrameRate) }
            out.append(.reencode)
        }
        return out
    }
}

public enum ExportWarning: Equatable, Sendable {
    case reencode
    case fastCutKeepsLeadIn
    case containerChange(from: String, to: String)
    case noUpscale
    /// An HDR source stays HDR: the picture is read in 10 bits and written as 10-bit HEVC (H.264 cannot carry it).
    case hdrKept
    /// Several videos are joined and only some are HDR: the whole file is written as SDR, the HDR ones tone-mapped.
    case hdrMixedToSDR
    /// Re-encoding keeps the HDR10/HLG picture but cannot carry the Dolby Vision metadata. A fast cut keeps it.
    case dolbyVisionMayBeLost
    case variableFrameRate
}
