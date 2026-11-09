import AVFoundation
import CoreMedia
import Foundation
import MacPlayerCore

public enum MediaProbeError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case noTracks
    public var description: String {
        switch self {
        case .unreadable(let m): return "Cannot read this file: \(m)"
        case .noTracks: return "The file has no audio or video tracks."
        }
    }
}

public enum MediaProbe {
    /// Reads metadata without decoding any frames. Never blocks the main thread: everything is async.
    public static func probe(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let tracks: [AVAssetTrack]
        let playable: Bool
        let exportable: Bool
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.load(.tracks)
            playable = try await asset.load(.isPlayable)
            exportable = try await asset.load(.isExportable)
        } catch {
            throw MediaProbeError.unreadable(error.localizedDescription)
        }
        if tracks.isEmpty { throw MediaProbeError.noTracks }

        var video: [MediaInfo.VideoTrack] = []
        var audio: [MediaInfo.AudioTrack] = []
        var subs: [MediaInfo.SubtitleTrack] = []

        for t in tracks {
            let descs = (try? await t.load(.formatDescriptions)) ?? []
            let desc = descs.first
            let codec = desc.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "????"
            let bitrate = (try? await t.load(.estimatedDataRate)).map(Double.init)
            switch t.mediaType {
            case .video:
                let size = (try? await t.load(.naturalSize)) ?? .zero
                let transform = (try? await t.load(.preferredTransform)) ?? .identity
                let rotation = Self.rotationDegrees(transform)
                let swapped = rotation == 90 || rotation == 270
                let nominal = (try? await t.load(.nominalFrameRate)) ?? 0
                let minDur = (try? await t.load(.minFrameDuration))
                let vfr = await Self.isVariableFrameRate(track: t, nominal: Double(nominal))
                var transfer: String?
                var primaries: String?
                var dolby = false
                if let d = desc {
                    let ext = CMFormatDescriptionGetExtensions(d) as? [String: Any]
                    transfer = ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                    primaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                    if let atoms = ext?["SampleDescriptionExtensionAtoms"] as? [String: Any] { dolby = atoms.keys.contains { $0 == "dvcC" || $0 == "dvvC" } }
                }
                let hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                var fr: FrameRate?
                if nominal > 0 { fr = FrameRate(approximately: Double(nominal)) }
                else if let m = minDur, m.isValid, m.seconds > 0 { fr = FrameRate(approximately: 1 / m.seconds) }
                video.append(.init(
                    trackID: t.trackID, codec: codec,
                    width: Int((swapped ? size.height : size.width).rounded()), height: Int((swapped ? size.width : size.height).rounded()),
                    rotation: rotation, frameRate: fr, isVariableFrameRate: vfr, bitrate: bitrate,
                    transferFunction: transfer, colorPrimaries: primaries, isHDR: hdr, dolbyVision: dolby ? true : nil))
            case .audio:
                var sr = 0.0
                var ch = 0
                if let d = desc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                    sr = asbd.mSampleRate
                    ch = Int(asbd.mChannelsPerFrame)
                }
                let lang = try? await t.load(.languageCode)
                audio.append(.init(trackID: t.trackID, codec: codec, sampleRate: sr, channels: ch, bitrate: bitrate, language: lang))
            case .subtitle, .closedCaption, .text:
                let lang = try? await t.load(.languageCode)
                subs.append(.init(trackID: t.trackID, language: lang, codec: codec))
            default:
                break
            }
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        return MediaInfo(
            duration: duration.isNumeric ? MediaTime(value: duration.value, timescale: duration.timescale) : .zero,
            fileExtension: url.pathExtension.lowercased(), fileSize: size,
            video: video, audio: audio, subtitles: subs, isPlayable: playable, isExportable: exportable)
    }

    static func rotationDegrees(_ t: CGAffineTransform) -> Int {
        let degrees = atan2(Double(t.b), Double(t.a)) * 180 / .pi
        let r = Int(degrees.rounded())
        return ((r % 360) + 360) % 360
    }

    /// Compares the shortest and a sampled frame duration; any real disagreement is variable frame rate.
    static func isVariableFrameRate(track: AVAssetTrack, nominal: Double) async -> Bool {
        guard nominal > 0, let min = try? await track.load(.minFrameDuration), min.isValid, min.seconds > 0 else { return false }
        // `minFrameDuration` vs `1/nominalFrameRate`: constant-rate media agree within a small tolerance.
        return abs(1 / min.seconds - nominal) > nominal * 0.02
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(bytes: bytes, encoding: .macOSRoman) ?? "????"
        return s.trimmingCharacters(in: .whitespaces)
    }
}
