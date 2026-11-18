import AVFoundation
import CoreImage
import Foundation
import MacPlayerCore
import Vision

/// Measures what `HighlightFinder` scores (0.22), on this Mac only: the picture read small every `step` seconds (how much it changes), people
/// looked for with Vision every `peopleEvery` seconds (how much of the picture they fill and how fast they move), and the sound's level.
public enum HighlightAnalyzer {
    /// For tests: replaces Vision (synthetic pictures have no people). Given a frame, returns boxes (0…1, top-left origin).
    nonisolated(unsafe) public static var detector: ((CVPixelBuffer) -> [CGRect])?

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
        func set() { lock.lock(); v = true; lock.unlock() }
    }
    private final class Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    /// `span`: source seconds to look at. `progress` gets 0…1 (from a background thread).
    public static func signals(url: URL, span: TimeSpan, step: Double = 0.2, peopleEvery: Double = 1.0, readEvery: Double = 10, longSide: CGFloat = 960,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> HighlightSignals {
        let asset = AVURLAsset(url: url)
        let start = span.start.seconds, length = span.duration.seconds
        guard length > step * 3, let track = try await asset.loadTracks(withMediaType: .video).first else {
            return HighlightSignals(start: start, step: step, motion: [])
        }
        let (natural, pt) = try await track.load(.naturalSize, .preferredTransform)
        let total = try await asset.load(.duration)
        let rect = CGRect(origin: .zero, size: natural).applying(pt)
        let upright = CGSize(width: abs(rect.width), height: abs(rect.height))
        let k = min(1, longSide / max(upright.width, upright.height, 1))
        let size = CGSize(width: max(16, (upright.width * k / 2).rounded() * 2), height: max(16, (upright.height * k / 2).rounded() * 2))
        let comp = AVMutableVideoComposition()
        comp.renderSize = size
        comp.frameDuration = CMTime(seconds: step, preferredTimescale: 600)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(pt.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)).concatenating(CGAffineTransform(scaleX: k, y: k)), at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        // Never past the file's end: a clip's end rounded to its time scale can lie a hair after it (5171.5017 against 5171.501 s), and a
        // reader asked to read past the end of its video composition refuses to start at all (-11841).
        let range = CMTimeRange(start: min(span.start.cmTime, total), end: min(span.end.cmTime, total))
        guard range.duration.seconds > step * 3 else { return HighlightSignals(start: start, step: step, motion: []) }
        let cancelled = Flag()
        let box = Box((asset, track, comp))
        let video: (motion: [Double], people: [Double?], speed: [Double], goals: [ScoreChange], thumbs: [[UInt8]], periods: [MatchPeriod], marks: [WordMark]) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Reading blocks its thread: its own, never the shared pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let (asset, track, comp) = box.value
                        let reader = try AVAssetReader(asset: asset)
                        reader.timeRange = range
                        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                        out.videoComposition = comp
                        out.alwaysCopiesSampleData = false
                        reader.add(out)
                        guard reader.startReading() else { throw reader.error ?? MediaProbeError.unreadable("video") }
                        var motion: [Double] = [], people: [Double?] = [], speed: [Double] = []
                        var prev: [UInt8]? = nil
                        var lastLook = -Double.infinity
                        var lastCenter: (x: Double, y: Double, t: Double)? = nil
                        var board = ScoreReader()
                        var watch = BoardWatch()
                        var clock = ClockReader()
                        var spotter = WordSpotter()
                        var thumbs: [[UInt8]] = []
                        var lastRead = -Double.infinity
                        while let sb = out.copyNextSampleBuffer() {
                            if cancelled.isSet { reader.cancelReading(); throw CancellationError() }
                            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                            let luma = grid(pb)
                            if let p = prev, p.count == luma.count {
                                var d = 0; for i in luma.indices { d += abs(Int(luma[i]) - Int(p[i])) }
                                motion.append(Double(d) / Double(luma.count) / 255)
                            } else { motion.append(0) }
                            prev = luma
                            thumbs.append(thumb(pb))
                            // The scoreboard's words, every few seconds (Vision reads its digits at about 960 px, not at 512).
                            if t - lastRead >= readEvery - step / 2 {
                                lastRead = t
                                let boxes = wordBoxes(pb)
                                let w = boxes.map { (text: $0.text, x: $0.box.midX, y: $0.box.midY) }
                                board.add(w, at: t); clock.add(w, at: t); spotter.add(w, at: t)
                                watch.add(boxes, at: t) { grid(pb, in: $0, cols: $1, rows: $2) }
                            }
                            if t - lastLook >= peopleEvery - step / 2 {
                                lastLook = t
                                let boxes = detector?(pb) ?? bodies(pb)
                                people.append(boxes.reduce(0) { $0 + Double($1.width * $1.height) })
                                if let c = PersonTracker.center(of: boxes) {
                                    if let l = lastCenter, t > l.t { speed.append(hypot(c.x - l.x, c.y - l.y) / (t - l.t)) } else { speed.append(0) }
                                    lastCenter = (c.x, c.y, t)
                                } else { speed.append(0); lastCenter = nil }
                            } else {
                                people.append(nil)
                                speed.append(speed.last ?? 0)
                            }
                            progress?(min(1, max(0, (t - range.start.seconds) / max(0.001, length))) * 0.9)
                        }
                        if reader.status == .failed { throw reader.error ?? MediaProbeError.unreadable("video") }
                        // Goals: the score read as text; else (its digits alone in boxes text recognition leaves out) the boxes seen to change,
                        // counted from 0-0 when the video shows the first kick-off.
                        let periods = clock.periods()
                        var goals = board.changes()
                        if goals.isEmpty { goals = watch.goals(fromNil: periods.first?.kickoffSeen ?? false) }
                        cont.resume(returning: (motion, people, speed, goals, thumbs, periods, spotter.events.map { WordMark(kind: $0.kind, time: $0.time) }))
                    } catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { cancelled.set() }
        try Task.checkCancellation()

        // The sound, as dB per sample.
        var loud: [Double] = [], peaks: [Double] = []
        if let r = try? await AudioAnalysis.levels(asset: asset, range: range, frameSeconds: 0.05), !r.frames.isEmpty {
            let per = max(1, Int((step / 0.05).rounded()))
            peaks = (0..<video.motion.count).map { i in
                let a = min(r.peaks.count, i * per), b = min(r.peaks.count, a + per)
                return b > a ? 20 * log10(Double(max(r.peaks[a..<b].max() ?? 0, 1e-4))) : -80
            }
            loud = (0..<video.motion.count).map { i in
                let a = min(r.frames.count, i * per), b = min(r.frames.count, a + per)
                guard b > a else { return -80 }
                let mean = r.frames[a..<b].reduce(0) { $0 + Double($1) } / Double(b - a)
                return 20 * log10(max(mean, 1e-4))
            }
        }
        var signals = HighlightSignals(start: start, step: step, motion: video.motion, loudness: loud, people: video.people, personSpeed: video.speed,
                                goals: video.goals, thumbs: video.thumbs)
        signals.periods = video.periods; signals.marks = video.marks; signals.peaks = peaks
        // Before the first kick-off, a closer look for teams lined up (a second, short pass).
        if let first = video.periods.first {
            var times: [Double] = []
            // Only where it can be: before a kick-off the video shows.
            var t = max(range.start.seconds, first.kickoff - 600)
            while first.kickoffSeen && t < first.kickoff - 10 { times.append(t); t += 2 }
            signals.lineups = try await lineups(asset: asset, at: times)
        }
        // Each set piece looked at closely while it is set up (0.22.5): how many people are in the picture.
        signals.kickCrowd = try await crowds(asset: asset, at: HighlightFinder.setPieceKicks(signals))
        progress?(1)
        return signals
    }

    /// Brightness on a grid of about 64 across (green as brightness is enough to see change).
    static func grid(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let stride = max(1, w / 64)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity((w / stride + 1) * (h / stride + 1))
        var y = stride / 2
        while y < h { var x = stride / 2; while x < w { out.append(p[y * row + x * 4 + 1]); x += stride }; y += stride }
        return out
    }

    /// A tiny colour picture of the frame (16 × 9, RGB): enough to know a graphic seen again (a replay's opening animation).
    static func thumb(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](); out.reserveCapacity(16 * 9 * 3)
        for by in 0..<9 { for bx in 0..<16 {
            var r = 0, g = 0, b = 0
            for sy in 0..<4 { for sx in 0..<4 {
                let x = (bx * 4 + sx) * w / 64 + w / 128, y = (by * 4 + sy) * h / 36 + h / 72
                let o = min(h - 1, y) * row + min(w - 1, x) * 4
                b += Int(p[o]); g += Int(p[o + 1]); r += Int(p[o + 2])
            } }
            out += [UInt8(r / 16), UInt8(g / 16), UInt8(b / 16)]
        } }
        return out
    }

    /// For tests: replaces text recognition. Given a frame, returns words and their middles (0…1, top-left origin).
    nonisolated(unsafe) public static var reader: ((CVPixelBuffer) -> [(text: String, x: Double, y: Double)])?

    /// The words on the picture with their frames (0…1, top-left origin).
    static func wordBoxes(_ pb: CVPixelBuffer) -> [(text: String, box: TextFrame)] {
        if let r = reader { return r(pb).map { ($0.text, TextFrame(x: $0.x - 0.02, y: $0.y - 0.01, width: 0.04, height: 0.02)) } }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            o.topCandidates(1).first.map { ($0.string, TextFrame(x: Double(o.boundingBox.minX), y: 1 - Double(o.boundingBox.maxY),
                                                                 width: Double(o.boundingBox.width), height: Double(o.boundingBox.height))) }
        }
    }

    /// A small picture (`cols` × `rows` brightness values) of a part of the frame (0…1, top-left origin).
    static func grid(_ pb: CVPixelBuffer, in r: TextFrame, cols: Int = 12, rows: Int = 16) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](); out.reserveCapacity(cols * rows)
        for gy in 0..<rows { for gx in 0..<cols {
            var sum = 0, n = 0
            for sy in 0..<2 { for sx in 0..<2 {
                let fx = r.x + r.width * (Double(gx) + (Double(sx) + 0.5) / 2) / Double(cols), fy = r.y + r.height * (Double(gy) + (Double(sy) + 0.5) / 2) / Double(rows)
                let x = min(w - 1, max(0, Int(fx * Double(w)))), y = min(h - 1, max(0, Int(fy * Double(h))))
                let o = y * row + x * 4
                sum += (Int(p[o + 2]) * 30 + Int(p[o + 1]) * 59 + Int(p[o]) * 11) / 100; n += 1
            } }
            out.append(UInt8(sum / max(1, n)))
        } }
        return out
    }

    /// The words on the picture and where (middle, 0…1 from the top-left).
    static func words(_ pb: CVPixelBuffer) -> [(text: String, x: Double, y: Double)] {
        if let r = reader { return r(pb) }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            o.topCandidates(1).first.map { ($0.string, Double(o.boundingBox.midX), 1 - Double(o.boundingBox.midY)) }
        }
    }

    /// For tests: replaces the row count. Given a frame, returns how many people stand in one row.
    nonisolated(unsafe) public static var rowCounter: ((CGImage) -> Int)?

    /// The times among `times` when at least `atLeast` people stand in a row. Small people far off are found by looking at six
    /// overlapping parts of a 960 px picture (the whole picture at once finds none of a lined-up team at night).
    static func lineups(asset: AVAsset, at times: [Double], atLeast: Int = 7) async throws -> [Double] {
        guard !times.isEmpty else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [Double] = []
        for t in times {
            try Task.checkCancellation()
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            if (rowCounter?(img) ?? rowCount(img)) >= atLeast { out.append(t) }
        }
        return out
    }

    /// For tests: replaces the people count of a set piece.
    nonisolated(unsafe) public static var crowdCounter: ((CGImage) -> Int)?

    /// How many people are in the picture 3 s and 1.5 s before each kick (the more of the two), by kick time.
    static func crowds(asset: AVAsset, at kicks: [Double]) async throws -> [Double: Int] {
        guard !kicks.isEmpty else { return [:] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var out: [Double: Int] = [:]
        for k in kicks {
            try Task.checkCancellation()
            var most = 0
            for t in [k - 3, k - 1.5] {
                guard let img = try? await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image else { continue }
                most = max(most, crowdCounter?(img) ?? people(img).count)
            }
            out[k] = most
        }
        return out
    }

    static func rowCount(_ img: CGImage) -> Int {
        peopleInARow(feet: people(img).map { Double($0.maxY) })
    }

    /// The people in a picture, small ones far off too: Vision looks at six overlapping parts of it. Boxes 0…1 from the top-left.
    static func people(_ img: CGImage) -> [CGRect] {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        var boxes: [CGRect] = []
        for ty in 0..<2 { for tx in 0..<3 {
            let part = CGRect(x: CGFloat(tx) * w / 3, y: CGFloat(ty) * h / 2, width: w / 3 + w / 12, height: h / 2 + h / 8).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
            guard let crop = img.cropping(to: part) else { continue }
            let req = VNDetectHumanRectanglesRequest()
            req.upperBodyOnly = false
            try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
            for o in req.results ?? [] where o.confidence > 0.3 {
                let b = o.boundingBox
                let r = CGRect(x: (part.minX + b.minX * part.width) / w, y: (part.minY + (1 - b.maxY) * part.height) / h,
                               width: b.width * part.width / w, height: b.height * part.height / h)
                // Parts overlap: the same person found twice counts once.
                if !boxes.contains(where: { let i = $0.intersection(r); return i.width * i.height > 0.5 * r.width * r.height }) { boxes.append(r) }
            }
        } }
        return boxes
    }

    /// Whole bodies found by Vision, 0…1 from the top-left.
    static func bodies(_ pb: CVPixelBuffer) -> [CGRect] {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.3 }.map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
    }
}
