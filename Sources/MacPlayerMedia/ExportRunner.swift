import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MacPlayerCore
import UniformTypeIdentifiers

public struct ExportResult: Sendable {
    public var outcome: SaveOutcome
    /// A still exported next to the video (per-clip thumbnail), if one was asked for.
    public var thumbnailPath: String?
    /// Things that went wrong but did not fail the export (for example, the thumbnail could not be written).
    public var warnings: [String]
}

/// Runs one `ExportJob`: renders into a temp file, checks it, and only then puts it in place, through `SafeSaver`.
/// The video that is being read is never written to.
public final class ExportRunner: @unchecked Sendable {
    private let saver: SafeSaver
    private let fs: FileSystem

    public init(saver: SafeSaver, fs: FileSystem) { self.saver = saver; self.fs = fs }

    public func run(job: ExportJob, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportResult {
        guard !job.pieces.isEmpty else { throw SaveError.produceFailed("nothing to export") }
        if case .legacyReplaceOriginal = job.target { throw SaveError.produceFailed(SaveTarget.legacyReplaceMessage) }
        let pieces = job.pieces.map {
            RenderPiece(sourceURL: URL(fileURLWithPath: $0.sourcePath), span: $0.span, look: $0.look ?? job.recipe.look, audio: $0.audio ?? job.recipe.audio)
        }
        let expectedSeconds = job.pieces.reduce(0.0) { $0 + $1.span.duration.seconds / max(VideoLook.minimumSpeed, ($1.look ?? job.recipe.look).speed) }

        // Source info for the size estimate and the final check.
        var infos: [MediaInfo] = []
        for p in Set(job.pieces.map(\.sourcePath)).sorted() {
            if let i = try? await MediaProbe.probe(url: URL(fileURLWithPath: p)) { infos.append(i) }
        }
        let first = infos.first
        let estimate = Int64((first.map { job.options.estimatedBytesPerSecond(source: $0) } ?? 2_000_000) * expectedSeconds)
        let wantAudio = job.options.includeAudio && (infos.first?.hasAudio ?? false)

        var warnings: [String] = []
        var artwork: EmbeddedArtwork?
        if let t = job.embedArtworkTime, let src = job.sourcePaths.first {
            if let img = try? await FrameGrabber.image(url: URL(fileURLWithPath: src), at: t, accuracy: .exact),
               let data = ImageWriter.data(img, format: .jpeg(quality: 0.9)) { artwork = EmbeddedArtwork(data: data, isPNG: false) }
            else { warnings.append("The cover art frame could not be read, so no artwork was embedded.") }
        }

        let produce: SafeSaver.Produce = { tempPath in
            try await RenderExporter().export(pieces: pieces, recipe: job.recipe, to: URL(fileURLWithPath: tempPath), options: job.options, artwork: artwork) { p in
                onProgress?(p.fraction)
            }
        }
        let verify: SafeSaver.Verify = { tempPath in
            try await Self.verify(path: tempPath, expectedSeconds: expectedSeconds, wantAudio: wantAudio, frameRate: first?.frameRateForStepping)
        }

        let outcome: SaveOutcome
        switch job.target {
        case .newCopy(let path, let overwrite):
            if job.sourcePaths.contains(where: { PathUtil.same($0, path) }) { throw SaveError.destinationIsSource }
            outcome = try await saver.saveCopy(sourcePath: job.sourcePaths.first, destination: path, overwrite: overwrite, estimatedBytes: estimate, produce: produce, verify: verify)
        case .legacyReplaceOriginal:
            throw SaveError.produceFailed(SaveTarget.legacyReplaceMessage)
        }

        var thumbPath: String?
        if let t = job.thumbnailTime, let src = job.sourcePaths.first {
            do { thumbPath = try await Self.exportStill(source: src, at: t, besideVideo: outcome.finalPath, fs: fs) }
            catch { warnings.append("The thumbnail was not saved: \(error.localizedDescription)") }
        }
        if !job.sidecarSubtitles.isEmpty {
            let dir = PathUtil.directory(of: outcome.finalPath), stem = PathUtil.stem(of: outcome.finalPath)
            var path = PathUtil.join(dir, "\(stem).srt"), n = 2
            while fs.exists(path) { path = PathUtil.join(dir, "\(stem) \(n).srt"); n += 1 }
            do { try fs.writeAtomically(Data(SubtitleCodec.serialize(job.sidecarSubtitles, format: .srt).utf8), to: path) }
            catch { warnings.append("The subtitle file was not saved: \(error.localizedDescription)") }
        }
        return ExportResult(outcome: outcome, thumbnailPath: thumbPath, warnings: warnings)
    }

    /// The check before a new file is allowed to replace anything: it opens, has the expected length, has the
    /// expected tracks, and its first frame decodes.
    static func verify(path: String, expectedSeconds: Double, wantAudio: Bool, frameRate: FrameRate?) async throws {
        let url = URL(fileURLWithPath: path)
        let info: MediaInfo
        do { info = try await MediaProbe.probe(url: url) } catch { throw SaveError.verificationFailed("the file cannot be opened (\(error))") }
        guard info.hasVideo else { throw SaveError.verificationFailed("there is no video track") }
        if wantAudio, !info.hasAudio { throw SaveError.verificationFailed("the audio track is missing") }
        let tolerance = max(0.25, 4 / (frameRate?.framesPerSecond ?? 30))
        guard abs(info.duration.seconds - expectedSeconds) <= tolerance else {
            throw SaveError.verificationFailed(String(format: "length %.2fs, expected %.2fs", info.duration.seconds, expectedSeconds))
        }
        do { _ = try await FrameGrabber.image(url: url, at: .zero, accuracy: .nearest) }
        catch { throw SaveError.verificationFailed("the first frame cannot be decoded (\(error.localizedDescription))") }
    }

    /// Writes a still of the source at `time` next to the exported video, as JPEG, never overwriting.
    static func exportStill(source: String, at time: MediaTime, besideVideo video: String, fs: FileSystem) async throws -> String {
        let img = try await FrameGrabber.image(url: URL(fileURLWithPath: source), at: time, accuracy: .exact)
        let dir = PathUtil.directory(of: video), stem = PathUtil.stem(of: video)
        var path = PathUtil.join(dir, "\(stem).jpg"), n = 2
        while fs.exists(path) { path = PathUtil.join(dir, "\(stem) \(n).jpg"); n += 1 }
        try ImageWriter.write(img, to: URL(fileURLWithPath: path), format: .jpeg(quality: 0.92))
        return path
    }
}

public enum ImageWriter {
    public enum Format { case png, jpeg(quality: Double) }

    public enum WriteError: Error { case cannotCreate, cannotFinalize }

    public static func write(_ image: CGImage, to url: URL, format: Format) throws {
        let type: UTType, props: [CFString: Any]
        switch format {
        case .png: type = .png; props = [:]
        case .jpeg(let q): type = .jpeg; props = [kCGImageDestinationLossyCompressionQuality: q]
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw WriteError.cannotCreate }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.cannotFinalize }
    }

    public static func data(_ image: CGImage, format: Format) -> Data? {
        let type: UTType, props: [CFString: Any]
        switch format {
        case .png: type = .png; props = [:]
        case .jpeg(let q): type = .jpeg; props = [kCGImageDestinationLossyCompressionQuality: q]
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
