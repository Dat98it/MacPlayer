import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Measures what design section 16 asks for, on this machine, with synthetic files, and writes the numbers as Markdown.
/// Nothing is estimated: every figure below was timed in the run that wrote it.
///
///   macplayer-probe bench <work-dir> <out.md> [--quick]
///
/// `--quick` shrinks the files so the command can be tried in a minute; its numbers are not for the report.
enum Bench {
    // MARK: Small helpers

    static func now() -> Double { CACurrentMediaTime() }
    static func pct(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted(); let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded(.up))))
        return s[i]
    }
    static func ms(_ x: Double) -> String { x.isNaN ? "—" : String(format: "%.0f ms", x * 1000) }
    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "?" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resident memory the process holds right now (what Activity Monitor calls "Memory").
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
    }

    /// "8-bit" or "10-bit" as the file's own format description says it (HEVC Main vs Main10).
    static func bitDepth(_ url: URL) async -> String {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let fd = try? await t.load(.formatDescriptions).first,
              let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] else { return "?" }
        return "\(ext["BitsPerComponent"] ?? "?")-bit"
    }

    static func mb(_ url: URL) -> String { String(format: "%.1f MB", Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_048_576) }

    /// Samples the process's memory every 50 ms on its own thread and keeps the highest value.
    final class PeakMemory {
        private let lock = NSLock(); private var peak = 0.0; private var stop = false
        init() {
            let t = Thread { [self] in
                while true {
                    lock.lock(); let done = stop; if !done { peak = max(peak, Bench.footprintMB()) }; lock.unlock()
                    if done { return }
                    usleep(50_000)
                }
            }
            t.start()
        }
        func finish() -> Double { lock.lock(); stop = true; let p = peak; lock.unlock(); return p }
    }

    // MARK: Report

    final class Report {
        var lines: [String] = []
        func add(_ s: String = "") { lines.append(s); print(s) }
        func table(_ head: [String], _ rows: [[String]]) {
            add("| " + head.joined(separator: " | ") + " |")
            add("|" + head.map { _ in "---" }.joined(separator: "|") + "|")
            for r in rows { add("| " + r.joined(separator: " | ") + " |") }
            add()
        }
    }

    // MARK: A headless player that hands over frames, standing in for the picture area

    final class Probe: NSObject, AVPlayerItemOutputPullDelegate {
        let item: AVPlayerItem, player: AVPlayer, output: AVPlayerItemVideoOutput
        func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {}
        init(url: URL) {
            item = AVPlayerItem(url: url)
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            super.init()
        }
        /// Waits until a frame the caller accepts can be taken. After a seek the output keeps handing out the previous
        /// frame until the new one is decoded, so "a frame exists" is not enough: `accept` sees the frame's own time.
        func waitForFrame(timeout: Double = 8, width: Int? = nil, accept: (Double) -> Bool = { _ in true }) async -> (ok: Bool, pts: Double) {
            let t0 = Bench.now()
            var lastPTS = Double.nan
            while Bench.now() - t0 < timeout {
                let t = item.currentTime()
                var disp = CMTime.zero
                if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &disp) {
                    if let w = width, CVPixelBufferGetWidth(pb) != w { return (false, .nan) }
                    lastPTS = disp.seconds
                    if accept(lastPTS) { return (true, lastPTS) }
                }
                try? await Task.sleep(nanoseconds: 300_000)
            }
            return (false, lastPTS)
        }
    }

    // MARK: Run

    static func run(workDir: URL, output: URL, quick: Bool) async throws {
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let r = Report()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
        r.add("# MacPlayer: đo hiệu năng (mục 16 của thiết kế)")
        r.add()
        r.add("Chạy bằng `macplayer-probe bench` (bản release), \(fmt.string(from: Date()))\(quick ? " **(chế độ --quick: số liệu chỉ để thử, không dùng làm báo cáo)**" : ""). Mọi con số dưới đây được đo trong lần chạy này, không ước lượng.")
        r.add()
        r.add("## Máy đo")
        r.add()
        r.add("- Máy: \(shell("/usr/sbin/sysctl", ["-n", "hw.model"])), chip \(shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])), \(shell("/usr/sbin/sysctl", ["-n", "hw.ncpu"])) nhân, RAM \(Int((Double(shell("/usr/sbin/sysctl", ["-n", "hw.memsize"])) ?? 0) / 1_073_741_824)) GB")
        r.add("- macOS \(shell("/usr/bin/sw_vers", ["-productVersion"])) (\(shell("/usr/bin/sw_vers", ["-buildVersion"]))), ổ đo: \(workDir.path.hasPrefix("/Volumes/") ? "ổ ngoài/phụ" : "ổ hệ thống")")
        r.add("- Mẫu: video **tổng hợp** do MacPlayer tự sinh (hình đơn giản, bitrate cố định). Hình tổng hợp dễ mã hóa hơn cảnh quay thật, nên tốc độ xuất ở đây có thể **cao hơn** thực tế với video camera, còn bitrate thấp hơn thực tế sẽ làm giải mã nhẹ hơn. Cần đo lại với mẫu thật trước khi hứa con số nào.")
        r.add("- Bộ nhớ đệm của ổ đĩa đã nóng (file vừa tạo); không có quyền root để xóa cache, nên “mở lần đầu” là lần mở lần đầu của tiến trình, không phải lần đầu của ổ.")
        r.add()

        // ---- Files
        struct F { var name: String; var url: URL; var fps: Double; var seconds: Double; var width: Int; var height: Int; var gop: Double }
        func make(_ name: String, w: Int, h: Int, fps: Double, secs: Double, codec: SyntheticMedia.Codec, bitrate: Int, gop: Int, hdr: SyntheticMedia.Spec.HDRKind? = nil) async throws -> F {
            var s = SyntheticMedia.Spec(); s.width = w; s.height = h; s.frameRate = FrameRate(approximately: fps); s.seconds = secs; s.codec = codec
            s.bitrate = bitrate; s.keyframeInterval = gop; s.hdr = hdr; s.container = .mov
            let u = workDir.appendingPathComponent("\(name).mov")
            let t0 = now(); try await SyntheticMedia.generate(to: u, spec: s)
            print(String(format: "  (made %@ in %.1f s, %@)", name, now() - t0, mb(u)))
            return F(name: name, url: u, fps: fps, seconds: secs, width: w, height: h, gop: Double(gop))
        }
        let short = quick ? 6.0 : 30.0, k4 = quick ? 4.0 : 12.0, longSecs = quick ? 60.0 : 600.0
        print("Generating test files...")
        let f1080 = try await make("1080p30-h264", w: 1920, h: 1080, fps: 30, secs: short, codec: .h264, bitrate: 12_000_000, gop: 60)
        let f1080h = try await make("1080p30-hevc", w: 1920, h: 1080, fps: 30, secs: short, codec: .hevc, bitrate: 8_000_000, gop: 60)
        let f4k60h = try await make("4k60-hevc", w: 3840, h: 2160, fps: 60, secs: k4, codec: .hevc, bitrate: 40_000_000, gop: 120)
        let f4k60a = try await make("4k60-h264", w: 3840, h: 2160, fps: 60, secs: k4, codec: .h264, bitrate: 50_000_000, gop: 120)
        let all = [f1080, f1080h, f4k60h, f4k60a]

        // ---- 1. First frame
        r.add("## 1. Mở nguồn: thời gian tới khung hình đầu")
        r.add()
        r.add("Mục tiêu (mục 16): khung hình đầu trong 2 giây ở ít nhất 95% lượt. Mỗi mẫu mở 20 lần (đối tượng mới mỗi lần), đo từ lúc tạo player tới lúc lấy được khung hình đầu; cột “đọc thông tin” là thời gian `MediaProbe` (phần ứng dụng làm song song để hiện thông tin).")
        r.add()
        var rows: [[String]] = []
        for f in all {
            var firsts: [Double] = [], probes: [Double] = []
            var failures = 0
            for _ in 0..<20 {
                let t0 = now()
                let p = Probe(url: f.url)
                let got = await p.waitForFrame(width: f.width)
                if got.ok { firsts.append(now() - t0) } else { failures += 1 }
                p.player.pause()
                let t1 = now(); _ = try? await MediaProbe.probe(url: f.url); probes.append(now() - t1)
            }
            rows.append([f.name, ms(pct(firsts, 0.5)), ms(pct(firsts, 0.95)), ms(firsts.max() ?? .nan), ms(pct(probes, 0.5)), failures == 0 ? "20/20" : "\(20 - failures)/20", (pct(firsts, 0.95) < 2) ? "Đạt" : "Không đạt"])
        }
        r.table(["Mẫu", "Trung vị", "p95", "Chậm nhất", "Đọc thông tin (trung vị)", "Có hình", "p95 < 2 s"], rows)

        // ---- 2. Seek
        r.add("## 2. Tua: từ lúc ra lệnh tới lúc có đúng khung hình")
        r.add()
        r.add("30 lần tua ngẫu nhiên (cùng một hạt giống cho mọi mẫu). “Chính xác” = tua tới đúng khung hình (dung sai 0); “Thô” = chấp nhận khung gần nhất (cách thanh trượt phát hiện khi kéo). Cột “sai khung” đếm lần hình trả về lệch quá một khung so với đích (chỉ áp dụng cho tua chính xác).")
        r.add()
        rows = []
        for f in all {
            for exact in [true, false] {
                let p = Probe(url: f.url); _ = await p.waitForFrame()
                defer { p.player.pause() }
                var rng = SystemRandomNumberGenerator(); _ = rng
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
                let gopSeconds = f.gop / f.fps
                var lat: [Double] = [], wrong = 0, timeouts = 0
                for _ in 0..<30 {
                    // As the app does: the frame's own time as a fraction of the frame rate, never rounded to a coarse timescale.
                    let fr = FrameRate(approximately: f.fps)
                    let idx = Int64((next() * (f.seconds - 0.5) * f.fps).rounded(.down))
                    let mt = MediaTime.frameStart(index: idx, frameRate: fr)
                    let target = mt.seconds
                    let t = mt.cmTime
                    let t0 = now()
                    await p.player.seek(to: t, toleranceBefore: exact ? .zero : .positiveInfinity, toleranceAfter: exact ? .zero : .positiveInfinity)
                    let got = await p.waitForFrame(timeout: 4, width: f.width) { pts in exact ? abs(pts - target) <= 0.5 / f.fps : abs(pts - target) <= gopSeconds + 1.0 / f.fps }
                    lat.append(now() - t0)
                    if ProcessInfo.processInfo.environment["BENCH_DEBUG"] != nil { print("   seek \(exact ? "exact" : "coarse") target=\(target) -> ok=\(got.ok) pts=\(got.pts) \(Int(lat.last! * 1000)) ms, current=\(p.item.currentTime().seconds)") }
                    if !got.ok { timeouts += 1 }
                    if exact, !got.ok || abs(got.pts - target) > 1.0 / f.fps + 0.001 { wrong += 1 }
                }
                rows.append([f.name, exact ? "Chính xác" : "Thô", ms(pct(lat, 0.5)), ms(pct(lat, 0.95)), ms(lat.max() ?? .nan), exact ? "\(wrong)/30" : "—", timeouts == 0 ? "0" : "\(timeouts)"])
            }
        }
        r.table(["Mẫu", "Kiểu tua", "Trung vị", "p95", "Chậm nhất", "Sai khung", "Không ra hình (4 s)"], rows)

        // ---- 3. Playback
        r.add("## 3. Phát liên tục: khung hình bị rơi")
        r.add()
        r.add("Phát \(quick ? 4 : 10) giây ở tốc độ 1× (và 2× cho 1080p). Một vòng lặp 1 ms lấy khung hình mà player có sẵn cho thời điểm hiện tại, giống cách màn hình lấy. Một khung “rơi” là khung có trong file mà không bao giờ được giao. Không có cửa sổ thật, nên đây là khả năng giải mã/giao hình, không gồm vẽ lên màn hình.")
        r.add()
        rows = []
        let playSecs = quick ? 4.0 : 10.0
        for (f, rate) in [(f1080, 1.0), (f1080, 2.0), (f1080h, 1.0), (f4k60h, 1.0), (f4k60a, 1.0)] {
            let p = Probe(url: f.url); _ = await p.waitForFrame()
            let startItem = p.item.currentTime().seconds
            let startWall = now()
            p.player.rate = Float(rate)
            let out = p.output
            let item = p.item
            let delivered = await Task.detached { () -> [(Double, Double)] in
                var seen = Set<Int64>(); var got: [(Double, Double)] = []
                let end = Bench.now() + playSecs
                while Bench.now() < end {
                    let host = Bench.now()
                    let t = out.itemTime(forHostTime: host)
                    if out.hasNewPixelBuffer(forItemTime: t) {
                        var disp = CMTime.zero
                        if out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &disp) != nil {
                            let key = Int64((disp.seconds * 100_000).rounded())
                            if seen.insert(key).inserted { got.append((disp.seconds, host)) }
                        }
                    }
                    usleep(1000)
                }
                return got
            }.value
            let wall = now() - startWall
            let playedMedia = item.currentTime().seconds - startItem
            p.player.pause()
            var dropped = 0, maxGap = 0.0
            for (a, b) in zip(delivered, delivered.dropFirst()) {
                let skipped = Int(((b.0 - a.0) * f.fps).rounded()) - 1
                if skipped > 0 { dropped += skipped }
                maxGap = max(maxGap, b.1 - a.1)
            }
            let expected = delivered.count + dropped
            rows.append([f.name, "\(rate == 1 ? "1" : "2")×", "\(delivered.count) / \(expected)", "\(dropped) (\(String(format: "%.2f", expected > 0 ? Double(dropped) * 100 / Double(expected) : 0))%)", ms(maxGap), String(format: "%.2f×", playedMedia / wall)])
        }
        r.table(["Mẫu", "Tốc độ", "Giao / có trong file", "Rơi", "Khoảng cách lâu nhất giữa 2 khung", "Tốc độ phát thực"], rows)

        // ---- 4. Export throughput + correctness
        r.add("## 4. Tốc độ xuất và độ đúng của kết quả")
        r.add()
        r.add("Mỗi dòng cắt một đoạn \(quick ? 3 : 8) giây, rồi **đọc lại file kết quả**: đếm khung (phải đủ và liên tục) và đo lệch âm thanh–hình tại các mốc bíp. “Nhanh” = không mã hóa lại. “Hệ số” = giây video / giây thực. Không có hệ số chung: số này chỉ đúng cho máy và mẫu ở trên.")
        r.add()
        rows = []
        let cutSecs = quick ? 3.0 : 8.0
        func cutCase(_ f: F, label: String, mode: CutMode, codec: VideoCodecChoice, res: ResolutionLimit = .source, look: VideoLook = VideoLook(), startAt: Double = 2.5) async -> [String] {
            let fr = FrameRate(approximately: f.fps)
            let a = Int64((startAt * f.fps).rounded()), b = a + Int64((min(cutSecs, f.seconds - startAt - 0.2) * f.fps).rounded())
            let span = TimeSpan(start: .frameStart(index: a, frameRate: fr), end: .frameStart(index: b, frameRate: fr))
            let out = workDir.appendingPathComponent("out-\(f.name)-\(label.filter { $0.isLetter || $0.isNumber }).mov")
            try? FileManager.default.removeItem(at: out)
            let opts = ExportOptions(mode: mode, container: .mov, codec: codec, resolution: res)
            let t0 = now()
            do {
                try await RenderExporter().export(pieces: [RenderPiece(sourceURL: f.url, span: span, look: look)], to: out, options: opts)
            } catch { return [f.name, label, "LỖI: \(error)", "", "", "", ""] }
            let wall = now() - t0
            var count = "—", sync = "—"
            if let frames = try? await FrameScanner.scanVideo(url: out) {
                let idx = frames.compactMap(\.index)
                let contiguous = zip(idx, idx.dropFirst()).allSatisfy { $1 == $0 + 1 }
                let want = Int(b - a)
                // A re-encode at a smaller size can lose the barcode; then only the count is checked.
                if idx.count == frames.count { count = (mode == .exact && idx.count == want && contiguous && idx.first == Int(a)) ? "\(idx.count)/\(want) đúng" : "\(idx.count)/\(want) (từ \(idx.first.map(String.init) ?? "?"), \(contiguous ? "liên tục" : "KHÔNG liên tục"))" }
                else { count = frames.count == want ? "\(frames.count)/\(want) (không đọc được mã vạch)" : "\(frames.count)/\(want) SAI" }
                if let onsets = try? await FrameScanner.beepOnsets(url: out), !onsets.isEmpty, idx.count == frames.count, mode == .exact {
                    let fpsInt = Int(f.fps.rounded()); var diffs: [Double] = []
                    for o in onsets { if let fr = frames.first(where: { ($0.index ?? -1) % fpsInt == 0 && ($0.index ?? 0) > 0 && abs($0.time.seconds - o.seconds) < 0.5 }) { diffs.append(abs(o.seconds - fr.time.seconds) * 1000) } }
                    if let w = diffs.max() { sync = String(format: "%.1f ms (khung = %.1f ms) %@", w, 1000 / f.fps, w <= 1000 / f.fps ? "Đạt" : "VƯỢT") }
                } else if mode == .fast { sync = "không áp dụng (giữ nguyên khung đầu trước điểm cắt)" }
            }
            return [f.name, label, String(format: "%.2f s", wall), String(format: "%.1f×", Double(b - a) / f.fps / wall), mb(out), count, sync]
        }
        var neutral = VideoLook(); _ = neutral
        var graded = VideoLook(); graded.color.brightness = 0.1; graded.color.saturation = 0.2
        for f in [f1080, f4k60h, f4k60a] {
            rows.append(await cutCase(f, label: "Nhanh", mode: .fast, codec: f.name.contains("hevc") ? .hevc : .h264))
            rows.append(await cutCase(f, label: "Chính xác, giữ cỡ", mode: .exact, codec: f.name.contains("hevc") ? .hevc : .h264))
        }
        rows.append(await cutCase(f1080, label: "Chính xác, HEVC", mode: .exact, codec: .hevc))
        rows.append(await cutCase(f1080, label: "Chính xác + chỉnh màu", mode: .exact, codec: .h264, look: graded))
        rows.append(await cutCase(f4k60h, label: "Chính xác, 4K→1080p", mode: .exact, codec: .h264, res: .p1080))
        rows.append(await cutCase(f4k60h, label: "Chính xác + chỉnh màu", mode: .exact, codec: .hevc, look: graded))
        neutral = VideoLook()
        r.table(["Mẫu", "Kiểu", "Thời gian", "Hệ số", "Kích thước", "Số khung", "Lệch âm–hình tệ nhất"], rows)

        // ---- 5. Cancel
        r.add("## 5. Hủy xuất")
        r.add()
        r.add("Mục tiêu: dừng worker và giải phóng tài nguyên trong 5 giây. Đo từ lúc gọi hủy (sau 1 giây xuất) tới lúc lệnh xuất trả về, rồi kiểm tra không còn file dở. 5 lần cho mỗi mẫu.")
        r.add()
        rows = []
        for f in [f1080, f4k60h] {
            var times: [Double] = [], leftovers = 0, finishedFirst = 0
            for i in 0..<5 {
                let out = workDir.appendingPathComponent("cancel-\(f.name)-\(i).mov")
                try? FileManager.default.removeItem(at: out)
                let fr = FrameRate(approximately: f.fps)
                let span = TimeSpan(start: .zero, end: .frameStart(index: Int64(f.seconds * f.fps) - 2, frameRate: fr))
                let task = Task { try await RenderExporter().export(pieces: [RenderPiece(sourceURL: f.url, span: span)], to: out, options: ExportOptions(mode: .exact, container: .mov, codec: f.name.contains("hevc") ? .hevc : .h264)) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let t0 = now(); task.cancel(); let res = await task.result; times.append(now() - t0)
                if case .success = res { finishedFirst += 1; try? FileManager.default.removeItem(at: out); continue }   // it was already done: nothing to cancel
                if FileManager.default.fileExists(atPath: out.path) { leftovers += 1; try? FileManager.default.removeItem(at: out) }
            }
            let cancelled = 5 - finishedFirst
            rows.append([f.name, "\(cancelled)/5", ms(pct(times, 0.5)), ms(times.max() ?? .nan), leftovers == 0 ? "không" : "\(leftovers)/\(cancelled) còn file dở", cancelled == 0 ? "xuất xong trước khi hủy: không đo được" : ((times.max() ?? 99) < 5 ? "Đạt" : "Không đạt")])
        }
        r.table(["Mẫu", "Hủy giữa chừng", "Trung vị", "Chậm nhất", "File dở sau hủy", "< 5 s"], rows)

        // ---- 6. Long video
        r.add("## 6. Video dài (\(Int(longSecs / 60)) phút, 1080p30)")
        r.add()
        print("Generating long file...")
        let long = try await make("long-1080p30", w: 1920, h: 1080, fps: 30, secs: longSecs, codec: .h264, bitrate: 6_000_000, gop: 60)
        let mem0 = footprintMB()
        let memory = PeakMemory()
        var lrows: [[String]] = []
        let t0 = now(); let info = try await MediaProbe.probe(url: long.url); lrows.append(["Đọc thông tin", ms(now() - t0), "thời lượng \(f1(info.duration.seconds)) s"])
        let lp = Probe(url: long.url); let t1 = now(); let ff = await lp.waitForFrame(); lrows.append(["Khung hình đầu", ms(now() - t1), ff.ok ? "có hình" : "KHÔNG có hình"])
        let t2 = now(); let peaks = (try? await Waveform.peaks(url: long.url)) ?? []; lrows.append(["Dạng sóng toàn bộ", ms(now() - t2), "\(peaks.count) cột, đỉnh lớn nhất \(f1(Double(peaks.max() ?? 0)))"])
        for target in [longSecs * 0.5, longSecs - 2, 1] {
            let t = CMTime(seconds: target, preferredTimescale: 6000); let ts = now()
            await lp.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero); let g = await lp.waitForFrame(timeout: 8) { abs($0 - target) <= 0.5 / 30 }
            lrows.append(["Tua chính xác tới \(Int(target)) s", ms(now() - ts), g.ok ? "đúng khung" : "KHÔNG ra đúng khung (\(f1(g.pts)))"])
        }
        lp.player.pause()
        let fr30 = FrameRate(numerator: 30, denominator: 1)
        let endSpan = TimeSpan(start: .frameStart(index: Int64((longSecs - 10) * 30), frameRate: fr30), end: .frameStart(index: Int64((longSecs - 2) * 30), frameRate: fr30))
        for mode in [CutMode.fast, .exact] {
            let out = workDir.appendingPathComponent("long-cut-\(mode.rawValue).mov"); try? FileManager.default.removeItem(at: out)
            let tc = now()
            do {
                try await RenderExporter().export(pieces: [RenderPiece(sourceURL: long.url, span: endSpan)], to: out, options: ExportOptions(mode: mode, container: .mov, codec: .h264))
                let idx = (try? await FrameScanner.scanVideo(url: out))?.compactMap(\.index) ?? []
                let ok = idx.count == 240 && idx.first == Int((longSecs - 10) * 30) && zip(idx, idx.dropFirst()).allSatisfy { $1 == $0 + 1 }
                lrows.append(["Cắt 8 s gần cuối (\(mode == .fast ? "nhanh" : "chính xác"))", ms(now() - tc), mode == .exact ? (ok ? "240/240 khung đúng" : "SAI: \(idx.count) khung, từ \(idx.first.map(String.init) ?? "?")") : "\(idx.count) khung (giữ khung trước điểm cắt)"])
            } catch { lrows.append(["Cắt gần cuối (\(mode.rawValue))", "—", "LỖI: \(error)"]) }
        }
        let out = workDir.appendingPathComponent("long-full-fast.mov"); try? FileManager.default.removeItem(at: out)
        let tf = now()
        do {
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: long.url, span: TimeSpan(start: .zero, end: info.duration))], to: out, options: ExportOptions(mode: .fast, container: .mov, codec: .h264))
            let w = now() - tf; lrows.append(["Xuất cả video, nhanh", String(format: "%.1f s", w), String(format: "%.0f× thời gian thực, %@", longSecs / w, mb(out))])
        } catch { lrows.append(["Xuất cả video, nhanh", "—", "LỖI: \(error)"]) }
        let memPeak = memory.finish()
        lrows.append(["Bộ nhớ của tiến trình", String(format: "đỉnh %.0f MB (lúc bắt đầu %.0f MB)", memPeak, mem0), "đo mỗi 50 ms suốt phần video dài, gồm cả cắt và xuất"])
        r.table(["Phép đo", "Kết quả", "Ghi chú"], lrows)

        // ---- 7. HDR
        r.add("## 7. HDR")
        r.add()
        r.add("Mẫu HDR ở đây **chỉ mang cờ HDR** (HEVC 10-bit, màu BT.2020, truyền HLG hoặc PQ), hình vẫn là hình thử nghiệm đơn giản; chưa có video HDR thật từ camera/iPhone (Dolby Vision cũng chưa thử). Phần này kiểm tra ứng dụng có **nhận ra** HDR, **cảnh báo** đúng, và file xuất ra mang nhãn màu gì; nó không đánh giá màu có đẹp hay không.")
        r.add()
        rows = []
        for (name, kind) in [("hdr-hlg", SyntheticMedia.Spec.HDRKind.hlg), ("hdr-pq", .pq)] {
            let f = try await make(name, w: 1920, h: 1080, fps: 30, secs: 4, codec: .hevc, bitrate: 10_000_000, gop: 60, hdr: kind)
            let i = try await MediaProbe.probe(url: f.url); let v = i.primaryVideo
            func warn(_ m: CutMode) -> String { ExportOptions(mode: m, container: .mov, codec: .hevc).warnings(source: i).contains(.hdrKept) ? "báo “giữ HDR”" : "không báo" }
            rows.append([name, "nguồn", "\(v?.codec ?? "?") \(await bitDepth(f.url)) \(v?.transferFunction ?? "?") / \(v?.colorPrimaries ?? "?")", v?.isHDR == true ? "nhận ra HDR" : "KHÔNG nhận ra", "xuất chính xác: \(warn(.exact)); cắt nhanh: \(warn(.fast))"])
            for mode in [CutMode.fast, .exact] {
                let o = workDir.appendingPathComponent("\(name)-\(mode.rawValue).mov"); try? FileManager.default.removeItem(at: o)
                let span = TimeSpan(start: .frameStart(index: 15, frameRate: fr30), end: .frameStart(index: 75, frameRate: fr30))
                do {
                    try await RenderExporter().export(pieces: [RenderPiece(sourceURL: f.url, span: span)], to: o, options: ExportOptions(mode: mode, container: .mov, codec: .hevc))
                    let oi = try await MediaProbe.probe(url: o); let ov = oi.primaryVideo
                    let depth = await bitDepth(o)
                    rows.append([name, mode == .fast ? "kết quả cắt nhanh" : "kết quả chính xác", "\(ov?.codec ?? "?") \(depth) \(ov?.transferFunction ?? "?") / \(ov?.colorPrimaries ?? "?")", ov?.isHDR == true && depth == "10-bit" ? "vẫn là HDR 10-bit" : (ov?.isHDR == true ? "nhãn HDR nhưng chỉ \(depth)" : "đã thành SDR"), mb(o)])
                } catch { rows.append([name, "kết quả \(mode.rawValue)", "LỖI: \(error)", "", ""]) }
            }
        }
        let hf = workDir.appendingPathComponent("hdr-hlg.mov")
        for (label, codec, look) in [("chính xác, chọn H.264", VideoCodecChoice.h264, VideoLook()), ("chính xác + chỉnh màu", .hevc, graded)] {
            let o = workDir.appendingPathComponent("hdr-hlg-\(label.filter { $0.isLetter || $0.isNumber }).mov"); try? FileManager.default.removeItem(at: o)
            let span = TimeSpan(start: .frameStart(index: 15, frameRate: fr30), end: .frameStart(index: 75, frameRate: fr30))
            do {
                try await RenderExporter().export(pieces: [RenderPiece(sourceURL: hf, span: span, look: look)], to: o, options: ExportOptions(mode: .exact, container: .mov, codec: codec))
                let oi = try await MediaProbe.probe(url: o); let ov = oi.primaryVideo; let depth = await bitDepth(o)
                rows.append(["hdr-hlg", "kết quả \(label)", "\(ov?.codec ?? "?") \(depth) \(ov?.transferFunction ?? "?") / \(ov?.colorPrimaries ?? "?")", ov?.isHDR == true && depth == "10-bit" ? "vẫn là HDR 10-bit" : "nhãn \(ov?.isHDR == true ? "HDR" : "SDR"), \(depth)", mb(o)])
            } catch { rows.append(["hdr-hlg", "kết quả \(label)", "LỖI: \(error)", "", ""]) }
        }
        r.table(["Mẫu", "Giai đoạn", "Codec / độ sâu / truyền / màu", "Nhận định", "Ghi chú"], rows)

        let md = r.lines.joined(separator: "\n") + "\n"
        try md.write(to: output, atomically: true, encoding: .utf8)
        print("\nwrote \(output.path)")
    }
}
