import Foundation

public enum SoundKind: String, Codable, CaseIterable, Sendable { case music, voice, effect }

/// A sound laid on the timeline next to the video's own: background music, a voice-over, a sound effect.
public struct SoundClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var kind: SoundKind
    /// Where it starts on the timeline, and which part of the file plays (from `sourceStart`, for `duration`).
    public var start: MediaTime
    public var sourceStart: MediaTime
    public var duration: MediaTime
    public var gainDB: Double
    public var fadeIn: Double
    public var fadeOut: Double
    public var muted: Bool
    /// Music only: turns down by `duckDepthDB` while someone speaks (the video's own sound or a voice-over).
    public var ducking: Bool
    public var duckDepthDB: Double
    /// Noise reduction strength 0...1 (nil = off).
    public var denoise: Double?
    /// How long the whole file is (for the length control; the builder reads the real file).
    public var fileDuration: MediaTime?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil, kind: SoundKind = .music, start: MediaTime, sourceStart: MediaTime = .zero,
                duration: MediaTime, gainDB: Double = 0, fadeIn: Double = 0, fadeOut: Double = 0, muted: Bool = false, ducking: Bool = false, duckDepthDB: Double = -14, denoise: Double? = nil, fileDuration: MediaTime? = nil) {
        self.fileDuration = fileDuration
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark; self.kind = kind; self.start = start; self.sourceStart = sourceStart
        self.duration = duration; self.gainDB = gainDB; self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.muted = muted; self.ducking = ducking
        self.duckDepthDB = duckDepthDB; self.denoise = denoise
    }

    public var end: MediaTime { start + duration }

    /// The part of this sound that plays during `span` of the timeline, placed as it will be in a file that starts at `span.start` (and goes on at
    /// `speed`). Nil when it does not reach into the span. A new id keeps the copies made for several exports apart.
    public func cropped(to span: TimeSpan, speed: Double = 1, offset: MediaTime = .zero) -> SoundClip? {
        let a = max(start, span.start), b = min(end, span.end)
        guard b > a else { return nil }
        var n = self
        let k = speed > 0 ? speed : 1
        n.sourceStart = sourceStart + (a - start)
        n.start = offset + MediaTime(seconds: (a - span.start).seconds / k, timescale: 6000)
        n.duration = MediaTime(seconds: (b - a).seconds / k, timescale: 6000)
        // A fade belongs to the sound's own start and end: it stays only where the sound still starts or ends there.
        if a > start { n.fadeIn = 0 }
        if b < end { n.fadeOut = 0 }
        return n
    }
}

extension Project {
    /// All the sounds on the timeline (stored only when there are some, so older projects are unchanged).
    public var soundClips: [SoundClip] {
        get { soundClipStore ?? [] }
        set { soundClipStore = newValue.isEmpty ? nil : newValue }
    }
}

/// Finding when someone speaks in a sound, from how loud each short stretch is.
public enum SpeechDetector {
    /// `rms`: the loudness of consecutive frames of `frameSeconds` each. Returns (start, end) in seconds. Nothing in silence, and nothing in a sound
    /// that is just as loud all the way through (there is nothing to tell speech from).
    public static func ranges(rms: [Float], frameSeconds: Double, pad: (before: Double, after: Double) = (0.1, 0.2), minSpeech: Double = 0.2, mergeGap: Double = 0.4) -> [(start: Double, end: Double)] {
        guard rms.count > 3 else { return [] }
        let sorted = rms.sorted()
        func pct(_ p: Double) -> Float { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let floorLevel = pct(0.2), high = pct(0.95)
        guard high > 0.002 else { return [] }
        let threshold = max(floorLevel * 3, high * 0.22, 0.0015)
        var runs: [(Int, Int)] = []
        var i = 0
        while i < rms.count {
            if rms[i] > threshold {
                var j = i
                while j + 1 < rms.count, rms[j + 1] > threshold { j += 1 }
                runs.append((i, j)); i = j + 1
            } else { i += 1 }
        }
        var merged: [(Int, Int)] = []
        let gapFrames = Int((mergeGap / frameSeconds).rounded())
        for r in runs {
            if let last = merged.last, r.0 - last.1 - 1 <= gapFrames { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        let total = Double(rms.count) * frameSeconds
        return merged.compactMap { r in
            let a = Double(r.0) * frameSeconds, b = Double(r.1 + 1) * frameSeconds
            guard b - a >= minSpeech else { return nil }
            return (max(0, a - pad.before), min(total, b + pad.after))
        }
    }
}

/// How loud a sound is, and the gain that brings it to a comfortable level.
public enum LoudnessMatch {
    /// Gain (dB) that brings a sound with the given average and peak level (dBFS) to `target` on average without the peak going past `ceiling`.
    public static func gainDB(averageDB: Double, peakDB: Double, target: Double = -18, ceiling: Double = -1) -> Double {
        guard averageDB.isFinite, peakDB.isFinite else { return 0 }
        return min(max(min(target - averageDB, ceiling - peakDB), -24), 24)
    }
}
