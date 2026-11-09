import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// The same questions the synthetic tests ask, put to real footage that nobody generated for the purpose.
/// Real files have no barcode, so the ground truth is the file's own frame times and its own decoded pixels:
///   - a seek is right when the frame that comes back carries the frame time that was asked for;
///   - a cut is right when it has exactly the frames of the span, in order, from time 0, and decodes to the
///     same picture (as displayed: rotation applied) as the source frames it was cut from (mean absolute luma difference);
///   - the sound of a cut is right when it is as long as the span, and its loudness over time lines up with the source's.
///
///   macplayer-probe realcheck <folder-with-videos> <work-dir> <out.md> [--light]
/// `--light` skips playback, the all-frames random-access sweep and the exports: it is for sweeping a whole library quickly.
enum RealCheck {
    // MARK: Ground truth from the file itself

    /// Frame times of the video track in presentation order, as the player shows them: read from the sample table (nothing is decoded),
    /// minus the start of the track's edit (files trimmed in Photos start their edit part-way into the media, so the table's own times run
    /// ahead of the timeline by that much, and the frames before the edit are never shown).
    static func frameTimes(_ url: URL) async -> [CMTime] {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: a) else { return [] }
        let seg = (try? await t.load(.segments))?.first { !$0.isEmpty }
        let shift = seg.map { CMTimeSubtract($0.timeMapping.source.start, $0.timeMapping.target.start) } ?? .zero
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        r.add(o); r.startReading()
        var out: [CMTime] = []
        while let sb = o.copyNextSampleBuffer() {
            let p = CMSampleBufferGetPresentationTimeStamp(sb)
            guard p.isNumeric else { continue }
            if let s = seg, CMTimeCompare(p, CMTimeSubtract(s.timeMapping.source.start, CMTime(value: 1, timescale: 1000))) < 0 { continue }      // before the edit: never shown
            if let s = seg, CMTimeCompare(p, CMTimeRangeGetEnd(s.timeMapping.source)) >= 0 { continue }                                           // after the edit
            out.append(CMTimeSubtract(p, shift))
        }
        return out.sorted { $0.seconds < $1.seconds }
    }

    struct Decoded { var times: [Double]; var luma: [Int: [Float]] }

    /// The track's coded size, before rotation: what the player's pixel buffers measure.
    static func rawWidth(_ url: URL) async -> Int {
        guard let t = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first, let s = try? await t.load(.naturalSize) else { return 0 }
        return Int(s.width)
    }

    /// Decodes frames (as the file presents them, edit list respected) and keeps a thin sample of the luma plane for the wanted ones.
    /// The sample grid is laid over the picture as it is DISPLAYED (rotation applied), so a file that stores its picture sideways and
    /// one that stores it upright compare as the same picture.
    static func decode(_ url: URL, from start: CMTime? = nil, frames: Int? = nil, fps: Double, tenBit: Bool, keep: Set<Int>, mirrorX: Bool = false) async -> Decoded {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: a) else { return Decoded(times: [], luma: [:]) }
        let transform = (try? await t.load(.preferredTransform)) ?? .identity
        let natural = (try? await t.load(.naturalSize)) ?? .zero
        let display = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let inverse = transform.inverted()
        if let s = start, let n = frames {
            // A reader returns every frame that overlaps the range, so start a quarter frame AFTER the wanted frame's time:
            // that frame still overlaps, the one before it ends exactly at its time and does not.
            let begin = CMTimeAdd(s, CMTime(seconds: 0.25 / fps, preferredTimescale: 60000))
            r.timeRange = CMTimeRange(start: begin, duration: CMTime(seconds: (Double(n) + 0.5) / fps, preferredTimescale: 60000))
        }
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        o.alwaysCopiesSampleData = false
        r.add(o); r.startReading()
        var times: [Double] = [], luma: [Int: [Float]] = [:]
        var i = 0
        while let sb = o.copyNextSampleBuffer() {
            let p = CMSampleBufferGetPresentationTimeStamp(sb)
            guard p.isNumeric else { continue }
            times.append(p.seconds)
            if keep.contains(i), let pb = CMSampleBufferGetImageBuffer(sb) {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
                var s: [Float] = []
                let sx = natural.width > 0 ? Double(w) / Double(natural.width) : 1, sy = natural.height > 0 ? Double(h) / Double(natural.height) : 1
                for dy in stride(from: 0, to: Int(display.height), by: 8) {
                    for dx in stride(from: 0, to: Int(display.width), by: 8) {
                        let q = CGPoint(x: (mirrorX ? display.width - Double(dx) - 0.5 : Double(dx) + 0.5) + display.minX, y: Double(dy) + 0.5 + display.minY).applying(inverse)
                        let x = min(max(Int((q.x * sx).rounded(.down)), 0), w - 1), y = min(max(Int((q.y * sy).rounded(.down)), 0), h - 1)
                        if tenBit { s.append(Float(base.load(fromByteOffset: y * row + x * 2, as: UInt16.self) >> 6) / 1023 * 255) }
                        else { s.append(Float(base.load(fromByteOffset: y * row + x, as: UInt8.self))) }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                luma[i] = s
            }
            i += 1
            if let n = frames, i >= n { break }
        }
        return Decoded(times: times, luma: luma)
    }

    static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .nan }
        var s = 0.0; for i in 0..<a.count { s += Double(abs(a[i] - b[i])) }
        return s / Double(a.count)
    }
    static func mean(_ a: [Float]) -> Double { a.isEmpty ? .nan : a.reduce(0.0) { $0 + Double($1) } / Double(a.count) }

    /// Names of the Dolby Vision configuration boxes the track carries, if any.
    static func dolbyVisionBoxes(_ url: URL) async -> [String] {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let fd = try? await t.load(.formatDescriptions).first,
              let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any], let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any] else { return [] }
        return atoms.keys.filter { $0.hasPrefix("dv") }.sorted()
    }


    /// How many of the first frames carry a Dolby Vision RPU (HEVC NAL unit type 62): a file that names Dolby Vision in its header but has none
    /// is not a Dolby Vision file. Nil when the track is not HEVC.
    static func rpuFrames(_ url: URL, limit: Int = 150) async -> (withRPU: Int, total: Int)? {
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first, let fd = try? await t.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC, let r = try? AVAssetReader(asset: a) else { return nil }
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &lengthSize)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        r.add(o)
        guard r.startReading() else { print("reader: \(String(describing: r.error))"); return nil }
        var with = 0, total = 0
        while total < limit, let sb = o.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { print("no data buffer"); continue }
            let n = CMBlockBufferGetDataLength(bb)
            var bytes = [UInt8](repeating: 0, count: n)
            bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            var i = 0, found = false
            while i + Int(lengthSize) < n {
                var len = 0
                for k in 0..<Int(lengthSize) { len = (len << 8) | Int(bytes[i + k]) }
                i += Int(lengthSize)
                if len <= 0 || i + len > n { break }
                if (bytes[i] >> 1) & 0x3F == 62 { found = true }
                i += len
            }
            total += 1; if found { with += 1 }
        }
        return (with, total)
    }

    // MARK: Run

    struct Info {
        var url: URL; var fps: Double; var hdr: Bool; var w: Int; var h: Int; var rawW: Int; var times: [CMTime]; var codec: String; var transfer: String
        var rotation: Int; var vfr: Bool; var audio: Bool
    }

    static func run(dir: URL, workDir: URL, output: URL, light: Bool) async throws {
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let r = Bench.Report()
        r.add("# MacPlayer: kiểm thử trên video thật")
        r.add()
        r.add("Chạy bằng `macplayer-probe realcheck`\(light ? " với `--light` (không phát, không xuất, không quét mọi khung)" : ""). Video thật (không do MacPlayer sinh) nên **không có mã vạch**: chân lý lấy từ chính bảng khung hình, điểm ảnh và âm thanh đã giải mã của file. Một lần tua đúng khi khung trả về mang đúng thời điểm khung đã yêu cầu. Một lần cắt đúng khi file kết quả có đúng các khung của đoạn, liên tục, bắt đầu từ 0, giải mã ra cùng một hình (theo chiều hiển thị) với các khung nguồn tương ứng (sai khác độ sáng trung bình, thang 0–255), và âm thanh dài bằng đoạn cắt, có đường độ to khớp với nguồn.")
        r.add()
        r.add("Máy: \(Bench.shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])), macOS \(Bench.shell("/usr/bin/sw_vers", ["-productVersion"])). \(files.count) file.")
        r.add()

        var infos: [Info] = []
        r.add("## 1. Các file và việc nhận diện")
        r.add()
        var rows: [[String]] = []
        for f in files {
            let i = try await MediaProbe.probe(url: f); guard let v = i.primaryVideo else { rows.append([f.lastPathComponent, "KHÔNG có track hình", "", "", "", "", ""]); continue }
            let times = await frameTimes(f)
            let fps = v.frameRate?.framesPerSecond ?? 30
            let deltas = zip(times, times.dropFirst()).map { $1.seconds - $0.seconds }
            let steady = deltas.allSatisfy { abs($0 - 1 / fps) < 0.5 / fps }     // no frame missing or doubled (times may be rounded to ms)
            let dv = await dolbyVisionBoxes(f)
            let gaps = deltas.isEmpty ? "" : String(format: ", cách khung %.1f–%.1f ms", (deltas.min() ?? 0) * 1000, (deltas.max() ?? 0) * 1000)
            rows.append([f.lastPathComponent, "\(v.codec) \(v.codec == "avc1" ? "8-bit" : await Bench.bitDepth(f)) \(v.width)×\(v.height)\(v.rotation != 0 ? ", xoay \(v.rotation)°" : "")",
                         String(format: "%.2f fps, %d khung, %.1f s", fps, times.count, i.duration.seconds) + (v.isVariableFrameRate ? ", VFR\(gaps)" : steady ? "" : ", cách khung không đều\(gaps)"),
                         v.isHDR ? "HDR (\(v.transferFunction ?? "?"))" : "SDR", dv.isEmpty ? "—" : dv.joined(separator: ","),
                         i.audio.isEmpty ? "không có" : "\(i.audio[0].codec) \(i.audio[0].channels) kênh \(Int(i.audio[0].sampleRate)) Hz", Bench.mb(f)])
            infos.append(Info(url: f, fps: fps, hdr: v.isHDR, w: v.width, h: v.height, rawW: await rawWidth(f), times: times, codec: v.codec, transfer: v.transferFunction ?? "",
                              rotation: v.rotation, vfr: v.isVariableFrameRate, audio: !i.audio.isEmpty))
        }
        r.table(["File", "Định dạng", "Khung hình", "Loại", "Hộp Dolby Vision", "Âm thanh", "Dung lượng"], rows)

        // ---- first frame
        let trials = light ? 3 : 10
        r.add("## 2. Mở: thời gian tới khung hình đầu")
        r.add()
        rows = []
        for f in infos {
            var firsts: [Double] = [], bad = 0
            for _ in 0..<trials {
                let t0 = Bench.now(); let p = Bench.Probe(url: f.url); let g = await p.waitForFrame(width: f.rawW)
                if g.ok { firsts.append(Bench.now() - t0) } else { bad += 1 }
                p.player.pause()
            }
            rows.append([f.url.lastPathComponent, Bench.ms(Bench.pct(firsts, 0.5)), Bench.ms(Bench.pct(firsts, 0.95)), "\(trials - bad)/\(trials)", Bench.pct(firsts, 0.95) < 2 ? "Đạt" : "Không đạt"])
        }
        r.table(["File", "Trung vị", "p95", "Có hình", "p95 < 2 s"], rows)

        // ---- seek
        let seeks = light ? 8 : 30
        r.add("## 3. Tua chính xác tới một khung bất kỳ")
        r.add()
        r.add("\(seeks) khung ngẫu nhiên mỗi file; thời điểm yêu cầu là thời điểm thật của khung trong bảng mẫu. “Sai” = khung trả về có thời điểm khác khung yêu cầu quá nửa khoảng cách tới khung kề (với VFR, khoảng cách thật của khung đó).")
        r.add()
        rows = []
        for f in infos where f.times.count > 2 {
            let p = Bench.Probe(url: f.url); _ = await p.waitForFrame(width: f.rawW)
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            var lat: [Double] = [], wrong = 0
            for _ in 0..<seeks {
                let k = Int(next() * Double(f.times.count - 1))
                let t = f.times[k]
                let prev = k > 0 ? t.seconds - f.times[k - 1].seconds : 1 / f.fps, nextGap = f.times[k + 1].seconds - t.seconds
                let tol = max(0.0005, 0.5 * min(prev, nextGap))
                let t0 = Bench.now()
                await p.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                let g = await p.waitForFrame(timeout: 4, width: f.rawW) { abs($0 - t.seconds) <= tol }
                lat.append(Bench.now() - t0)
                if !g.ok { wrong += 1; print("   tua lỗi \(f.url.lastPathComponent): khung \(k) yêu cầu \(t.seconds) (\(t.value)/\(t.timescale)), nhận \(g.pts), \(Int((Bench.now() - t0) * 1000)) ms") }
            }
            p.player.pause()
            rows.append([f.url.lastPathComponent, Bench.ms(Bench.pct(lat, 0.5)), Bench.ms(Bench.pct(lat, 0.95)), Bench.ms(lat.max() ?? .nan), "\(wrong)/\(seeks)"])
        }
        r.table(["File", "Trung vị", "p95", "Chậm nhất", "Sai"], rows)

        if light {
            let md = r.lines.joined(separator: "\n") + "\n"
            try md.write(to: output, atomically: true, encoding: .utf8)
            print("\nwrote \(output.path)")
            return
        }

        // ---- playback
        r.add("## 4. Phát liên tục (1×), tối đa 10 s từ đầu file")
        r.add()
        r.add("“Rơi” đếm số khung CÓ trong bảng mẫu của file mà không bao giờ được giao (tính theo khung thật của file, nên đúng cả với VFR).")
        r.add()
        rows = []
        for f in infos {
            let p = Bench.Probe(url: f.url); _ = await p.waitForFrame(width: f.rawW)
            let start = p.item.currentTime().seconds, w0 = Bench.now()
            let secs = min(10.0, max(1.5, (f.times.last?.seconds ?? 3) - start - 0.8))
            p.player.rate = 1
            let out = p.output
            let got = await Task.detached { () -> [(Double, Double)] in
                var seen = Set<Int64>(); var g: [(Double, Double)] = []
                let end = Bench.now() + secs
                while Bench.now() < end {
                    let host = Bench.now(); let t = out.itemTime(forHostTime: host)
                    if out.hasNewPixelBuffer(forItemTime: t) {
                        var d = CMTime.zero
                        if out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &d) != nil, seen.insert(Int64((d.seconds * 100_000).rounded())).inserted { g.append((d.seconds, host)) }
                    }
                    usleep(1000)
                }
                return g
            }.value
            let wall = Bench.now() - w0, played = p.item.currentTime().seconds - start
            p.player.pause()
            let table = f.times.map(\.seconds)
            func index(_ x: Double) -> Int {      // nearest frame of the file
                var lo = 0, hi = table.count - 1
                while lo < hi { let m = (lo + hi) / 2; if table[m] < x { lo = m + 1 } else { hi = m } }
                return lo > 0 && abs(table[lo - 1] - x) < abs(table[lo] - x) ? lo - 1 : lo
            }
            var dropped = 0, gap = 0.0
            for (a, b) in zip(got, got.dropFirst()) { let sk = index(b.0) - index(a.0) - 1; if sk > 0 { dropped += sk }; gap = max(gap, b.1 - a.1) }
            rows.append([f.url.lastPathComponent, String(format: "%.1f s", secs), "\(got.count) / \(got.count + dropped)", "\(dropped)", Bench.ms(gap), String(format: "%.2f×", played / wall)])
        }
        r.table(["File", "Phát", "Giao / có trong file", "Rơi", "Khoảng cách lâu nhất", "Tốc độ phát thực"], rows)

        // ---- random access
        r.add("## 4b. Truy cập ngẫu nhiên: khung nào hệ thống giải mã được khi nhảy thẳng tới nó")
        r.add()
        r.add("Mọi khung (tối đa 1800 khung đầu của mỗi file) được yêu cầu riêng bằng `AVAssetImageGenerator` (dung sai 0). Khung không giải mã được sẽ không hiện khi tua/bước tới đó (xem hình đứng yên ở khung cũ), dù phát tuần tự và xuất vẫn đúng.")
        r.add()
        rows = []
        for f in infos {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: f.url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            g.maximumSize = CGSize(width: 480, height: 270)
            var bad: [Int] = []
            let probed = Array(f.times.prefix(1800))
            for (i, t) in probed.enumerated() { do { _ = try await g.image(at: t) } catch { bad.append(i) } }
            var groups: [[Int]] = []
            for i in bad { if let l = groups.last?.last, i == l + 1 { groups[groups.count - 1].append(i) } else { groups.append([i]) } }
            rows.append([f.url.lastPathComponent, "\(probed.count - bad.count)/\(probed.count)", bad.isEmpty ? "—" : "\(bad.count) khung, \(groups.count) nhóm; nhóm đầu: \(groups.first!.first!)…\(groups.first!.last!)\(groups.count > 1 ? ", cách \(groups[1].first! - groups[0].first!) khung" : "")"])
        }
        r.table(["File", "Giải mã được", "Không giải mã được"], rows)

        // ---- exports
        r.add("## 5. Xuất và đọc lại kết quả")
        r.add()
        r.add("Đoạn xuất: tối đa 240 khung bắt đầu từ khung 300 (hoặc từ một phần tư file nếu file ngắn). “Lệch hình” là sai khác độ sáng trung bình giữa khung kết quả và khung nguồn tương ứng, đo ở khung đầu, giữa và cuối đoạn trên hình **như hiển thị** (thang 0–255); cắt nhanh phải gần 0, mã hóa lại phải nhỏ. “Tiếng” là độ dài tiếng so với đoạn, độ lệch giữa đường độ to của kết quả và của nguồn (ms), và hệ số tương quan của hai đường đó. Với VFR, số khung kỳ vọng của xuất chính xác là độ dài đoạn nhân tốc độ khung của file kết quả.")
        r.add()
        rows = []
        for f in infos where f.times.count >= 60 {
            let n = f.times.count
            let a0 = min(300, n / 4), count = min(240, (n - a0 - 1) / 2)
            guard count >= 20 else { continue }
            let t0c = f.times[a0], t1c = f.times[a0 + count]
            let span = TimeSpan(start: MediaTime(value: t0c.value, timescale: t0c.timescale), end: MediaTime(value: t1c.value, timescale: t1c.timescale))
            let spanSeconds = t1c.seconds - t0c.seconds
            let src = await decode(f.url, from: t0c, frames: count, fps: f.fps, tenBit: f.hdr, keep: [0, count / 2, count - 1])
            let srcSound = f.audio ? await AudioEnvelope.read(f.url, from: t0c, duration: spanSeconds) : nil
            let srcWave = f.audio ? await AudioEnvelope.loadSamples(f.url, from: t0c, duration: spanSeconds) : nil
            struct Case { var label: String; var options: ExportOptions; var look: VideoLook }
            let same: VideoCodecChoice = f.codec == "avc1" ? .h264 : .hevc
            var cases: [Case] = [Case(label: "Cắt nhanh", options: ExportOptions(mode: .fast, container: .mp4, codec: same), look: VideoLook()),
                                 Case(label: "Chính xác, giữ cỡ", options: ExportOptions(mode: .exact, container: .mp4, codec: same), look: VideoLook())]
            if max(f.w, f.h) > 2500 { cases.append(Case(label: "Chính xác, 4K→1080p", options: ExportOptions(mode: .exact, container: .mp4, codec: .h264, resolution: .p1080), look: VideoLook())) }
            if !f.hdr && max(f.w, f.h) < 2500 {
                cases.append(Case(label: "Chính xác, đổi sang HEVC", options: ExportOptions(mode: .exact, container: .mp4, codec: .hevc), look: VideoLook()))
                var l = VideoLook(); l.color.brightness = 0.15
                cases.append(Case(label: "Chính xác + tăng sáng 0,15", options: ExportOptions(mode: .exact, container: .mp4, codec: .h264), look: l))
            }
            if f.hdr { cases.append(Case(label: "Chính xác, chọn H.264", options: ExportOptions(mode: .exact, container: .mp4, codec: .h264), look: VideoLook())) }
            var mirror = VideoLook(); mirror.flipHorizontal = true
            cases.append(Case(label: "Chính xác, lật ngang (qua compositor)", options: ExportOptions(mode: .exact, container: .mp4, codec: same), look: mirror))
            for c in cases {
                let out = workDir.appendingPathComponent("\(f.url.deletingPathExtension().lastPathComponent)-\(c.label.filter { $0.isLetter || $0.isNumber }).mp4")
                let t0 = Bench.now()
                do { try await RenderExporter().export(pieces: [RenderPiece(sourceURL: f.url, span: span, look: c.look)], to: out, options: c.options) }
                catch { rows.append([f.url.lastPathComponent, c.label, "LỖI: \(error)", "", "", "", "", "", "KHÔNG đạt"]); continue }
                let wall = Bench.now() - t0
                let oi = try await MediaProbe.probe(url: out); let ov = oi.primaryVideo
                let sameSize = ov?.width == f.w && ov?.height == f.h
                let dec = await decode(out, fps: f.fps, tenBit: f.hdr, keep: [0, count / 2, count - 1])
                let deltas = zip(dec.times, dec.times.dropFirst()).map { $1 - $0 }
                // Frames that should be there: a fast cut and a constant-rate file keep all of them; an exact cut of a VFR file is laid on its
                // output frame rate, so it has as many frames as the span is long.
                let outFps = ov?.frameRate?.framesPerSecond ?? f.fps
                let expected = (c.options.mode == .exact && f.vfr) ? Int((spanSeconds * outFps).rounded()) : count
                // No frame missing or doubled. The first gap may be shorter: a cut puts the grid half a frame early and the first frame sits at 0.
                let contiguous: Bool = {
                    if f.vfr { return !deltas.isEmpty && deltas.allSatisfy { $0 > 0 && $0 < 0.25 } }
                    return !deltas.isEmpty && deltas.dropFirst().allSatisfy { abs($0 - 1 / f.fps) < 0.5 / f.fps } && (deltas.first ?? 9) > 0 && (deltas.first ?? 9) <= 1.5 / f.fps
                }()
                let firstGap = deltas.first.map { String(format: "%.1f ms", $0 * 1000) } ?? "?"
                var diffs: [Double] = [], bright: [Double] = []
                if sameSize, !c.look.flipHorizontal, !f.vfr || c.options.mode == .fast { for k in [0, count / 2, count - 1] { if let x = src.luma[k], let y = dec.luma[k] { diffs.append(meanAbsDiff(x, y)); bright.append(mean(y) - mean(x)) } } }
                else if sameSize, !c.look.flipHorizontal { // a re-timed (VFR) cut has no one-to-one frames: compare the first frame, which is the same instant
                    if let x = src.luma[0], let y = dec.luma[0] { diffs.append(meanAbsDiff(x, y)); bright.append(mean(y) - mean(x)) }
                }
                // Frame identity through the compositor, pixel for pixel (a flipped picture moves pixels but keeps their values): which source frame
                // is each of the first, middle and last frames of the file? Expected: frames a0, a0+k, ... exactly.
                var identityNote = ""
                var identityOK = true
                if c.look.flipHorizontal, sameSize {
                    let lead = min(3, a0)
                    let win = await decode(f.url, from: f.times[a0 - lead], frames: count + lead + 4, fps: f.fps, tenBit: f.hdr, keep: Set(0..<(count + lead + 4)))
                    let od = await decode(out, fps: f.fps, tenBit: f.hdr, keep: [0, dec.times.count / 2, dec.times.count - 1], mirrorX: true)
                    var shifts: [Int] = []
                    for k in [0, dec.times.count / 2, dec.times.count - 1] {
                        guard let o = od.luma[k] else { continue }
                        // A VFR file is re-timed onto a fixed grid, so its k-th output frame is not its k-th source frame: only the first is compared there.
                        if f.vfr, k != 0 { continue }
                        let scored = (-3...3).compactMap { d -> (Int, Double)? in win.luma[k + lead + d].map { (d, meanAbsDiff($0, o)) } }
                        if let b = scored.min(by: { $0.1 < $1.1 }), let at0 = scored.first(where: { $0.0 == 0 }) { shifts.append(at0.1 <= b.1 + 0.15 ? 0 : b.0) }
                    }
                    identityNote = ", khung đầu/giữa/cuối lệch so với nguồn: \(shifts) khung"
                    identityOK = shifts.allSatisfy { $0 == 0 }
                }
                let depth = ov?.codec == "avc1" ? "8-bit" : await Bench.bitDepth(out)
                let dv = await dolbyVisionBoxes(out)
                var notes = "\(ov?.codec ?? "?") \(depth)" + identityNote
                if f.hdr { notes += ov?.isHDR == true ? ", giữ HDR \(ov?.transferFunction ?? "")" : ", MẤT HDR" }
                if !dv.isEmpty { notes += ", còn hộp \(dv.joined(separator: ","))"; if let q = await rpuFrames(out) { notes += q.withRPU == 0 ? " NHƯNG KHÔNG có dữ liệu RPU nào" : " (RPU \(q.withRPU)/\(q.total) khung)" } } else if (await dolbyVisionBoxes(f.url)).isEmpty == false { notes += ", mất hộp Dolby Vision" }
                if !sameSize { notes += ", \(ov?.width ?? 0)×\(ov?.height ?? 0)" }
                if (ov?.rotation ?? 0) != f.rotation { notes += ", xoay \(f.rotation)°→\(ov?.rotation ?? 0)° (hiển thị vẫn \(ov?.width ?? 0)×\(ov?.height ?? 0))" }
                if f.vfr { notes += ", VFR→\(ov?.isVariableFrameRate == true ? "VFR" : "CFR \(String(format: "%.2f", outFps)) fps")" }
                let isEdit = c.look.color.brightness != 0
                if c.options.mode == .exact, !isEdit, let worst = diffs.max(), worst > 4, let srcRate = (try? await MediaProbe.probe(url: f.url))?.primaryVideo?.bitrate {
                    let outRate = Double((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) * 8 / max(0.1, spanSeconds)
                    notes += String(format: ", CHẤT LƯỢNG GIẢM RÕ: %.1f Mb/s so với %.1f Mb/s của nguồn", outRate / 1e6, Double(srcRate) / 1e6)
                }
                let countOK = abs(dec.times.count - expected) <= (f.vfr && c.options.mode == .exact ? 1 : 0)
                var verdict = countOK && contiguous && abs(dec.times.first ?? 9) < 1 / f.fps + 0.001 ? "Đạt" : "KHÔNG đạt"
                if !identityOK { verdict = "KHÔNG đạt (sai khung)" }
                // The picture must match the source as displayed. A missing comparison is a failure, not a pass.
                if !sameSize && !(c.label.contains("1080p")) { verdict = "KHÔNG đạt" }
                if sameSize, !c.look.flipHorizontal {      // a mirrored picture is judged by frame identity above, pixel for pixel
                    if diffs.isEmpty || diffs.contains(where: { $0.isNaN }) { verdict = "KHÔNG đạt" }
                    else if !isEdit, let worst = diffs.max(), worst > (c.options.mode == .fast ? 0.5 : 8) { verdict = "KHÔNG đạt" }
                    if isEdit, let b = bright.min(), b < 5 { verdict = "KHÔNG đạt" }
                }
                // Sound: as long as the span (a cut puts its edges half a frame inside it on each side), and lined up with the source to within a frame.
                var soundCell = f.audio ? "?" : "(nguồn không có tiếng)"
                if f.audio {
                    if let o = await AudioEnvelope.read(out), let s = srcSound, let sw = srcWave, let ow = await AudioEnvelope.loadSamples(out) {
                        let lenDiff = (o.seconds - s.seconds) * 1000
                        let frameMs = 1000 / f.fps
                        let wave = AudioEnvelope.alignWaveforms(sw, ow, maxLagMs: 150)
                        soundCell = String(format: "dài %.2f s (đoạn %.2f s, %+.0f ms)", o.seconds, s.seconds, lenDiff)
                        if let w = wave { soundCell += String(format: ", lệch %+.1f ms (1 khung = %.1f ms), khớp sóng %.2f", w.lagMs, frameMs, w.correlation) } else { soundCell += ", im lặng nên không đo được độ lệch" }
                        let okLen = abs(lenDiff) <= 1.5 * frameMs + 20
                        // A stream-copy cut moves the sound's packets without touching them: that is checked on the bytes. A re-encoded one is
                        // checked on the waveform.
                        var copied: Bool?
                        if c.options.mode == .fast { copied = await AudioEnvelope.packetsCopied(from: f.url, into: out); soundCell += copied == true ? ", gói tiếng sao chép nguyên byte" : ", gói tiếng KHÔNG phải bản sao" }
                        let okAlign = c.options.mode == .fast ? (copied == true || wave == nil) : (wave == nil || (abs(wave!.lagMs) <= frameMs + 5 && wave!.correlation >= 0.4))
                        if !okLen || !okAlign { verdict = "KHÔNG đạt (tiếng)" }
                    } else { soundCell = "MẤT TIẾNG"; verdict = "KHÔNG đạt (mất tiếng)" }
                }
                rows.append([f.url.lastPathComponent, c.label, String(format: "%.2f s (%.1f×)", wall, spanSeconds / wall), Bench.mb(out),
                             "\(dec.times.count)/\(expected)\(contiguous ? "" : ", KHÔNG liên tục"), khoảng cách đầu \(firstGap)",
                             sameSize ? (isEdit ? String(format: "sáng hơn %.1f", bright.min() ?? .nan) : String(format: "%.2f", diffs.max() ?? .nan)) : "—", soundCell, notes, verdict])
                try? FileManager.default.removeItem(at: out)      // free the disk: the table keeps what was measured
            }
        }
        r.table(["File", "Kiểu", "Thời gian (hệ số)", "Kích thước", "Số khung", "Lệch hình", "Tiếng", "Ghi chú", "Kết quả"], rows)

        let md = r.lines.joined(separator: "\n") + "\n"
        try md.write(to: output, atomically: true, encoding: .utf8)
        print("\nwrote \(output.path)")
    }
}
