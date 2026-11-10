import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MacPlayerCore

/// Generates small test movies whose every frame carries its own index as a 16-bit barcode (top-left),
/// and whose audio is a 1 kHz beep at the start of every whole second.
/// Used by tests and by `macplayer-probe` to measure seek accuracy, cut accuracy and A/V sync with real
/// encoders, with no personal media involved.
public enum SyntheticMedia {
    public enum Codec: String, CaseIterable, Sendable { case h264, hevc }
    public enum Container: String, CaseIterable, Sendable {
        case mp4, mov, m4v
        public var fileType: AVFileType {
            switch self {
            case .mp4: return .mp4
            case .mov: return .mov
            case .m4v: return .m4v
            }
        }
    }

    public struct Spec: Sendable {
        public var container: Container = .mp4
        public var codec: Codec = .h264
        public var width = 640
        public var height = 360
        public var frameRate = FrameRate(numerator: 30, denominator: 1)
        public var seconds = 10.0
        public var withAudio = true
        /// Sample rate of the (mono) sound; screen recordings and phone exports often use 22,050 or 24,000 Hz.
        public var audioSampleRate = 48_000.0
        /// A second audio track playing a 440 Hz tone (the first beeps at 1 kHz), for track-selection tests.
        public var secondAudioTrack = false
        /// With a second track: make the two tracks alternatives of each other (like languages), so a player offers a choice.
        public var alternateAudioTracks = false
        /// Keyframe interval in frames (a long GOP makes keyframe-limited cuts visible).
        public var keyframeInterval = 60
        /// Presentation timestamps jitter when > 0 (a rough variable-frame-rate stand-in).
        public var dropEveryNthFrame = 0
        /// Clockwise rotation stored as track metadata (0/90/180/270), like a phone held upright.
        public var rotationMetadata = 0
        /// Average video bit rate; 2 Mbit/s suits the small default size, benchmarks raise it for 1080p and 4K.
        public var bitrate = 2_000_000
        /// Writes 10-bit HEVC flagged with BT.2020 primaries and an HLG or PQ transfer function. The picture is the
        /// same synthetic pattern: only the flags are HDR, which is what detection and the export warning read.
        public enum HDRKind: Sendable { case hlg, pq }
        public var hdr: HDRKind?
        public init() {}
    }

    public enum GenerateError: Error, CustomStringConvertible {
        case writerFailed(String)
        public var description: String {
            switch self { case .writerFailed(let m): return "synthetic writer failed: \(m)" }
        }
    }

    static let barcodeBits = 16
    static let blockSize = 16

    public static func generate(to url: URL, spec: Spec) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.container.fileType)

        var compression: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: spec.keyframeInterval,
            AVVideoAverageBitRateKey: spec.bitrate,
            AVVideoAllowFrameReorderingKey: false,
        ]
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: (spec.codec == .h264 && spec.hdr == nil) ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
        ]
        if let hdr = spec.hdr {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: hdr == .hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = false
        switch spec.rotationMetadata {
        case 90: vIn.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 180: vIn.transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 270: vIn.transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: break
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: spec.hdr == nil ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
            ])
        writer.add(vIn)

        var a2In: AVAssetWriterInput?
        if spec.withAudio && spec.secondAudioTrack {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            a2In = a
        }
        var aIn: AVAssetWriterInput?
        var pendingGroup: AVAssetWriterInputGroup?
        if spec.withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: spec.audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: AACSettings.bitRate(sampleRate: spec.audioSampleRate, channels: 1),
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            aIn = a
            if let two = a2In, spec.alternateAudioTracks { pendingGroup = AVAssetWriterInputGroup(inputs: [a, two], defaultInput: a) }
        }
        if let g = pendingGroup, writer.canAdd(g) { writer.add(g) }

        guard writer.startWriting() else { throw GenerateError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let fps = spec.frameRate
        let frameCount = Int((spec.seconds * fps.framesPerSecond).rounded())

        // Video, pulled by the writer when it wants more data.
        let videoDone = Task.detached { () -> Void in
            var i = 0
            // HDR: the frame is drawn as 8-bit RGB, then converted into the 10-bit buffer the encoder wants.
            var transfer: VTPixelTransferSession?
            var scratch: CVPixelBuffer?
            if spec.hdr != nil {
                VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
                CVPixelBufferCreate(nil, spec.width, spec.height, kCVPixelFormatType_32BGRA, nil, &scratch)
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let q = DispatchQueue(label: "synthetic.video")
                vIn.requestMediaDataWhenReady(on: q) {
                    while vIn.isReadyForMoreMediaData {
                        if i >= frameCount {
                            vIn.markAsFinished()
                            cont.resume()
                            return
                        }
                        defer { i += 1 }
                        if spec.dropEveryNthFrame > 0, i > 0, i % spec.dropEveryNthFrame == 0 { continue }
                        guard let pool = adaptor.pixelBufferPool else { continue }
                        var pb: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                        guard let buf = pb else { continue }
                        if let t = transfer, let sc = scratch {
                            drawFrame(sc, index: i, width: spec.width, height: spec.height, fps: fps)
                            VTPixelTransferSessionTransferImage(t, from: sc, to: buf)
                        } else {
                            drawFrame(buf, index: i, width: spec.width, height: spec.height, fps: fps)
                        }
                        let pts = CMTime(value: CMTimeValue(i) * CMTimeValue(fps.denominator), timescale: fps.numerator)
                        if !adaptor.append(buf, withPresentationTime: pts) { vIn.markAsFinished(); cont.resume(); return }
                    }
                }
            }
        }

        let audioDone = Task.detached { () -> Void in
            guard let aIn else { return }
            let sampleRate = spec.audioSampleRate
            let total = Int(spec.seconds * sampleRate)
            let chunk = Int(sampleRate / 10)
            var written = 0
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let q = DispatchQueue(label: "synthetic.audio")
                aIn.requestMediaDataWhenReady(on: q) {
                    while aIn.isReadyForMoreMediaData {
                        if written >= total { aIn.markAsFinished(); cont.resume(); return }
                        let n = min(chunk, total - written)
                        if let sb = beepBuffer(startSample: written, count: n, sampleRate: sampleRate) {
                            if !aIn.append(sb) { aIn.markAsFinished(); cont.resume(); return }
                        }
                        written += n
                    }
                }
            }
        }

        let audio2Done = Task.detached { () -> Void in
            guard let aIn = a2In else { return }
            let sampleRate = 48_000.0, total = Int(spec.seconds * sampleRate), chunk = 4800
            var written = 0
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic.audio2")) {
                    while aIn.isReadyForMoreMediaData {
                        if written >= total { aIn.markAsFinished(); cont.resume(); return }
                        let n = min(chunk, total - written)
                        if let sb = beepBuffer(startSample: written, count: n, sampleRate: sampleRate, frequency: 440, continuous: true) { if !aIn.append(sb) { aIn.markAsFinished(); cont.resume(); return } }
                        written += n
                    }
                }
            }
        }
        await videoDone.value
        await audioDone.value
        await audio2Done.value
        await writer.finishWriting()
        if writer.status != .completed {
            throw GenerateError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    // MARK: Frame drawing and decoding

    private static func drawFrame(_ buf: CVPixelBuffer, index: Int, width: Int, height: Int, fps: FrameRate) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let p = base.assumingMemoryBound(to: UInt8.self)
        // Background shifts slowly so the picture is not trivially static; blocks stay pure black/white.
        let shade = UInt8(40 + (index % 60))
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4
                p[o] = shade; p[o + 1] = UInt8(truncatingIfNeeded: x / 3 + index); p[o + 2] = UInt8(truncatingIfNeeded: y / 2); p[o + 3] = 255
            }
        }
        // Corner markers (BGRA): top-right red, bottom-left green, bottom-right blue. Used to check orientation and crops.
        func fill(_ x0: Int, _ y0: Int, _ b: UInt8, _ g: UInt8, _ r: UInt8) {
            for y in y0..<(y0 + 40) { for x in x0..<(x0 + 40) { let o = y * stride + x * 4; p[o] = b; p[o + 1] = g; p[o + 2] = r; p[o + 3] = 255 } }
        }
        fill(width - 40, 0, 0, 0, 255)
        fill(0, height - 40, 0, 255, 0)
        fill(width - 40, height - 40, 255, 0, 0)
        for bit in 0..<barcodeBits {
            let on = (index >> (barcodeBits - 1 - bit)) & 1 == 1
            let v: UInt8 = on ? 255 : 0
            for y in 0..<blockSize {
                for x in 0..<blockSize {
                    let o = y * stride + (bit * blockSize + x) * 4
                    p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = 255
                }
            }
        }
    }

    /// Reads the frame index out of a BGRA pixel buffer drawn by `drawFrame`, or nil if the blocks are ambiguous.
    public static func decodeIndex(from buf: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf),
              CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buf) >= barcodeBits * blockSize else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var value = 0
        for bit in 0..<barcodeBits {
            let cx = bit * blockSize + blockSize / 2
            let cy = blockSize / 2
            let o = cy * stride + cx * 4
            let lum = (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3
            if lum > 60 && lum < 195 { return nil }
            value = (value << 1) | (lum >= 128 ? 1 : 0)
        }
        return value
    }

    private static func beepBuffer(startSample: Int, count: Int, sampleRate: Double, frequency: Double = 1000, continuous: Bool = false) -> CMSampleBuffer? {
        var samples = [Float](repeating: 0, count: count)
        let beepLen = Int(0.1 * sampleRate)
        for k in 0..<count {
            let s = startSample + k
            let inSecond = s % Int(sampleRate)
            if continuous || inSecond < beepLen {
                samples[k] = 0.5 * Float(sin(2 * Double.pi * frequency * Double(s) / sampleRate))
            }
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate))
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: count, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        let bytes = count * 4
        return samples.withUnsafeMutableBytes { raw -> CMSampleBuffer? in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: raw.baseAddress))
            guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: &abl) == noErr else { return nil }
            return sb
        }
    }
}
