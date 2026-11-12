import Foundation

/// What MacPlayer knows about a media file, normalised so the UI and the export planner never touch AVFoundation.
public struct MediaInfo: Codable, Equatable, Sendable {
    public struct VideoTrack: Codable, Equatable, Sendable {
        public var trackID: Int32
        /// FourCC of the codec, e.g. "avc1", "hvc1".
        public var codec: String
        /// Display size after the track's rotation is applied.
        public var width: Int
        public var height: Int
        /// Clockwise rotation in degrees (0, 90, 180, 270) from the track transform.
        public var rotation: Int
        public var frameRate: FrameRate?
        /// True when frame durations are not uniform.
        public var isVariableFrameRate: Bool
        public var bitrate: Double?
        public var transferFunction: String?
        public var colorPrimaries: String?
        public var isHDR: Bool
        /// The track carries a Dolby Vision configuration box. Optional so projects saved before this field still open.
        public var dolbyVision: Bool?

        public init(trackID: Int32, codec: String, width: Int, height: Int, rotation: Int = 0, frameRate: FrameRate? = nil,
                    isVariableFrameRate: Bool = false, bitrate: Double? = nil, transferFunction: String? = nil,
                    colorPrimaries: String? = nil, isHDR: Bool = false, dolbyVision: Bool? = nil) {
            self.trackID = trackID; self.codec = codec; self.width = width; self.height = height; self.rotation = rotation
            self.frameRate = frameRate; self.isVariableFrameRate = isVariableFrameRate; self.bitrate = bitrate
            self.transferFunction = transferFunction; self.colorPrimaries = colorPrimaries; self.isHDR = isHDR; self.dolbyVision = dolbyVision
        }
    }

    public struct AudioTrack: Codable, Equatable, Sendable {
        public var trackID: Int32
        public var codec: String
        public var sampleRate: Double
        public var channels: Int
        public var bitrate: Double?
        public var language: String?

        public init(trackID: Int32, codec: String, sampleRate: Double, channels: Int, bitrate: Double? = nil, language: String? = nil) {
            self.trackID = trackID; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
            self.bitrate = bitrate; self.language = language
        }
    }

    public struct SubtitleTrack: Codable, Equatable, Sendable {
        public var trackID: Int32
        public var language: String?
        public var codec: String
        public init(trackID: Int32, language: String?, codec: String) {
            self.trackID = trackID; self.language = language; self.codec = codec
        }
    }

    public var duration: MediaTime
    public var fileExtension: String
    public var fileSize: Int64
    public var video: [VideoTrack]
    public var audio: [AudioTrack]
    public var subtitles: [SubtitleTrack]
    /// False when AVFoundation reports the asset as not playable on this Mac.
    public var isPlayable: Bool
    /// False when AVFoundation reports it cannot be exported / used as an edit source.
    public var isExportable: Bool

    public init(duration: MediaTime, fileExtension: String, fileSize: Int64, video: [VideoTrack], audio: [AudioTrack],
                subtitles: [SubtitleTrack] = [], isPlayable: Bool = true, isExportable: Bool = true) {
        self.duration = duration; self.fileExtension = fileExtension; self.fileSize = fileSize
        self.video = video; self.audio = audio; self.subtitles = subtitles
        self.isPlayable = isPlayable; self.isExportable = isExportable
    }

    public var primaryVideo: VideoTrack? { video.first }
    public var hasVideo: Bool { !video.isEmpty }
    public var hasAudio: Bool { !audio.isEmpty }

    /// Frame rate to use for frame stepping and snapping. Falls back to 30 for audio-only or unknown, and for a picture slower than one a
    /// second (the cover video of a sound has one picture every 5 s, 0.2 fps: rounded to 0, it crashed the timecode, 0.16).
    public var frameRateForStepping: FrameRate {
        guard let r = primaryVideo?.frameRate, r.framesPerSecond >= 1 else { return FrameRate(numerator: 30, denominator: 1) }
        return r
    }
}
