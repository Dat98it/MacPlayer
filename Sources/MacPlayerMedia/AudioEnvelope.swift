import AVFoundation
import CoreMedia
import Foundation

/// Loudness over time, for checking that a cut or a join kept the sound where it belongs.
/// Real footage has no beeps to count, so two files are compared by the shape of their loudness curves.
public enum AudioEnvelope {
    /// Loudness of the first audio track as the mean absolute value of each 10 ms of 8 kHz mono, for a span of the file
    /// (the whole file when no span is given). `seconds` is how much sound was actually read, so a result with too little
    /// or too much sound shows.
    public static func read(_ url: URL, from start: CMTime? = nil, duration: Double? = nil) async -> (bins: [Float], seconds: Double)? {
        guard let samples = await loadSamples(url, from: start, duration: duration) else { return nil }
        var bins: [Float] = []
        var i = 0
        while i + 80 <= samples.count {
            var s = 0.0
            for k in i..<(i + 80) { s += Double(abs(Int(samples[k]))) }
            bins.append(Float(s / 80)); i += 80
        }
        return (bins, Double(samples.count) / 8000)
    }

    /// The first audio track as 8 kHz mono 16-bit samples, for a span of the file (the whole file when no span is given).
    public static func loadSamples(_ url: URL, from start: CMTime? = nil, duration: Double? = nil) async -> [Int16]? {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .audio).first, let r = try? AVAssetReader(asset: a) else { return nil }
        if let s = start, let d = duration { r.timeRange = CMTimeRange(start: s, duration: CMTime(seconds: d, preferredTimescale: 60000)) }
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
                                                                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        r.add(o)
        guard r.startReading() else { return nil }
        var samples: [Int16] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb)
            var chunk = [Int16](repeating: 0, count: n / 2)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// How well two loudness curves line up: the best shift in ms (positive = `b` is late) within ±`maxLagBins` × 10 ms (default 200 ms), and the correlation there.
    /// Nil when either curve is flat (silence), where a shift cannot be measured.
    public static func align(_ a: [Float], _ b: [Float], maxLagBins: Int = 20) -> (lagMs: Int, correlation: Double)? {
        func corr(_ x: ArraySlice<Float>, _ y: ArraySlice<Float>) -> Double? {
            guard x.count == y.count, x.count > 20 else { return nil }
            let mx = x.reduce(0, +) / Float(x.count), my = y.reduce(0, +) / Float(y.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for (p, q) in zip(x, y) { let dx = Double(p - mx), dy = Double(q - my); sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
            guard sxx > 1e-6, syy > 1e-6 else { return nil }
            return sxy / (sxx * syy).squareRoot()
        }
        var best: (Int, Double)?
        for lag in -maxLagBins...maxLagBins {
            // b[i + lag] ↔ a[i]
            let lo = max(0, -lag), hi = min(a.count, b.count - lag)
            guard hi - lo > 20, let c = corr(a[lo..<hi], b[(lo + lag)..<(hi + lag)]) else { continue }
            if best == nil || c > best!.1 { best = (lag * 10, c) }
        }
        return best.map { (lagMs: $0.0, correlation: $0.1) }
    }

    /// Aligns two stretches of the same sound by their waveforms (8 kHz): the shift in milliseconds (positive = `b` is late) within
    /// ±`maxLagMs`, to 0.125 ms, and the normalised correlation there. Unlike the loudness curves this works on steady ambient noise too,
    /// as long as the sound was copied or encoded faithfully. Nil when either side is silent.
    public static func alignWaveforms(_ a: [Int16], _ b: [Int16], maxLagMs: Int = 200) -> (lagMs: Double, correlation: Double)? {
        let n = min(a.count, b.count) - 8 * maxLagMs
        guard n > 4000 else { return nil }
        let x = a.prefix(n).map { Float($0) }, maxLag = 8 * maxLagMs
        let ex = x.reduce(0) { $0 + $1 * $1 }
        guard ex > 1 else { return nil }
        var best: (Int, Double)?
        b.withUnsafeBufferPointer { bp in
            x.withUnsafeBufferPointer { xp in
                for lag in -maxLag...maxLag {
                    // b[i + lag] ↔ a[i]; i runs over the part of `a` whose partner exists
                    let lo = max(0, -lag), hi = min(n, b.count - lag)
                    guard hi - lo > 4000 else { continue }
                    var sxy: Float = 0, syy: Float = 0, sxx: Float = 0
                    for i in lo..<hi { let p = xp[i], q = Float(bp[i + lag]); sxy += p * q; syy += q * q; sxx += p * p }
                    guard sxx > 1, syy > 1 else { continue }
                    let c = Double(sxy) / (Double(sxx) * Double(syy)).squareRoot()
                    if best == nil || c > best!.1 { best = (lag, c) }
                }
            }
        }
        return best.map { (lagMs: Double($0.0) / 8, correlation: $0.1) }
    }

    /// The first audio track's compressed bytes, as stored (no decoding).
    static func rawBytes(_ url: URL) async -> [UInt8]? {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .audio).first, let r = try? AVAssetReader(asset: a) else { return nil }
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        r.add(o)
        guard r.startReading() else { return nil }
        var out: [UInt8] = []
        while let sb = o.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb)
            var chunk = [UInt8](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// Whether a stretch of `exported`'s compressed sound appears byte for byte in `source`'s: a stream-copy cut moves the packets and
    /// does not touch them, which decoding two different cuts and comparing their waveforms cannot show reliably. Samples three stretches.
    /// Nil when either file has no sound.
    public static func packetsCopied(from source: URL, into exported: URL) async -> Bool? {
        guard let s = await rawBytes(source), let e = await rawBytes(exported), e.count > 3000, !s.isEmpty else { return nil }
        // Index the source by an 8-byte key at every position that starts with a plausible byte; a plain scan is fast enough at these sizes.
        for fraction in [3, 2] {
            let at = e.count / fraction
            let key = Array(e[at..<min(e.count, at + 48)])
            var i = 0, found = false
            while i + key.count <= s.count {
                if s[i] == key[0], s[i + 1] == key[1], Array(s[i..<(i + key.count)]) == key { found = true; break }
                i += 1
            }
            if !found { if ProcessInfo.processInfo.environment["MACPLAYER_DEBUG_IDENTITY"] != nil { print("   packet check: stretch at \(at) of \(e.count) bytes not found in the source's \(s.count) bytes; first bytes \(key.prefix(8))") }; return false }
        }
        return true
    }
}
