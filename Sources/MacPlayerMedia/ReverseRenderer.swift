import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacPlayerCore

/// Writes a copy of part of a video that plays backwards, picture and sound. Frames are decoded a few seconds at a time, from the end
/// towards the start, so a long clip never has to fit in memory. The original is only read.
public enum ReverseRenderer {
    public enum ReverseError: Error, CustomStringConvertible {
        case noVideo, tooLong(Double), failed(String), cancelled
        public var description: String {
            switch self {
            case .noVideo: return "This file has no picture to reverse."
            case .tooLong(let m): return "A clip of more than \(Int(m)) seconds is too long to reverse."
            case .failed(let m): return "Reversing failed: \(m)"
            case .cancelled: return "Reversing was cancelled."
            }
        }
    }

    /// The longest part that is reversed in one go.
    public static let maxSeconds = 180.0

    private final class Flag: @unchecked Sendable { private let l = NSLock(); private var v = false; var set: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }

    public static func reverse(source: URL, span: TimeSpan, to output: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard span.duration.seconds <= maxSeconds else { throw ReverseError.tooLong(maxSeconds) }
        let flag = Flag()
        try await withTaskCancellationHandler {
            try await run(source: source, span: span, output: output, progress: progress, cancelled: flag)
        } onCancel: { flag.set = true }
    }

    private static func run(source: URL, span: TimeSpan, output: URL, progress: (@Sendable (Double) -> Void)?, cancelled: Flag) async throws {
        let asset = AVURLAsset(url: source)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ReverseError.noVideo }
        let natural = try await vTrack.load(.naturalSize), transform = try await vTrack.load(.preferredTransform)
        let nominal = Double(try await vTrack.load(.nominalFrameRate))
        let rate = FrameRate(approximately: nominal > 0 ? nominal : 30)
        let frameDur = rate.frameDuration.cmTime
        let range = CMTimeRange(start: span.start.cmTime, duration: span.duration.cmTime)

        // 1. When every frame of the part is shown (read without decoding: quick).
        var times: [CMTime] = []
        do {
            let r = try AVAssetReader(asset: asset); r.timeRange = range
            let o = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
            r.add(o)
            guard r.startReading() else { throw ReverseError.failed(r.error?.localizedDescription ?? "cannot read") }
            while let sb = o.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb)) } }
        }
        times.sort { CMTimeCompare($0, $1) < 0 }
        guard !times.isEmpty else { throw ReverseError.failed("no frames in that part") }

        // 2. The writer.
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let width = Int(natural.width), height = Int(natural.height)
        let srcBitrate = Double(try await vTrack.load(.estimatedDataRate))
        let bitrate = min(max(srcBitrate * 1.1, 6_000_000), 80_000_000)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        vIn.transform = transform; vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(vIn) else { throw ReverseError.failed("cannot write video") }
        writer.add(vIn)

        // Sound: read the part as plain 16-bit samples, reversed in memory (a few MB per minute).
        var audioBuffers: [CMSampleBuffer] = []
        if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            audioBuffers = (try? await reversedAudio(asset: asset, track: aTrack, range: range)) ?? []
        }
        var aIn: AVAssetWriterInput?
        if let first = audioBuffers.first, let fmt = CMSampleBufferGetFormatDescription(first),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVEncoderBitRateKey: asbd.mChannelsPerFrame == 1 ? 96_000 : 160_000])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input }
        }
        guard writer.startWriting() else { throw ReverseError.failed(writer.error?.localizedDescription ?? "cannot start writing") }
        writer.startSession(atSourceTime: .zero)

        // 3. Pictures: chunks from the end, each written back to front.
        let bytesPerFrame = max(1, width * height * 4)
        let chunk = min(60, max(6, 320_000_000 / bytesPerFrame))
        let total = times.count
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        final class State: @unchecked Sendable { var next = 0; var chunkEnd: Int; var pending: [(CVPixelBuffer, CMTime)] = []; var failed: String?; init(_ e: Int) { chunkEnd = e } }
        let state = State(total)
        let videoQueue = DispatchQueue(label: "macplayer.reverse.video"), audioQueue = DispatchQueue(label: "macplayer.reverse.audio")

        // Reads frames [from, to) of `times` into memory, in display order.
        func readChunk(_ from: Int, _ to: Int) -> [(CVPixelBuffer, CMTime)] {
            guard let r = try? AVAssetReader(asset: asset) else { return [] }
            let start = times[from], end = CMTimeAdd(times[to - 1], frameDur)
            r.timeRange = CMTimeRange(start: start, end: end)
            let o = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            o.alwaysCopiesSampleData = true
            r.add(o)
            guard r.startReading() else { return [] }
            var out: [(CVPixelBuffer, CMTime)] = []
            while let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
                var copy: CVPixelBuffer?
                CVPixelBufferCreate(nil, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), kCVPixelFormatType_32BGRA, nil, &copy)
                guard let c = copy else { continue }
                context.render(CIImage(cvPixelBuffer: pb), to: c)
                out.append((c, CMSampleBufferGetPresentationTimeStamp(sb)))
            }
            return out
        }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            var videoFinished = false
            vIn.requestMediaDataWhenReady(on: videoQueue) {
                while vIn.isReadyForMoreMediaData && !videoFinished {
                    if cancelled.set || state.failed != nil { vIn.markAsFinished(); videoFinished = true; group.leave(); return }
                    if state.pending.isEmpty {
                        guard state.chunkEnd > 0 else { vIn.markAsFinished(); videoFinished = true; group.leave(); return }
                        let from = max(0, state.chunkEnd - chunk)
                        state.pending = readChunk(from, state.chunkEnd).reversed()          // last frame first
                        if state.pending.isEmpty { state.failed = "could not decode frames \(from)–\(state.chunkEnd)"; continue }
                        state.chunkEnd = from
                    }
                    let (pb, _) = state.pending.removeFirst()
                    let pts = CMTimeMultiply(frameDur, multiplier: Int32(state.next))
                    if !adaptor.append(pb, withPresentationTime: pts) { state.failed = writer.error?.localizedDescription ?? "the writer stopped"; continue }
                    state.next += 1
                    progress?(min(0.98, Double(state.next) / Double(total)))
                }
            }
            if let aIn {
                group.enter()
                var index = 0, audioFinished = false
                aIn.requestMediaDataWhenReady(on: audioQueue) {
                    while aIn.isReadyForMoreMediaData && !audioFinished {
                        if cancelled.set || index >= audioBuffers.count { aIn.markAsFinished(); audioFinished = true; group.leave(); return }
                        if !aIn.append(audioBuffers[index]) { aIn.markAsFinished(); audioFinished = true; group.leave(); return }
                        index += 1
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
        if cancelled.set { writer.cancelWriting(); try? FileManager.default.removeItem(at: output); throw ReverseError.cancelled }
        if let f = state.failed { writer.cancelWriting(); try? FileManager.default.removeItem(at: output); throw ReverseError.failed(f) }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw ReverseError.failed(writer.error?.localizedDescription ?? "the file was not finished")
        }
        progress?(1)
    }

    /// The part's sound as 16-bit samples, played back to front, cut into buffers the writer can take.
    private static func reversedAudio(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) async throws -> [CMSampleBuffer] {
        let reader = try AVAssetReader(asset: asset); reader.timeRange = range
        var rate = 48_000.0, channels = 2
        if let d = (try await track.load(.formatDescriptions)).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000; channels = min(2, max(1, Int(asbd.mChannelsPerFrame)))
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var bytes = Data()
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb)
            var chunk = [UInt8](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            bytes.append(contentsOf: chunk)
        }
        let frameBytes = 2 * channels
        let frames = bytes.count / frameBytes
        guard frames > 0 else { return [] }
        var reversed = Data(count: frames * frameBytes)
        bytes.withUnsafeBytes { src in
            reversed.withUnsafeMutableBytes { dst in
                for f in 0..<frames { memcpy(dst.baseAddress! + f * frameBytes, src.baseAddress! + (frames - 1 - f) * frameBytes, frameBytes) }
            }
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(frameBytes), mFramesPerPacket: 1, mBytesPerFrame: UInt32(frameBytes),
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let fmt = format else { return [] }
        var buffers: [CMSampleBuffer] = []
        let per = 4096
        var f = 0
        while f < frames {
            let n = min(per, frames - f)
            let slice = reversed.subdata(in: (f * frameBytes)..<((f + n) * frameBytes))
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: slice.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: slice.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard let bb = block else { break }
            slice.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: slice.count) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb, formatDescription: fmt, sampleCount: n,
                                                                  presentationTimeStamp: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sb)
            if let sb { buffers.append(sb) }
            f += n
        }
        return buffers
    }
}
