import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import MacPlayerCore

/// Everything the re-encoder needs, built from the same edit model the preview plays.
/// How an HDR picture is tagged (HLG or PQ with its primaries and matrix), so the output can be written 10-bit with the same tags.
public struct HDRFormat: Equatable, Sendable {
    public var primaries: String, transfer: String, matrix: String
    public init(primaries: String, transfer: String, matrix: String) { self.primaries = primaries; self.transfer = transfer; self.matrix = matrix }

    /// The HDR tags of a video track, or nil for an SDR track.
    public static func of(_ track: AVAssetTrack) async -> HDRFormat? {
        guard let fd = (try? await track.load(.formatDescriptions))?.first else { return nil }
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
        guard let tf = ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
              tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) || tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) else { return nil }
        return HDRFormat(primaries: ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String),
                         transfer: tf,
                         matrix: ext?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String ?? (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String))
    }
}

public struct ReencodeJob {
    public var asset: AVAsset
    public var videoComposition: AVVideoComposition?
    public var audioMix: AVAudioMix?
    public var duration: CMTime
    public var codec: VideoCodecChoice
    public var container: OutputContainer
    public var quality: QualityLevel
    public var maxHeight: Int?
    public var includeAudio: Bool
    public var metadata: [AVMetadataItem]
    /// The first source's own video, so "High" can keep up with it.
    public var source: QualityLevel.SourceVideo?
    /// The tags the output is written with. `detectHDR` false means this is final (nil = SDR); true reads them from the asset's own track.
    public var hdr: HDRFormat?
    public var detectHDR = true

    public init(asset: AVAsset, videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil, duration: CMTime,
                codec: VideoCodecChoice, container: OutputContainer, quality: QualityLevel = .high, maxHeight: Int? = nil, includeAudio: Bool = true, metadata: [AVMetadataItem] = [], source: QualityLevel.SourceVideo? = nil, hdr: HDRFormat? = nil, detectHDR: Bool = true) {
        self.asset = asset; self.videoComposition = videoComposition; self.audioMix = audioMix; self.duration = duration
        self.codec = codec; self.container = container; self.quality = quality; self.maxHeight = maxHeight; self.includeAudio = includeAudio; self.metadata = metadata; self.source = source; self.hdr = hdr; self.detectHDR = detectHDR
    }
}

/// Decode -> (compose) -> encode, with explicit settings. Unlike an export-session preset this always
/// re-encodes, so the cut lands on the exact frame and filters/crops/burned-in subtitles are applied.
public final class ReencodeExporter: @unchecked Sendable {
    /// What went wrong, with the system's domain and code (and the error underneath, when there is one) so a failure can be told apart
    /// from another that reads the same: the plain description is often only "this operation could not be completed".
    static func detail(_ error: Error?, _ fallback: String) -> String {
        guard let e = error as NSError? else { return fallback }
        var text = "\(e.localizedDescription) (\(e.domain) \(e.code)"
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { text += ", underlying \(u.domain) \(u.code): \(u.localizedDescription)" }
        if let reason = e.localizedFailureReason { text += ", \(reason)" }
        return text + ")"
    }

    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    /// AVAssetReader/Writer must not be cancelled from another thread while `startReading` / `startWriting` is
    /// still running (that crashes inside MediaToolbox). So a cancel that arrives early only sets a flag, and the
    /// exporting task acts on it as soon as start-up is over.
    private enum Phase { case idle, starting, running, done }
    private var phase = Phase.idle

    public init() {}

    private func register(reader r: AVAssetReader, writer w: AVAssetWriter) { lock.lock(); reader = r; writer = w; phase = .starting; lock.unlock() }

    /// Called once reading and writing have started. Returns true if a cancel arrived meanwhile.
    private func startupFinished() -> Bool { lock.lock(); defer { lock.unlock() }; phase = .running; return cancelled }

    private func finish() { lock.lock(); phase = .done; lock.unlock() }

    /// A pump waiting for the writer. After `cancelWriting` the writer never calls back again, so cancel must wake it.
    private final class Gate: @unchecked Sendable {
        private let l = NSLock()
        private var cont: CheckedContinuation<Void, Never>?
        private var done = false
        func set(_ c: CheckedContinuation<Void, Never>) { l.lock(); if done { l.unlock(); c.resume() } else { cont = c; l.unlock() } }
        func resume() { l.lock(); let c = cont; cont = nil; done = true; l.unlock(); c?.resume() }
    }
    private var gates: [Gate] = []
    private func add(_ g: Gate) { lock.lock(); gates.append(g); let c = cancelled && phase != .starting; lock.unlock(); if c { g.resume() } }

    public func cancel() {
        lock.lock()
        cancelled = true
        let active = phase == .running
        let r = reader, w = writer
        let g = gates
        lock.unlock()
        if active {
            r?.cancelReading(); w?.cancelWriting()
            g.forEach { $0.resume() }
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func run(job: ReencodeJob, to output: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if FileManager.default.fileExists(atPath: output.path) { throw ExportError.incompatible("The destination already exists.") }
        let asset = job.asset
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = job.includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        guard let vTrack = vTracks.first else { throw ExportError.incompatible("The source has no video track.") }

        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let nominal = (try? await vTrack.load(.nominalFrameRate)) ?? 30
        // A composition sets its own pace (its frame duration). Its track's "nominal" rate is an average over the clips, which a photo clip
        // (one picture a second) pulls down: a timeline of 30 fps videos and a photo came out at 15 fps.
        var fps = nominal > 0 ? Double(nominal) : 30
        if let vc = job.videoComposition, vc.frameDuration.isNumeric, vc.frameDuration.seconds > 0 { fps = 1 / vc.frameDuration.seconds }

        // Output size: composition render size if present, else the natural (stored) size. Even numbers only.
        var size = job.videoComposition?.renderSize ?? natural
        // The limit is for the shorter side of the picture as shown (a tall phone video at 720p is 720 × 1280).
        let shown = job.videoComposition == nil ? Self.displaySize(natural, transform) : size
        let displayHeight = min(shown.width, shown.height)
        if let limit = job.maxHeight, Int(displayHeight) > limit {
            let scale = Double(limit) / Double(displayHeight)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let w = RenderGeometry.even(Double(size.width)), h = RenderGeometry.even(Double(size.height))

        // HDR (HLG or PQ) must not be squeezed into 8 bits: read 10-bit pictures and write 10-bit HEVC with the same colour tags.
        // H.264 cannot carry it here, so an HDR source is always written as HEVC.
        let hdr: HDRFormat? = job.detectHDR ? await HDRFormat.of(vTrack) : job.hdr
        let codec: VideoCodecChoice = hdr != nil ? .hevc : job.codec

        let rd = try AVAssetReader(asset: asset)
        let wr = try AVAssetWriter(outputURL: output, fileType: job.container.fileType)
        wr.metadata = job.metadata
        register(reader: rd, writer: wr)

        // Video in
        let pixelSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: hdr != nil ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ]
        let vOut: AVAssetReaderOutput
        if let vc = job.videoComposition {
            let o = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: pixelSettings)
            o.videoComposition = vc
            vOut = o
        } else {
            vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: pixelSettings)
        }
        vOut.alwaysCopiesSampleData = false
        guard rd.canAdd(vOut) else { throw ExportError.incompatible("Cannot read the video track.") }
        rd.add(vOut)

        let bitrate = Int(job.quality.videoBitrate(width: Double(w), height: Double(h), fps: fps, hevc: codec == .hevc, source: job.source))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(300_000, bitrate),
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
        ]
        var vSettings: [String: Any] = [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ]
        if let hdr {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            vSettings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: hdr.primaries, AVVideoTransferFunctionKey: hdr.transfer, AVVideoYCbCrMatrixKey: hdr.matrix]
        }
        vSettings[AVVideoCompressionPropertiesKey] = compression
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        // Rotation is kept as metadata unless a composition already applied it.
        if job.videoComposition == nil { vIn.transform = transform }
        guard wr.canAdd(vIn) else { throw ExportError.incompatible("This codec/container pair is not supported.") }
        wr.add(vIn)

        // Audio in
        var aOut: AVAssetReaderOutput?
        var aIn: AVAssetWriterInput?
        if !aTracks.isEmpty {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            let o: AVAssetReaderOutput
            if let mix = job.audioMix {
                let m = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: pcm)
                m.audioMix = mix
                o = m
            } else {
                o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: pcm)
            }
            o.alwaysCopiesSampleData = false
            if rd.canAdd(o) {
                rd.add(o)
                aOut = o
                var channels = 2
                var rate = 48_000.0
                if let d = (try? await aTracks[0].load(.formatDescriptions))?.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                    channels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
                    rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
                }
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: AACSettings.bitRate(sampleRate: rate, channels: channels),
                ])
                a.expectsMediaDataInRealTime = false
                if wr.canAdd(a) { wr.add(a); aIn = a }
            }
        }

        // Nothing past the end of the composition: a sped-up or slowed-down soundtrack otherwise runs on after the picture has ended.
        if job.duration.isNumeric, job.duration.seconds > 0 { rd.timeRange = CMTimeRange(start: .zero, duration: job.duration) }
        defer { finish() }
        if isCancelled { throw ExportError.cancelled } // cancelled before anything was started
        guard rd.startReading() else { throw ExportError.sessionFailed(Self.detail(rd.error, "reader did not start")) }
        guard wr.startWriting() else { rd.cancelReading(); throw ExportError.sessionFailed(Self.detail(wr.error, "writer did not start")) }
        wr.startSession(atSourceTime: .zero)
        if startupFinished() {
            // A cancel arrived during start-up: stop here, from this task, where it is safe.
            rd.cancelReading(); wr.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw ExportError.cancelled
        }

        let total = max(job.duration.seconds, 0.001)
        let progressBox = ProgressBox()

        async let videoDone: Void = self.pump(output: vOut, input: vIn, writer: wr) { sb in
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            progressBox.set(t); progress?(min(1, t / total))
        }
        async let audioDone: Void = {
            if let aOut, let aIn { try await self.pump(output: aOut, input: aIn, writer: wr, onSample: nil) }
        }()
        do {
            try await videoDone
            try await audioDone
        } catch {
            rd.cancelReading(); wr.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if isCancelled { throw ExportError.cancelled }
            throw error
        }

        if isCancelled { rd.cancelReading(); wr.cancelWriting(); try? FileManager.default.removeItem(at: output); throw ExportError.cancelled }
        if rd.status == .failed {
            wr.cancelWriting(); try? FileManager.default.removeItem(at: output)
            // "Cannot Decode" partway through: the data ran out or is damaged there. Say where, instead of AVFoundation's own words.
            if let e = rd.error as NSError?, e.code == -11821, progressBox.value > 1 {
                throw ExportError.sourceDamaged(readable: progressBox.value, declared: job.duration.seconds)
            }
            throw ExportError.sessionFailed(Self.detail(rd.error, "reading failed"))
        }
        await wr.finishWriting()
        if wr.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw ExportError.sessionFailed(Self.detail(wr.error, "writer status \(wr.status.rawValue)"))
        }
        progress?(1)
    }

    static func displaySize(_ s: CGSize, _ t: CGAffineTransform) -> CGSize {
        let r = s.applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    private final class ProgressBox: @unchecked Sendable {
        private let l = NSLock(); private var v = 0.0
        func set(_ x: Double) { l.lock(); v = x; l.unlock() }
        var value: Double { l.lock(); defer { l.unlock() }; return v }
    }

    /// Feeds samples from a reader output to a writer input until the output is drained or the export is cancelled.
    private func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, writer: AVAssetWriter,
                      onSample: (@Sendable (CMSampleBuffer) -> Void)?) async throws {
        struct Box: @unchecked Sendable { let o: AVAssetReaderOutput; let i: AVAssetWriterInput; let w: AVAssetWriter }
        let box = Box(o: output, i: input, w: writer)
        let gate = Gate()
        add(gate)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gate.set(cont)
            let q = DispatchQueue(label: "macplayer.reencode.\(input.mediaType.rawValue)")
            var finished = false
            func end() {
                if finished { return }
                finished = true
                // markAsFinished on a cancelled or failed writer raises an exception.
                if box.w.status == .writing { box.i.markAsFinished() }
                gate.resume()
            }
            box.i.requestMediaDataWhenReady(on: q) { [weak self] in
                while box.i.isReadyForMoreMediaData && !finished {
                    if self?.isCancelled ?? true { end(); return }
                    guard let sb = box.o.copyNextSampleBuffer() else { end(); return }
                    onSample?(sb)
                    if !box.i.append(sb) { end(); return }
                }
            }
        }
    }
}

/// The AAC encoder refuses a bit rate that is too high for the sample rate ("encoding parameters are not supported", -12651): 160 kb/s
/// stereo is fine at 44.1 or 48 kHz but not at the 22.05 or 24 kHz that many screen recordings and phone exports use.
public enum AACSettings {
    public static func bitRate(sampleRate: Double, channels: Int) -> Int {
        let mono = channels == 1
        switch sampleRate {
        case ..<16_000: return mono ? 32_000 : 64_000
        case ..<32_000: return mono ? 48_000 : 96_000
        default: return mono ? 96_000 : 160_000
        }
    }
}
