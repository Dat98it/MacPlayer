import AVFoundation
import Foundation
import MacPlayerCore

/// Audio only, as an .m4a (AAC). Same safe-save rules apply: the caller gives it a temp path.
public enum AudioExporter {
    public static func export(source: URL, span: TimeSpan, audio: AudioSettings, to output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) { throw ExportError.incompatible("The destination already exists.") }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExportError.incompatible("The source has no audio.") }
        let comp = AVMutableComposition()
        guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.emptySelection }
        let range = CMTimeRange(start: span.start.cmTime, duration: span.duration.cmTime)
        try t.insertTimeRange(range, of: track, at: .zero)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw ExportError.incompatible("AAC export is not available.") }
        if !audio.isNeutral {
            let p = AVMutableAudioMixInputParameters(track: t)
            let v = audio.muted ? 0 : Float(pow(10, audio.gainDB / 20))
            p.setVolume(v, at: .zero)
            if audio.fadeIn > 0, !audio.muted { p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: audio.fadeIn, preferredTimescale: 600))) }
            if audio.fadeOut > 0, !audio.muted {
                let d = CMTime(seconds: audio.fadeOut, preferredTimescale: 600)
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(range.duration, d), duration: d))
            }
            let mix = AVMutableAudioMix(); mix.inputParameters = [p]
            session.audioMix = mix
        }
        do { try await session.export(to: output, as: .m4a) }
        catch is CancellationError { try? FileManager.default.removeItem(at: output); throw ExportError.cancelled }
        catch { try? FileManager.default.removeItem(at: output); throw ExportError.sessionFailed(error.localizedDescription) }
    }
}
