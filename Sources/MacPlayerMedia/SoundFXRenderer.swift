import AVFoundation
import Foundation
import MacPlayerCore

/// Gives a sound its bass, treble, pitch, room and echo by running it once through Apple's audio units, off line (faster than it plays), and
/// writing the result next to the app's other cached work. The original is never touched; the same settings on the same file are made once.
public enum SoundFXRenderer {
    nonisolated(unsafe) public static var cacheFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("macplayer-soundfx", isDirectory: true)
    /// Longer sounds are not processed.
    public static let maxSeconds = 3600.0

    public enum FXError: Error, CustomStringConvertible {
        case noAudio, tooLong, failed(String)
        public var description: String {
            switch self {
            case .noAudio: return "This file has no sound to change."
            case .tooLong: return "This sound is too long to change in one go (the limit is one hour)."
            case .failed(let m): return "Changing the sound failed: \(m)"
            }
        }
    }

    public static func cacheURL(for source: URL, fx: SoundFX) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(source.standardizedFileURL.path)|\(size)|\(Int(modified))|\(fx.cacheKey)"
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return cacheFolder.appendingPathComponent(String(format: "%016llx.m4a", h))
    }

    /// The changed sound, when it has been made before.
    public static func cached(for source: URL, fx: SoundFX) -> URL? {
        let u = cacheURL(for: source, fx: fx)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Makes (or finds) the changed copy of a file's sound.
    public static func process(_ source: URL, fx raw: SoundFX, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let fx = raw.clamped()
        if let hit = cached(for: source, fx: fx) { progress?(1); return hit }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let out = cacheURL(for: source, fx: fx)
        let temp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await Task.detached(priority: .userInitiated) { try render(source, fx: fx, to: temp, progress: progress) }.value
        // Only a finished file takes the final name, so a stopped run never leaves half a sound that would be taken for a good one.
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: temp, to: out)
        progress?(1)
        return out
    }

    private static func render(_ source: URL, fx: SoundFX, to dest: URL, progress: (@Sendable (Double) -> Void)?) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) } catch { throw FXError.noAudio }
        let format = file.processingFormat
        let total = file.length
        guard total > 0 else { throw FXError.noAudio }
        guard Double(total) / format.sampleRate <= maxSeconds else { throw FXError.tooLong }

        // Everything after the player works in stereo at the file's rate (the audio units are happiest so); a mixer after the player turns a
        // mono or surround file into it.
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) else { throw FXError.failed("no format") }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let inMixer = AVAudioMixerNode()
        engine.attach(player); engine.attach(inMixer)
        engine.connect(player, to: inMixer, format: format)
        var chain: [AVAudioNode] = [inMixer]
        func add(_ n: AVAudioNode) { engine.attach(n); chain.append(n) }

        let eq = AVAudioUnitEQ(numberOfBands: 3)
        if fx.bass != 0 || fx.mid != 0 || fx.treble != 0 {
            let b0 = eq.bands[0]; b0.filterType = .lowShelf; b0.frequency = 150; b0.gain = Float(fx.bass); b0.bypass = false
            let b1 = eq.bands[1]; b1.filterType = .parametric; b1.frequency = 1000; b1.bandwidth = 1.5; b1.gain = Float(fx.mid); b1.bypass = false
            let b2 = eq.bands[2]; b2.filterType = .highShelf; b2.frequency = 6000; b2.gain = Float(fx.treble); b2.bypass = false
            add(eq)
        }
        if fx.pitch != 0 {
            let p = AVAudioUnitTimePitch(); p.pitch = Float(fx.pitch * 100); p.rate = 1
            add(p)
        }
        if fx.echo > 0 {
            let d = AVAudioUnitDelay(); d.delayTime = 0.33; d.feedback = Float(20 + fx.echo * 30); d.lowPassCutoff = 7000; d.wetDryMix = Float(fx.echo * 55)
            add(d)
        }
        if fx.reverb > 0 {
            let r = AVAudioUnitReverb(); r.loadFactoryPreset(.largeHall); r.wetDryMix = Float(fx.reverb * 70)
            add(r)
        }
        chain.append(engine.mainMixerNode)
        for i in 0..<(chain.count - 1) { engine.connect(chain[i], to: chain[i + 1], format: stereo) }

        let maxFrames: AVAudioFrameCount = 4096
        do { try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: maxFrames) } catch { throw FXError.failed(error.localizedDescription) }
        do { try engine.start() } catch { throw FXError.failed(error.localizedDescription) }
        defer { engine.stop() }

        // Units that look ahead (the pitch shifter) delay the sound a little: that much is dropped from the front so the sound stays in time.
        let latency = chain.compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }.reduce(0, +)
        let skip = AVAudioFramePosition((latency * format.sampleRate).rounded())

        player.scheduleFile(file, at: nil)
        player.play()

        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 2,
                                       AVEncoderBitRateKey: 192_000]
        let outFile: AVAudioFile
        do { outFile = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { throw FXError.failed(error.localizedDescription) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else { throw FXError.failed("no buffer") }

        var rendered: AVAudioFramePosition = 0, written: AVAudioFramePosition = 0
        let limit = total + skip + AVAudioFramePosition(format.sampleRate)            // a safety stop
        while written < total, rendered < limit {
            buffer.frameLength = 0
            let want = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), total + skip - rendered > 0 ? total + skip - rendered : AVAudioFramePosition(maxFrames)))
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(max(1, want), to: buffer) } catch { throw FXError.failed(error.localizedDescription) }
            guard status == .success || status == .insufficientDataFromInputNode else { throw FXError.failed("the sound could not be drawn (\(status.rawValue))") }
            let n = AVAudioFramePosition(buffer.frameLength)
            guard n > 0 else { if status == .insufficientDataFromInputNode { rendered += AVAudioFramePosition(want); continue }; break }
            var from: AVAudioFramePosition = 0
            if rendered < skip { from = min(n, skip - rendered) }
            rendered += n
            let count = min(n - from, total - written)
            if count > 0 {
                if from == 0 && count == n { try outFile.write(from: buffer) }
                else if let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)) {
                    for c in 0..<Int(buffer.format.channelCount) {
                        if let src = buffer.floatChannelData?[c], let dst = part.floatChannelData?[c] { dst.update(from: src + Int(from), count: Int(count)) }
                    }
                    part.frameLength = AVAudioFrameCount(count)
                    try outFile.write(from: part)
                }
                written += count
            }
            progress?(min(1, Double(written) / Double(total)))
        }
        guard written > 0 else { throw FXError.failed("nothing was written") }
    }
}
