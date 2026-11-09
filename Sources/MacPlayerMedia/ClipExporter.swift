import AVFoundation
import CoreMedia
import Foundation
import MacPlayerCore

extension OutputContainer {
    public var fileType: AVFileType {
        switch self { case .mp4: return .mp4; case .mov: return .mov; case .m4v: return .m4v }
    }
}

public enum ExportError: Error, CustomStringConvertible, Equatable {
    case sourceUnreadable(String)
    case emptySelection
    case incompatible(String)
    case sessionFailed(String)
    case cancelled
    case verificationFailed(String)
    /// The source's data stops being readable partway (see `SourceDamage`).
    case sourceDamaged(readable: Double, declared: Double)

    public var description: String {
        switch self {
        case .sourceUnreadable(let m): return "Cannot read the source: \(m)"
        case .emptySelection: return "Nothing selected to export."
        case .incompatible(let m): return "This export is not possible: \(m)"
        case .sessionFailed(let m): return "Export failed: \(m)"
        case .cancelled: return "Export cancelled."
        case .verificationFailed(let m): return "The exported file did not pass verification: \(m)"
        case .sourceDamaged(let r, let d): return SourceDamage.message(readable: r, declared: d)
        }
    }
}

public struct ExportProgress: Sendable {
    public var fraction: Double
}

/// Artwork to embed in the exported file (design section 9, third thumbnail feature).
public struct EmbeddedArtwork: Sendable {
    public var data: Data
    public var isPNG: Bool
    public init(data: Data, isPNG: Bool) { self.data = data; self.isPNG = isPNG }
}

/// Writes pieces of one or more sources into one file. Always writes to the URL it is given; deciding that URL
/// (a temp file next to the destination) is the job of `SafeSaver`.
public struct RenderExporter {
    public init() {}

    public func export(pieces: [RenderPiece], recipe: RenderRecipe = RenderRecipe(), to output: URL, options: ExportOptions,
                       artwork: EmbeddedArtwork? = nil, progress: (@Sendable (ExportProgress) -> Void)? = nil) async throws {
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.span.isEmpty }) else { throw ExportError.emptySelection }
        if FileManager.default.fileExists(atPath: output.path) { throw ExportError.incompatible("The destination already exists.") }
        var firstSource: QualityLevel.SourceVideo?
        for url in Set(pieces.map(\.sourceURL)) {
            let info: MediaInfo
            do { info = try await MediaProbe.probe(url: url) } catch { throw ExportError.sourceUnreadable("\(error)") }
            guard info.isExportable else { throw ExportError.incompatible("AVFoundation reports \(url.lastPathComponent) cannot be exported.") }
            if url == pieces[0].sourceURL, let v = info.primaryVideo, let rate = v.bitrate {
                firstSource = QualityLevel.SourceVideo(bitrate: rate, pixels: Double(v.width * v.height), isHEVC: v.codec == "hvc1" || v.codec == "hev1")
            }
        }
        if options.mode == .fast, recipe.needsReencode || pieces.contains(where: { !($0.look.isNeutral && $0.audio.isNeutral) }) {
            throw ExportError.incompatible("A fast cut copies the video as it is, so it cannot apply crop, rotation, colour, text, subtitles or sound changes. Use the exact mode.")
        }
        if options.mode == .exact {
            // Exact export decodes every frame and packet. Look at the end of each source first: a file that was cut off would
            // otherwise run for minutes and only fail at the end.
            for url in Set(pieces.map(\.sourceURL)) {
                let end = pieces.filter { $0.sourceURL == url }.map { $0.span.end.seconds }.max() ?? 0
                if let bad = await SourceHealth.tailDamage(of: url, endingAt: end), bad.readable < end - 0.05 {
                    throw ExportError.sourceDamaged(readable: bad.readable, declared: bad.declared)
                }
            }
        }
        let overlayMeta = Self.metadata(for: artwork, container: options.container)

        let built = try await CompositionBuilder.build(
            pieces: pieces, overlays: recipe.overlays, cues: recipe.burnedInCues, subtitleStyle: recipe.subtitleStyle,
            maxHeight: options.mode == .exact ? options.resolution.maxHeight : nil, includeAudio: options.includeAudio,
            replacementAudio: recipe.audio.replacementPath.map { URL(fileURLWithPath: $0) }, layers: recipe.layers, soundClips: recipe.soundClips, frameAccurate: true, fixedGrid: options.mode == .exact)

        if options.mode == .exact {
            // Always re-encodes (an export-session preset may silently copy the stream, which would not be exact).
            let exporter = ReencodeExporter()
            let job = ReencodeJob(asset: built.composition, videoComposition: built.videoComposition, audioMix: built.audioMix, duration: built.duration,
                                  codec: options.codec, container: options.container, quality: options.quality,
                                  maxHeight: options.resolution.maxHeight, includeAudio: options.includeAudio, metadata: overlayMeta, source: firstSource, hdr: built.hdr, detectHDR: false)
            try await withTaskCancellationHandler {
                try await exporter.run(job: job, to: output) { f in progress?(ExportProgress(fraction: f)) }
            } onCancel: { exporter.cancel() }
            return
        }

        // Fast: copy the compressed samples (AVFoundation trims with an edit list).
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.incompatible("No passthrough export is available for this source.")
        }
        guard session.supportedFileTypes.contains(options.container.fileType) else {
            throw ExportError.incompatible("\(options.container.rawValue.uppercased()) cannot hold this source without re-encoding.")
        }
        session.metadata = overlayMeta
        let task = Task { () -> Void in
            if let progress {
                for await state in session.states(updateInterval: 0.2) {
                    if case .exporting(let p) = state { progress(ExportProgress(fraction: p.fractionCompleted)) }
                }
            }
        }
        defer { task.cancel() }
        do {
            try await session.export(to: output, as: options.container.fileType)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            throw ExportError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw ExportError.cancelled }
            throw ExportError.sessionFailed(error.localizedDescription)
        }
    }

    /// Cover art as file metadata. MP4/M4V use the iTunes cover atom, MOV uses QuickTime's artwork key.
    static func metadata(for artwork: EmbeddedArtwork?, container: OutputContainer) -> [AVMetadataItem] {
        guard let art = artwork else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = container == .mov ? .commonIdentifierArtwork : .iTunesMetadataCoverArt
        item.dataType = art.isPNG ? (kCMMetadataBaseDataType_PNG as String) : (kCMMetadataBaseDataType_JPEG as String)
        item.value = art.data as NSData
        item.extendedLanguageTag = "und"
        return [item]
    }
}

/// The simple case: spans of one source with no edits.
public struct ClipExporter {
    public init() {}
    public func export(source: URL, spans: [TimeSpan], to output: URL, options: ExportOptions,
                       progress: (@Sendable (ExportProgress) -> Void)? = nil) async throws {
        try await RenderExporter().export(pieces: spans.map { RenderPiece(sourceURL: source, span: $0) }, to: output, options: options, progress: progress)
    }
}
