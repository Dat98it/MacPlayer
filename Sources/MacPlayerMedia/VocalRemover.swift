import AVFoundation
import CoreML
import Foundation
import MacPlayerCore

/// Offline instrumental extraction. A fixed-size window is decoded and processed at a time, so a long
/// song does not require holding its PCM or spectrogram in memory. The caller supplies a fresh temp file.
public enum VocalRemover {
    public static let sampleRate = 44100.0

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noAudio, invalidDuration, destinationExists, model, transform, reading, writing
        public var description: String {
            switch self {
            case .noAudio: return "This file has no sound to separate."
            case .invalidDuration: return "The audio duration could not be read."
            case .destinationExists: return "The destination already exists. Nothing was overwritten."
            case .model: return "The vocal separation model could not process this audio."
            case .transform: return "The audio transform could not be created."
            case .reading: return "The audio could not be read."
            case .writing: return "The instrumental audio could not be written."
            }
        }
    }

    /// The app ships a compiled model. SwiftPM tests and development builds may compile the checked-in package.
    public static func modelLocation() throws -> URL {
        if let url = Bundle.main.url(forResource: "Instrumental", withExtension: "mlmodelc", subdirectory: "Models") { return url }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Models/Instrumental.mlpackage", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.path) { return source }
        #endif
        throw Failure.model
    }

    public static func audioDuration(of source: URL) async throws -> Double { try await inputInfo(source).duration }

    private static func inputInfo(_ source: URL) async throws -> (asset: AVURLAsset, track: AVAssetTrack, duration: Double) {
        guard source.isFileURL else { throw Failure.reading }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        // The audio can end before a video's last picture. Its track, rather than the movie duration,
        // is what the instrumental file must preserve.
        let duration = try await track.load(.timeRange).duration.seconds
        guard duration.isFinite, duration > 0 else { throw Failure.invalidDuration }
        return (asset, track, duration)
    }

    public static func writeInstrumental(source: URL, to output: URL, modelURL: URL? = nil,
                                         progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard source.isFileURL, output.isFileURL else { throw Failure.reading }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.destinationExists }
        try Task.checkCancellation()
        let (asset, track, duration) = try await inputInfo(source)
        let location = try modelURL ?? modelLocation()
        let worker = Task.detached(priority: .userInitiated) {
            try process(asset: asset, track: track, duration: duration, output: output, modelURL: location, progress: progress)
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func process(asset: AVAsset, track: AVAssetTrack, duration: Double, output: URL, modelURL: URL,
                                progress: (@Sendable (Double) -> Void)?) throws {
        try Task.checkCancellation()
        progress?(0.01)
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        defer { if compiled != modelURL { try? FileManager.default.removeItem(at: compiled) } }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: compiled, configuration: config)
        let transform = try VocalSTFT()
        let input = try PCMReader(asset: asset, track: track)
        defer { input.reader.cancelReading() }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        var writer: AVAudioFile?
        var finished = false
        var ownsOutput = false
        defer {
            writer = nil
            if ownsOutput && !finished { try? FileManager.default.removeItem(at: output) }
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.destinationExists }
        writer = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000],
                                 commonFormat: .pcmFormatFloat32, interleaved: false)
        ownsOutput = true
        var channels = [[Float](repeating: 0, count: VocalSTFT.trim), [Float](repeating: 0, count: VocalSTFT.trim)]
        var emitted = 0
        while true {
            try Task.checkCancellation()
            let needed = VocalSTFT.samples - channels[0].count
            let fresh = try input.read(frames: needed)
            for channel in 0..<2 { channels[channel].append(contentsOf: fresh[channel]) }
            let count = min(VocalSTFT.step, channels[0].count - VocalSTFT.trim)
            guard count > 0 else { break }
            let chunk = channels.map { $0 + [Float](repeating: 0, count: VocalSTFT.samples - $0.count) }
            let wave: [[Float]] = try autoreleasepool {
                let spectrum = try transform.spectrum(chunk)
                let features = try MLDictionaryFeatureProvider(dictionary: ["input": spectrum])
                let prediction = try model.prediction(from: features)
                guard let stem = prediction.featureValue(for: "output")?.multiArrayValue else { throw Failure.model }
                try Task.checkCancellation()
                // UVR's sign-inversion denoise cancels the network's bias. Without it a truly silent
                // input produced audible low-level noise, especially at the end of a song.
                let samples = spectrum.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0..<spectrum.count { samples[i] = -samples[i] }
                let opposite = try model.prediction(from: features)
                guard let negative = opposite.featureValue(for: "output")?.multiArrayValue,
                      stem.dataType == .float16, negative.dataType == .float16,
                      stem.shape.map(\.intValue) == [1, 4, VocalSTFT.bins, VocalSTFT.frames], negative.shape == stem.shape else { throw Failure.model }
                let first = stem.dataPointer.assumingMemoryBound(to: Float16.self), second = negative.dataPointer.assumingMemoryBound(to: Float16.self)
                let a = stem.strides.map(\.intValue), b = negative.strides.map(\.intValue)
                for plane in 0..<4 {
                    for bin in 0..<VocalSTFT.bins {
                        for frame in 0..<VocalSTFT.frames {
                            let i = plane * a[1] + bin * a[2] + frame * a[3], j = plane * b[1] + bin * b[2] + frame * b[3]
                            first[i] = Float16((Float(first[i]) - Float(second[j])) * 0.5)
                        }
                    }
                }
                // Inst HQ 3 predicts the instrumental directly; subtracting it would return the vocals instead.
                return try transform.waveform(stem)
            }
            try Task.checkCancellation()
            var offset = 0
            while offset < count {
                let n = min(32768, count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let floats = buffer.floatChannelData else { throw Failure.writing }
                buffer.frameLength = AVAudioFrameCount(n)
                for channel in 0..<2 {
                    wave[channel].withUnsafeBufferPointer { floats[channel].update(from: $0.baseAddress! + VocalSTFT.trim + offset, count: n) }
                }
                try writer?.write(from: buffer)
                offset += n
            }
            emitted += count
            progress?(min(0.98, 0.04 + 0.94 * Double(emitted) / (duration * sampleRate)))
            for channel in 0..<2 { channels[channel].removeFirst(count) }
        }
        guard emitted > 0 else { throw Failure.noAudio }
        writer = nil // Finalise the container before verification or moving the file.
        try Task.checkCancellation()
        finished = true
        progress?(1)
    }

    private final class PCMReader {
        let reader: AVAssetReader
        private let output: AVAssetReaderAudioMixOutput
        private var pending: [Float] = []
        private var position = 0
        private var ended = false

        init(asset: AVAsset, track: AVAssetTrack) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: sampleRate,
            ])
            guard reader.canAdd(output) else { throw Failure.reading }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure.reading }
        }

        func read(frames: Int) throws -> [[Float]] {
            var channels: [[Float]] = [[], []]
            for channel in 0..<2 { channels[channel].reserveCapacity(frames) }
            while channels[0].count < frames {
                try Task.checkCancellation()
                if position >= pending.count {
                    if ended { break }
                    guard let sample = output.copyNextSampleBuffer() else {
                        if reader.status == .failed { throw reader.error ?? Failure.reading }
                        ended = true; break
                    }
                    guard let data = CMSampleBufferGetDataBuffer(sample) else { throw Failure.reading }
                    let length = CMBlockBufferGetDataLength(data)
                    guard length % 8 == 0 else { throw Failure.reading }
                    pending = [Float](repeating: 0, count: length / 4); position = 0
                    let status = pending.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                    guard status == kCMBlockBufferNoErr else { throw Failure.reading }
                }
                let n = min(frames - channels[0].count, (pending.count - position) / 2)
                for i in 0..<n {
                    channels[0].append(pending[position + 2 * i]); channels[1].append(pending[position + 2 * i + 1])
                }
                position += 2 * n
            }
            return channels
        }
    }
}
