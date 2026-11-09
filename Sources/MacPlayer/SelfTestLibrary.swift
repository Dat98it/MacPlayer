import AppKit
import AVFoundation
import CryptoKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// `--selftest <dir> --library <folder> [--real-only]`: the full flow, in the real app, on a folder of the user's own footage.
/// Everything runs on the files in <folder> (which the caller makes a copy of); exports go to a scratch folder and are deleted.
/// Checks are made against the file itself (its own frame table, pixels and sound), because real footage has no barcode.
@MainActor
extension SelfTest {
    // MARK: Helpers

    static func sha256(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "?" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The picture's size as it is displayed (rotation applied), read straight from the track, not through MacPlayer's own probe.
    static func displaySize(_ url: URL) async -> CGSize {
        guard let t = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let n = try? await t.load(.naturalSize), let x = try? await t.load(.preferredTransform) else { return .zero }
        let r = CGRect(origin: .zero, size: n).applying(x).standardized
        return CGSize(width: r.width.rounded(), height: r.height.rounded())
    }

    /// A small grey thumbnail of the frame at a time, for "is it black" and "did it change" questions.
    static func thumb(_ url: URL, at seconds: Double) async -> [Float]? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600); g.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        g.maximumSize = CGSize(width: 256, height: 256)
        guard let img = try? await g.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        let n = 48
        var px = [UInt8](repeating: 0, count: n * n)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n)); return true
        }
        return ok ? px.map(Float.init) : nil
    }
    static func meanOf(_ a: [Float]) -> Double { a.isEmpty ? 0 : a.reduce(0.0) { $0 + Double($1) } / Double(a.count) }
    static func mad(_ a: [Float], _ b: [Float]) -> Double { a.count == b.count && !a.isEmpty ? { let ma = meanOf(a), mb = meanOf(b); return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - ma - (Double($1.1) - mb)) } / Double(a.count) }() : .nan }


    /// Presentation times (as the player shows them: edit list applied) of the frames within `radius` seconds of a time.
    static func windowTimes(_ url: URL, around t: Double, radius: Double) async -> [CMTime] {
        let a = AVURLAsset(url: url)
        guard let tr = try? await a.loadTracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: a) else { return [] }
        r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t - radius), preferredTimescale: 60000), duration: CMTime(seconds: radius * 2, preferredTimescale: 60000))
        let o = AVAssetReaderTrackOutput(track: tr, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        o.alwaysCopiesSampleData = false
        r.add(o); r.startReading()
        var out: [CMTime] = []
        while let sb = o.copyNextSampleBuffer() { let p = CMSampleBufferGetPresentationTimeStamp(sb); if p.isNumeric { out.append(p) } }
        return out.sorted { $0.seconds < $1.seconds }
    }

    /// The picture of exactly one frame, upright, as a small grey thumbnail. Nil if the system cannot decode that frame on its own.
    static func thumbExact(_ url: URL, at time: CMTime, mirrored: Bool = false) async -> [Float]? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        g.maximumSize = CGSize(width: 256, height: 256)
        guard let img = try? await g.image(at: time).image else { return nil }
        let n = 48
        var px = [UInt8](repeating: 0, count: n * n)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            if mirrored { ctx.translateBy(x: CGFloat(n), y: 0); ctx.scaleBy(x: -1, y: 1) }          // mirrored before it is scaled down, so the pixels line up exactly
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n)); return true
        }
        return ok ? px.map(Float.init) : nil
    }

    /// Which frame of the source an exported frame is, among the source frames near the one it should be: the shift (in frames) of the
    /// best match from the expected one. `still` when the neighbours look alike and the picture cannot tell; nil when nothing can be read.
    static func frameShift(source: URL, times: [CMTime], expectedIndex d: Int, exported: [Float]) async -> (shift: Int, still: Bool)? {
        guard d >= 0, d < times.count else { return nil }
        var scores: [(Int, Double)] = []
        for k in max(0, d - 3)...min(times.count - 1, d + 3) {
            if let th = await thumbExact(source, at: times[k]) { scores.append((k - d, mad(th, exported))) }
        }
        if ProcessInfo.processInfo.environment["MACPLAYER_DEBUG_IDENTITY"] != nil { print("   identity scores (shift: difference): \(scores.map { "\($0.0): \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))") }
        guard let best = scores.min(by: { $0.1 < $1.1 }), let atExpected = scores.first(where: { $0.0 == 0 }) else { return nil }
        let spread = (scores.map(\.1).max() ?? 0) - best.1
        if spread < 0.4 { return (0, true) }
        return (atExpected.1 <= best.1 + 0.15 ? 0 : best.0, false)
    }

    /// Runs one export through the real queue and waits for it. Returns the output path when it succeeded.
    static func runExport(_ s: EditorSession, env: AppEnvironment, _ request: ExportRequest, timeout: Double = 300) async -> (path: String?, message: String) {
        guard let (jobs, _) = try? s.planExport(request) else { return (nil, "plan refused") }
        env.exports.enqueue(jobs); await waitForQueue(env, timeout: timeout)
        guard let job = env.exports.queue.jobs.first(where: { $0.id == jobs[0].id }) else { return (nil, "job vanished") }
        if case .succeeded = job.state { return (job.outputPath, "ok") }
        return (nil, "\(job.state)")
    }

    // MARK: The per-file flow

    static func libraryFlow(env: AppEnvironment, work: URL, library: URL, app: AppDelegate) async {
        print("== L: your own videos, in the real app")
        app.quitWhenLastWindowCloses = false
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []).filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        print("\(files.count) files in the library")
        var infos: [(url: URL, info: MediaInfo)] = []

        let mixedOnly = ProcessInfo.processInfo.environment["MACPLAYER_LIBRARY_ONLY"] == "mixed"
        for url in files {
            let name = url.lastPathComponent
            if mixedOnly { if let i = try? await MediaProbe.probe(url: url) { infos.append((url, i)) }; continue }
            print("-- \(name)")
            let dir = work.appendingPathComponent("lib-\(UUID().uuidString.prefix(6))"); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let before = sha256(url)
            guard let s = try? await EditorSession.open(url: url) else { check(false, "open \(name)"); continue }
            guard let v = s.info?.primaryVideo else { check(false, "\(name) has a video track"); s.close(discardRecovery: true); continue }
            infos.append((url, s.info!))
            let hasAudio = !(s.info?.audio.isEmpty ?? true)
            let table = await RealCheckLite.frameTimes(url)
            let disp = await displaySize(url)
            let assetDuration = ((try? await AVURLAsset(url: url).load(.duration))?.seconds) ?? 0
            check(abs(s.duration.seconds - assetDuration) < 0.1, "opened: \(String(format: "%.1f", s.duration.seconds)) s (the file says \(String(format: "%.1f", assetDuration)) s), \(table.count) samples, \(String(format: "%.2f", s.frameRate.framesPerSecond)) fps")
            check(Int(disp.width) == v.width && Int(disp.height) == v.height, "the picture is read upright: \(v.width)×\(v.height) (rotation \(v.rotation)°, track says \(Int(disp.width))×\(Int(disp.height)))")

            // Play
            s.player.play(); try? await Task.sleep(nanoseconds: 600_000_000)
            let t0 = s.player.currentTime.seconds
            if s.duration.seconds > 3 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let rate = (s.player.currentTime.seconds - t0) / 1.5
                check(rate > 0.9 && rate < 1.1, "plays at normal speed (\(String(format: "%.2f", rate)))")
            }
            s.player.pause()

            // Exact seek and single steps, by the file's own frame table
            guard table.count > 40, let a = try? await FrameLocator.frame(url: url, at: MediaTime(seconds: s.duration.seconds * 0.3)) else { check(false, "frame table"); s.close(discardRecovery: true); continue }
            await s.player.seek(to: a.time)
            check(abs(s.player.currentTime.seconds - a.time.seconds) < 0.0005, "exact seek lands on the frame time (\(s.player.currentTime.seconds) vs \(a.time.seconds))")
            let shown = await windowTimes(url, around: a.time.seconds, radius: 0.4)       // the frames as the player shows them
            func shownIndex(_ t: Double) -> Int? { shown.lastIndex { $0.seconds <= t + 0.0002 } }
            let d0 = shownIndex(s.player.currentTime.seconds)
            let next = try? await FrameLocator.step(url: url, from: a.time, by: 1)
            s.player.step(frames: 1); try? await Task.sleep(nanoseconds: 900_000_000)
            let d1 = shownIndex(s.player.currentTime.seconds)
            check(next != nil && abs(s.player.currentTime.seconds - next!.seconds) < 0.0005, "one frame forward")
            check(d0 != nil && d1 != nil && d1! - d0! == 1, "and it is exactly one frame of the picture shown (frame \(d0 ?? -1) → \(d1 ?? -1))")
            s.player.step(frames: -1); try? await Task.sleep(nanoseconds: 900_000_000)
            check(abs(s.player.currentTime.seconds - a.time.seconds) < 0.0005, "one frame back")
            check(shownIndex(s.player.currentTime.seconds) == d0, "and it is the same frame as before")
            s.player.step(frames: 5); try? await Task.sleep(nanoseconds: 900_000_000)
            let d5 = shownIndex(s.player.currentTime.seconds)
            check(d0 != nil && d5 != nil && d5! - d0! == 5, "five frames forward shows five frames later (frame \(d0 ?? -1) → \(d5 ?? -1))")
            s.player.step(frames: -5); try? await Task.sleep(nanoseconds: 900_000_000)

            // A cut of up to 120 frames, exact and fast
            let count = min(120, max(10, Int(Double(table.count) * 0.3)))
            guard let b = try? await FrameLocator.step(url: url, from: a.time, by: count) else { check(false, "end of span"); s.close(discardRecovery: true); continue }
            let spanSeconds = b.seconds - a.time.seconds
            s.inPoint = a.time; s.outPoint = b
            s.addClipFromInOut(name: "Cut")
            let srcSound = hasAudio ? await AudioEnvelope.read(url, from: a.time.cmTime, duration: spanSeconds) : nil
            let srcWave = hasAudio ? await AudioEnvelope.loadSamples(url, from: a.time.cmTime, duration: spanSeconds) : nil
            for (mode, edited) in [(CutMode.exact, false), (.fast, false), (.exact, true)] {
                if edited { s.edit("mirror") { $0.look.flipHorizontal = true } }          // a mirrored picture goes through the compositor, which has its own frame grid; the pixels are only moved, so frames can still be told apart
                defer { if edited { s.undo() } }
                let label = edited ? "\(mode) cut of a mirrored picture" : "\(mode) cut"
                let outDir = dir.appendingPathComponent("out-\(mode)"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
                let res = await runExport(s, env: env, ExportRequest(scope: .allClips, saveKind: .newCopy, options: ExportOptions(mode: mode), folder: outDir.path, baseName: nil))
                guard let path = res.path else { check(false, "\(label) export of \(name): \(res.message)"); continue }
                let out = URL(fileURLWithPath: path)
                let times = await decodedTimes(out)
                let oi = try? await MediaProbe.probe(url: out)
                let od = await displaySize(out)
                let outWave = hasAudio ? await AudioEnvelope.loadSamples(out) : nil
                let vfr = v.isVariableFrameRate
                let outFps = oi?.primaryVideo?.frameRate?.framesPerSecond ?? s.frameRate.framesPerSecond
                let expected = (mode == .exact && vfr) ? Int((spanSeconds * outFps).rounded()) : count
                let countOK = (vfr && (mode == .exact || edited)) ? abs(Double(times.count) / outFps - spanSeconds) <= 2.5 / outFps + 0.02 : abs(times.count - expected) <= (mode == .exact && vfr ? 1 : 0)
                check(countOK && abs(times.first ?? 9) < 1 / max(1, outFps) + 0.001,
                      "\(label): \(times.count) frames (wanted \(expected)), from \(String(format: "%.3f", times.first ?? -1)) s")
                check(od == disp, "\(label) keeps the picture upright and the same size (\(Int(od.width))×\(Int(od.height)))")
                if v.isHDR { check(oi?.primaryVideo?.isHDR == true, "\(label) stays HDR (\(oi?.primaryVideo?.transferFunction ?? "?"))") }
                if hasAudio {
                    if let so = await AudioEnvelope.read(out), let sa = srcSound {
                        let lenDiff = (so.seconds - sa.seconds) * 1000
                        let frameMs = 1000 / max(1, s.frameRate.framesPerSecond)         // a cut puts its edges half a frame inside the span on each side (CutPlanning.guarded)
                        let wave: (lagMs: Double, correlation: Double)? = {
                            guard let a = srcWave, let b = outWave else { return nil }
                            return AudioEnvelope.alignWaveforms(a, b, maxLagMs: 150)
                        }()
                        // A stream-copy (fast) cut moves the sound's packets without touching them: that is checked on the bytes. A re-encoded cut is checked on the waveform.
                        let copied: Bool? = mode == .fast && !edited ? await AudioEnvelope.packetsCopied(from: url, into: out) : nil
                        let ok = abs(lenDiff) <= 1.5 * frameMs + 20 && (mode == .fast && !edited ? ((copied ?? true) || wave == nil || (abs(wave!.lagMs) <= frameMs + 5 && wave!.correlation >= 0.6)) : (wave == nil || (abs(wave!.lagMs) <= frameMs + 5 && wave!.correlation >= 0.4)))
                        check(ok, "\(label) sound: \(String(format: "%.2f", so.seconds)) s for a \(String(format: "%.2f", sa.seconds)) s span (\(String(format: "%+.0f", lenDiff)) ms), \(wave.map { "shifted \(String(format: "%+.1f", $0.lagMs)) ms (a frame is \(String(format: "%.1f", frameMs)) ms), waveform match \(String(format: "%.2f", $0.correlation))" } ?? "silent")\(copied.map { $0 ? ", the sound packets are copied byte for byte" : ", the sound packets are NOT a copy" } ?? "")")
                    } else { check(false, "\(label) kept the sound") }
                } else { check(oi?.audio.isEmpty ?? true, "\(label) of a silent video stays silent") }
                // The first and last frame of the file are the frames of the source that the cut named (the one the player shows at the In point,
                // and the one at the last frame before Out), not their neighbours: this is what "frame accurate" means on footage with a shifted edit list.
                if !edited, let t0 = times.first, let t1 = times.last, let outInfo = try? await RealCheckLite.frameTimes(out), outInfo.count > 2,
                   let f0 = await thumbExact(out, at: CMTime(seconds: t0, preferredTimescale: 60000), mirrored: edited), let f1 = await thumbExact(out, at: CMTime(seconds: t1, preferredTimescale: 60000), mirrored: edited) {
                    // Expected: the frames of the picture the player shows from the In point on, in order. Frame k of the file is source frame D + k.
                    let span = await windowTimes(url, around: a.time.seconds + spanSeconds / 2, radius: spanSeconds / 2 + 0.2)
                    let dIn = span.lastIndex { $0.seconds <= a.time.seconds + 0.0002 } ?? 0
                    let first = await frameShift(source: url, times: span, expectedIndex: dIn, exported: f0)
                    let last = (dIn + times.count - 1 < span.count) ? await frameShift(source: url, times: span, expectedIndex: dIn + times.count - 1, exported: f1) : nil
                    func say(_ r: (shift: Int, still: Bool)?) -> String { r.map { $0.still ? "picture too still to tell" : "\($0.shift) frames off" } ?? "not readable" }
                    let slack = 0         // the compositor re-draws every frame (about 3/255 of error), so at 60 fps or on a re-timed VFR file neighbouring frames cannot be told apart that closely
                    check(first == nil || first!.still || abs(first!.shift) <= slack, "\(label): its first frame is the frame at the In point (\(say(first)))")
                    check(last == nil || last!.still || abs(last!.shift) <= slack, "\(label): its last frame is source frame #\(times.count) from the In point (\(say(last)))")
                }
                try? fm.removeItem(at: outDir)
            }
            check(sha256(url) == before, "source untouched, byte for byte")

            // Project: save and reopen
            s.makeProject(fromClips: true)
            let projPath = dir.appendingPathComponent("real.macplayer").path
            s.saveProject(to: projPath)
            if let p = try? await EditorSession.openProject(path: projPath) {
                check(p.isProject && p.project.timeline.count == 1 && abs(p.duration.seconds - spanSeconds) < 0.1, "project saved and reopened (\(p.project.timeline.count) clip, \(String(format: "%.2f", p.duration.seconds)) s)")
                p.close(discardRecovery: true)
            } else { check(false, "reopen project") }
            s.close(discardRecovery: true)

            // Replace the original (a copy of it) with the cut, keeping a backup
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size < 120_000_000 {
                let victim = dir.appendingPathComponent("victim-\(name)"); try? fm.copyItem(at: url, to: victim)
                if let r = try? await EditorSession.open(url: victim) {
                    r.inPoint = a.time; r.outPoint = b
                    if let (jobs, _) = try? r.planExport(ExportRequest(scope: .inOut, saveKind: .replaceOriginal, options: ExportOptions(mode: .exact, container: url.pathExtension.lowercased() == "mov" ? .mov : .mp4), folder: dir.path, baseName: nil)) {
                        env.exports.enqueue(jobs); await waitForQueue(env, timeout: 300)
                        let t = await decodedTimes(victim)
                        let vi = try? await MediaProbe.probe(url: victim)
                        let rfps = vi?.primaryVideo?.frameRate?.framesPerSecond ?? 30
                        let wanted = v.isVariableFrameRate ? Int((spanSeconds * rfps).rounded()) : count
                        let backups = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("MacPlayer Backups").path)) ?? []
                        check(abs(t.count - wanted) <= (v.isVariableFrameRate ? 1 : 0), "replaced original now has \(t.count) frames (wanted \(wanted))")
                        check(backups.count == 1 && sha256(dir.appendingPathComponent("MacPlayer Backups/\(backups[0])")) == before, "backup is the untouched original")
                        check(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy { !$0.contains(".macplayer-") }, "no temp files left")
                        let vd = await displaySize(victim)
                        check(vd == disp, "replaced original is still upright and the same size (\(Int(vd.width))×\(Int(vd.height)))")
                    } else { check(false, "plan replace (\((try? r.planExport(ExportRequest(scope: .inOut, saveKind: .replaceOriginal, options: ExportOptions(mode: .exact, container: url.pathExtension.lowercased() == "mov" ? .mov : .mp4), folder: dir.path, baseName: nil))) == nil ? "refused" : "?"))") }
                    r.close(discardRecovery: true)
                } else { check(false, "open victim") }
            }
            try? fm.removeItem(at: dir)
        }

        if !mixedOnly { await libraryPlaylist(library: library, files: files, app: app) }
        await libraryMixed(env: env, work: work, infos: infos)
    }

    // MARK: A folder as a playlist

    static func libraryPlaylist(library: URL, files: [URL], app: AppDelegate) async {
        print("-- the whole folder as a playlist")
        let host = SelfTestHost(); let model = app.playlists
        model.host = host
        let pid = model.create(name: "Library")
        let report = model.add(urls: [library], to: pid)
        check(model.selected?.count == files.count, "dropping the folder adds all \(files.count) videos (got \(model.selected?.count ?? 0), skipped \(report?.duplicates.count ?? 0))")
        check(model.selected?.items.map(\.title) == files.map { $0.deletingPathExtension().lastPathComponent }, "in natural order")
        model.setMode(pid, rep: .off)
        guard let first = model.selected?.items.first else { return }
        model.play(first.id, in: pid)
        var seen: [String] = []
        let end = Date().addingTimeInterval(40)
        while Date() < end, seen.count < 3 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let t = host.current?.sourceURL?.deletingPathExtension().lastPathComponent, seen.last != t { seen.append(t) }
            if let s = host.current, s.player.duration.seconds > 0, s.player.currentTime.seconds < s.player.duration.seconds - 0.8, s.player.isPlaying { await s.player.seek(to: s.player.duration - MediaTime(seconds: 0.4)) }
        }
        check(seen == Array(files.prefix(3)).map { $0.deletingPathExtension().lastPathComponent }, "plays the first three in order and moves on by itself: \(seen)")
        host.current?.close(discardRecovery: true); host.current = nil
        model.delete(pid)
    }

    // MARK: Several different videos joined, with a layer

    static func libraryMixed(env: AppEnvironment, work: URL, infos: [(url: URL, info: MediaInfo)]) async {
        print("-- different videos joined on one timeline, then a layer on top")
        let fm = FileManager.default
        func pick(_ what: String, _ pred: (MediaInfo, MediaInfo.VideoTrack) -> Bool, excluding: [URL]) -> URL? {
            infos.first { i in !excluding.contains(i.url) && i.info.duration.seconds > 3.2 && (i.info.primaryVideo.map { pred(i.info, $0) } ?? false) }?.url
        }
        var chosen: [URL] = []
        for (what, pred) in [("portrait HDR with sound", { (i: MediaInfo, v: MediaInfo.VideoTrack) in v.isHDR && v.rotation == 90 && !i.audio.isEmpty && !v.isVariableFrameRate }),
                             ("landscape HDR", { (i: MediaInfo, v: MediaInfo.VideoTrack) in v.isHDR && v.rotation == 0 && !v.isVariableFrameRate }),
                             ("H.264 SDR", { (i: MediaInfo, v: MediaInfo.VideoTrack) in v.codec == "avc1" && !v.isHDR }),
                             ("30 fps SDR HEVC portrait", { (i: MediaInfo, v: MediaInfo.VideoTrack) in !v.isHDR && v.codec == "hvc1" && v.rotation != 0 }),
                             ("4K", { (i: MediaInfo, v: MediaInfo.VideoTrack) in max(v.width, v.height) > 2500 })] as [(String, (MediaInfo, MediaInfo.VideoTrack) -> Bool)] {
            if let u = pick(what, pred, excluding: chosen) { chosen.append(u); print("   \(what): \(u.lastPathComponent)") }
        }
        guard chosen.count >= 3, let s = try? await EditorSession.open(url: chosen[0]) else { check(false, "enough different videos to join"); return }
        await s.addVideos(Array(chosen.dropFirst()))
        check(s.project.timeline.count == chosen.count, "all \(chosen.count) added as clips (notice: \(s.notice?.text ?? "none"))")
        let order = s.project.timeline.map { c in s.sourceURLs[c.sourceID]?.lastPathComponent ?? "?" }
        check(order == chosen.map(\.lastPathComponent), "added in the order given: \(order.joined(separator: ", "))")
        // Keep each to 3 s, so the export is quick.
        for c in s.project.timeline {
            guard let start = TimelineEditor.starts(s.project.timeline)[c.id] else { continue }
            s.trimClip(c.id, leftEdge: false, toTimelineTime: start + MediaTime(seconds: 3))
        }
        let total = s.project.timelineDuration.seconds
        let starts = s.project.timeline.map { TimelineEditor.starts(s.project.timeline)[$0.id]?.seconds ?? 0 }
        check(abs(total - 3 * Double(chosen.count)) < 0.3, "timeline is \(String(format: "%.2f", total)) s (\(chosen.count) × 3 s)")
        await waitFor(15) { abs(s.player.duration.seconds - total) < 0.3 }
        check(abs(s.player.duration.seconds - total) < 0.3, "the preview is built for the whole timeline (\(String(format: "%.2f", s.player.duration.seconds)) s)")

        let outDir = work.appendingPathComponent("mixed"); try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let res = await runExport(s, env: env, ExportRequest(scope: .whole, saveKind: .newCopy, options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "joined"))
        guard let path = res.path else { check(false, "joined export: \(res.message)"); s.close(discardRecovery: true); return }
        let out = URL(fileURLWithPath: path)
        let times = await decodedTimes(out)
        let oi = try? await MediaProbe.probe(url: out)
        let outFps = oi?.primaryVideo?.frameRate?.framesPerSecond ?? 30
        let maxGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 9
        check(maxGap < 0.12 && abs(Double(times.count) / outFps - total) < 0.1, "joined file: \(times.count) frames at \(String(format: "%.2f", outFps)) fps for \(String(format: "%.2f", total)) s, longest gap \(Int(maxGap * 1000)) ms")
        let outLen = oi?.duration.seconds ?? 0
        check(abs(outLen - total) < 0.05, "joined file is \(String(format: "%.2f", outLen)) s long (the preview is \(String(format: "%.2f", total)) s)")
        if abs(outLen - total) > 0.03 { print("NOTE  the joined file is \(String(format: "%+.0f", (outLen - total) * 1000)) ms against the preview: each clip's length is rounded to the output frame grid, so a join drifts from the preview by about a frame per clip") }
        let od = await displaySize(out)
        print("   output picture \(Int(od.width))×\(Int(od.height)), \(oi?.primaryVideo?.codec ?? "?"), HDR \(oi?.primaryVideo?.isHDR == true)")
        // Every clip's picture is there (not black) and its sound lines up with the source's
        let joinedWave = await AudioEnvelope.loadSamples(out)
        print("   output sound \(String(format: "%.2f", Double(joinedWave?.count ?? 0) / 8000)) s for \(String(format: "%.2f", total)) s of picture")
        for (k, u) in chosen.enumerated() {
            let st = starts[k]
            if let mid = await thumb(out, at: st + 1.5), let src = await thumb(u, at: 1.5) {
                check(meanOf(mid) > 3 || meanOf(src) <= 3, "clip \(k + 1) (\(u.lastPathComponent)) is on screen at \(String(format: "%.1f", st + 1.5)) s (brightness \(Int(meanOf(mid))), source \(Int(meanOf(src))))")
            } else { check(false, "read a frame of clip \(k + 1)") }
            if infos.first(where: { $0.url == u })?.info.audio.isEmpty == false, let src = await AudioEnvelope.loadSamples(u, from: .zero, duration: 3), let all = joinedWave {
                let lo = Int(st * 8000), hi = min(all.count, lo + 24000)
                if hi - lo > 8000 {
                    let seg = Array(all[lo..<hi])
                    let w = AudioEnvelope.alignWaveforms(src, seg, maxLagMs: 300)
                    let allowed = 40.0          // every clip is a whole number of grid frames, so nothing accumulates
                    let ok = w == nil || (abs(w!.lagMs) <= allowed && w!.correlation >= 0.5)
                    var more = ""
                    if !ok, let wide = AudioEnvelope.alignWaveforms(src, seg, maxLagMs: 2500) { more = "; looking wider, the best fit is a shift of \(String(format: "%+.0f", wide.lagMs)) ms (match \(String(format: "%.2f", wide.correlation)))" }
                    check(ok, "clip \(k + 1) sound lines up with its source: \(w.map { "shifted \(String(format: "%+.1f", $0.lagMs)) ms, waveform match \(String(format: "%.2f", $0.correlation))" } ?? "silent")\(more)")
                }
            }
        }

        // A layer on top (a portrait HDR clip over the joined timeline)
        if let layerURL = chosen.first {
            await s.player.seek(to: MediaTime(seconds: 1))
            await s.addOverlayVideos([layerURL])
            check(s.project.overlayClips.count == 1, "a real video added as a layer")
            let res2 = await runExport(s, env: env, ExportRequest(scope: .whole, saveKind: .newCopy, options: ExportOptions(mode: .exact), folder: outDir.path, baseName: "layered"))
            if let p2 = res2.path {
                let o2 = URL(fileURLWithPath: p2)
                let i2 = try? await MediaProbe.probe(url: o2)
                check(abs((i2?.duration.seconds ?? 0) - total) < 0.15, "export with the layer keeps the length (\(String(format: "%.2f", i2?.duration.seconds ?? 0)) s)")
                if let a = await thumb(out, at: 2.0), let b = await thumb(o2, at: 2.0) { check(mad(a, b) > 0.8, "the layer shows in the picture (difference \(String(format: "%.1f", mad(a, b))))") }
            } else { check(false, "export with a layer: \(res2.message)") }
        }
        s.close(discardRecovery: true)
        if ProcessInfo.processInfo.environment["MACPLAYER_KEEP_OUTPUT"] == nil { try? fm.removeItem(at: outDir) } else { print("   kept \(outDir.path)") }
    }
}

/// The few ground-truth readers the library flow needs (the probe tool has the full set; the app does not link it).
enum RealCheckLite {
    static func frameTimes(_ url: URL) async -> [CMTime] {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: a) else { return [] }
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        r.add(o); r.startReading()
        var out: [CMTime] = []
        while let sb = o.copyNextSampleBuffer() { let p = CMSampleBufferGetPresentationTimeStamp(sb); if p.isNumeric { out.append(p) } }
        return out.sorted { $0.seconds < $1.seconds }
    }
}
