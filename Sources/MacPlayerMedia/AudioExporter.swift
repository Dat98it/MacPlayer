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

    /// The sound of a whole timeline (0.16): every clip's sound with its volume, fades, noise removal and voice effect, the sounds under the
    /// picture and the layers' sound, mixed as in the video export, written as an .m4a (AAC). The picture is not made at all.
    public static func exportTimeline(pieces: [RenderPiece], layers: [LayerSpec] = [], soundClips: [SoundClip] = [], to output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) { throw ExportError.incompatible("The destination already exists.") }
        let built = try await CompositionBuilder.build(pieces: pieces, includeAudio: true, layers: layers, soundClips: soundClips, frameAccurate: true)
        let comp = built.composition
        for t in comp.tracks(withMediaType: .video) { comp.removeTrack(t) }
        guard comp.tracks(withMediaType: .audio).contains(where: { !$0.segments.isEmpty }) else { throw ExportError.incompatible("The timeline has no sound.") }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw ExportError.incompatible("AAC export is not available.") }
        session.audioMix = built.audioMix
        session.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        do { try await session.export(to: output, as: .m4a) }
        catch is CancellationError { try? FileManager.default.removeItem(at: output); throw ExportError.cancelled }
        catch { try? FileManager.default.removeItem(at: output); throw ExportError.sessionFailed(error.localizedDescription) }
    }
}
