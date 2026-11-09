import AVFoundation
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// The phase-0 prototype: checks the media assumptions of the design with real encoders and decoders.
enum Spike {
    struct Case {
        var name: String
        var spec: SyntheticMedia.Spec
    }

    static func run(workDir: URL) async throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var cases: [Case] = []
        func add(_ name: String, _ f: (inout SyntheticMedia.Spec) -> Void) { var s = SyntheticMedia.Spec(); f(&s); cases.append(Case(name: name, spec: s)) }
        add("h264-mp4-30") { $0.container = .mp4; $0.codec = .h264 }
        add("h264-mov-30") { $0.container = .mov; $0.codec = .h264 }
        add("hevc-mov-30") { $0.container = .mov; $0.codec = .hevc }
        add("hevc-mp4-30") { $0.container = .mp4; $0.codec = .hevc }
        add("h264-m4v-30") { $0.container = .m4v; $0.codec = .h264 }
        add("h264-mp4-2997") { $0.container = .mp4; $0.codec = .h264; $0.frameRate = FrameRate(numerator: 30000, denominator: 1001) }
        add("h264-mp4-60") { $0.container = .mp4; $0.codec = .h264; $0.frameRate = FrameRate(numerator: 60, denominator: 1); $0.keyframeInterval = 120 }
        add("h264-mp4-noaudio") { $0.container = .mp4; $0.codec = .h264; $0.withAudio = false }

        for c in cases {
            print("\n=== \(c.name) ===")
            let ext = c.spec.container.rawValue
            let src = workDir.appendingPathComponent("\(c.name).\(ext)")
            let t0 = Date()
            do { try await SyntheticMedia.generate(to: src, spec: c.spec) } catch { print("  generate FAILED: \(error)"); continue }
            print(String(format: "  generated in %.1fs", Date().timeIntervalSince(t0)))
            let info = try await MediaProbe.probe(url: src)
            let v = info.primaryVideo
            print("  probe: \(v?.codec ?? "-") \(v?.width ?? 0)x\(v?.height ?? 0) \(v?.frameRate?.description ?? "?") vfr=\(v?.isVariableFrameRate ?? false) audio=\(info.audio.first?.codec ?? "none") dur=\(info.duration.seconds)s playable=\(info.isPlayable) exportable=\(info.isExportable)")
            try await checkSeek(src, info: info)
            for mode in [CutMode.exact, .fast] {
                await checkCut(src, info: info, mode: mode, container: c.spec.container, workDir: workDir, name: c.name)
                if c.name == "h264-mp4-2997" { // frames whose real PTS sit before / after the ideal grid
                    await checkCut(src, info: info, mode: mode, container: c.spec.container, workDir: workDir, name: c.name + "-b", frames: (121, 181))
                }
            }
            if c.name == "h264-mp4-2997" { try await checkFrameLocator(src) }
        }
        try await checkPlayerSeek(workDir.appendingPathComponent("h264-mp4-30.mp4"))
    }

    /// Frame-accurate still extraction: ask for frame N, expect barcode N.
    static func checkSeek(_ src: URL, info: MediaInfo) async throws {
        let fr = info.frameRateForStepping
        let probes = [0, 1, 17, 59, 60, 61, 119, 121, 149, 200]
        var bad: [String] = []
        for n in probes {
            // Like the app: locate the frame by its real presentation time (frame centre of the ideal grid), then ask for it.
            let ideal = MediaTime.frameStart(index: Int64(n), frameRate: fr)
            if ideal >= info.duration { continue }
            let centre = ideal + MediaTime(value: Int64(fr.denominator), timescale: fr.numerator * 2)
            guard let located = try await FrameLocator.frame(url: src, at: centre) else { bad.append("asked \(n): no frame"); continue }
            let t = located.time
            do {
                let img = try await FrameGrabber.image(url: src, at: t, accuracy: .exact)
                let got = FrameGrabber.syntheticIndex(of: img)
                if got != n { bad.append("asked \(n) got \(got.map(String.init) ?? "nil")") }
            } catch { bad.append("asked \(n) error \(error.localizedDescription)") }
        }
        print("  seek(exact still): \(bad.isEmpty ? "OK \(probes.count) frames" : "MISMATCH " + bad.joined(separator: "; "))")
    }

    static func checkCut(_ src: URL, info: MediaInfo, mode: CutMode, container: SyntheticMedia.Container, workDir: URL, name: String, frames wanted: (Int64, Int64)? = nil) async {
        let fr = info.frameRateForStepping
        // 2.5 s .. 5.0 s: starts between keyframes (GOP 2-4 s), so a fast cut is expected to be keyframe-bound.
        let startIdx = wanted?.0 ?? Int64((2.5 * fr.framesPerSecond).rounded())
        let endIdx = wanted?.1 ?? Int64((5.0 * fr.framesPerSecond).rounded())
        let span = TimeSpan(start: .frameStart(index: startIdx, frameRate: fr), end: .frameStart(index: endIdx, frameRate: fr))
        let out = workDir.appendingPathComponent("\(name)-cut-\(mode.rawValue).\(container.rawValue)")
        try? FileManager.default.removeItem(at: out)
        let opts = ExportOptions(mode: mode, container: OutputContainer(rawValue: container.rawValue) ?? .mp4,
                                 codec: info.primaryVideo?.codec == "hvc1" ? .hevc : .h264)
        let t0 = Date()
        do {
            try await ClipExporter().export(source: src, spans: [span], to: out, options: opts)
        } catch {
            print("  cut[\(mode.rawValue)]: export FAILED: \(error)")
            return
        }
        let secs = Date().timeIntervalSince(t0)
        do {
            let frames = try await FrameScanner.scanVideo(url: out)
            let idxs = frames.compactMap(\.index)
            let firstIdx = idxs.first.map(String.init) ?? "nil"
            let lastIdx = idxs.last.map(String.init) ?? "nil"
            let contiguous = zip(idxs, idxs.dropFirst()).allSatisfy { $1 == $0 + 1 }
            let first = frames.first?.time.seconds ?? -1
            let outInfo = try await MediaProbe.probe(url: out)
            var syncNote = "no audio"
            if info.hasAudio {
                let onsets = try await FrameScanner.beepOnsets(url: out)
                // The frame carrying index k*fps is the visual cue for beep k; compare their times in the output.
                let fpsInt = Int(fr.framesPerSecond.rounded())
                var diffs: [Double] = []
                for o in onsets {
                    if let f = frames.first(where: { ($0.index ?? -1) % fpsInt == 0 && ($0.index ?? 0) > 0 && abs($0.time.seconds - o.seconds) < 0.5 }) {
                        diffs.append((o.seconds - f.time.seconds) * 1000)
                    }
                }
                let worst = diffs.map(abs).max()
                let frameMs = 1000 / fr.framesPerSecond
                syncNote = diffs.isEmpty ? "no beep/frame pairs (beeps=\(onsets.count))"
                    : String(format: "A/V offset worst %.1f ms (frame=%.1f ms) over %d cues", worst!, frameMs, diffs.count)
            }
            print(String(format: "  cut[%@] asked %lld..%lld -> got first=%@ last=%@ count=%d contiguous=%@ firstPTS=%.3f dur=%.3fs (%@, %.1fs)",
                         mode.rawValue, startIdx, endIdx, firstIdx, lastIdx, frames.count, contiguous ? "yes" : "NO", first,
                         outInfo.duration.seconds, "\(outInfo.primaryVideo?.codec ?? "-")/\(outInfo.audio.first?.codec ?? "none")", secs))
            print("            \(syncNote)")
        } catch {
            print("  cut[\(mode.rawValue)]: verify FAILED: \(error)")
        }
    }

    /// Real PTS from the sample table must agree with what decoding reports.
    static func checkFrameLocator(_ src: URL) async throws {
        let frames = try await FrameScanner.scanVideo(url: src)
        var bad: [String] = []
        for n in [0, 1, 121, 149, 200] {
            guard let truth = frames.first(where: { $0.index == n }) else { continue }
            let near = MediaTime(value: truth.time.value + 1, timescale: truth.time.timescale)
            if let f = try await FrameLocator.frame(url: src, at: near), f.time != truth.time { bad.append("frame \(n): locator \(f.time.seconds) vs decoded \(truth.time.seconds)") }
        }
        let a = try await FrameLocator.step(url: src, from: frames[10].time, by: 3)
        if a != frames[13].time { bad.append("step +3 from frame 10 gave \(String(describing: a?.seconds)) expected \(frames[13].time.seconds)") }
        let b = try await FrameLocator.step(url: src, from: frames[10].time, by: -4)
        if b != frames[6].time { bad.append("step -4 from frame 10 gave \(String(describing: b?.seconds)) expected \(frames[6].time.seconds)") }
        print("  FrameLocator (real PTS vs decoded, step +/-): \(bad.isEmpty ? "OK" : "MISMATCH " + bad.joined(separator: "; "))")
    }

    /// AVPlayer seeking with zero tolerance: what the on-screen preview will show.
    static func checkPlayerSeek(_ src: URL) async throws {
        let item = AVPlayerItem(url: src)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        let player = AVPlayer(playerItem: item)
        var bad: [String] = []
        let targets = [0, 45, 90, 150, 211]
        for n in targets {
            let t = CMTime(value: CMTimeValue(n), timescale: 30)
            let t0 = Date()
            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            var got: Int?
            for _ in 0..<40 {
                if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                    got = SyntheticMedia.decodeIndex(from: pb); break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            if got != n { bad.append("asked \(n) got \(got.map(String.init) ?? "nil")") }
            print(String(format: "  player seek %d -> %@ (%.0f ms)", n, got.map(String.init) ?? "nil", ms))
        }
        print("\n  player zero-tolerance seek: \(bad.isEmpty ? "OK" : "MISMATCH " + bad.joined(separator: "; "))")
    }
}
