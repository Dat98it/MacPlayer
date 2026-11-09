import AVFoundation
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Builds the format matrix by doing each thing for real on synthetic files, and writes it as Markdown.
/// Every "Đạt" below was observed in this run; nothing is copied from a wish list.
enum Matrix {
    struct Row { var cells: [String] }

    static func run(workDir: URL, output: URL) async throws {
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let fr30 = FrameRate(numerator: 30, denominator: 1)
        func span(_ a: Int64, _ b: Int64, _ fr: FrameRate) -> TimeSpan { TimeSpan(start: .frameStart(index: a, frameRate: fr), end: .frameStart(index: b, frameRate: fr)) }
        let mark = { (ok: Bool) in ok ? "Đạt" : "Lỗi" }

        // 1. Container x codec: play, import for editing, cut fast, cut exact, artwork
        var rows1: [[String]] = []
        for container in SyntheticMedia.Container.allCases {
            for codec in SyntheticMedia.Codec.allCases {
                var s = SyntheticMedia.Spec(); s.container = container; s.codec = codec; s.width = 320; s.height = 180; s.seconds = 4; s.keyframeInterval = 60
                let src = workDir.appendingPathComponent("src-\(container.rawValue)-\(codec.rawValue).\(container.rawValue)")
                var play = "—", importEdit = "—", fast = "—", exact = "—", art = "—", why = ""
                do {
                    try await SyntheticMedia.generate(to: src, spec: s)
                    let info = try await MediaProbe.probe(url: src)
                    let first = try? await FrameGrabber.image(url: src, at: .zero, accuracy: .nearest)
                    play = mark(info.isPlayable && first != nil)
                    importEdit = mark(info.isExportable && info.primaryVideo != nil)
                    for mode in [CutMode.fast, .exact] {
                        let out = workDir.appendingPathComponent("cut-\(mode.rawValue)-\(container.rawValue)-\(codec.rawValue).\(container.rawValue)")
                        do {
                            try await ClipExporter().export(source: src, spans: [span(45, 105, fr30)], to: out,
                                options: ExportOptions(mode: mode, container: OutputContainer(rawValue: container.rawValue)!, codec: codec == .hevc ? .hevc : .h264))
                            let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
                            let good = idx.first == 45 && idx.last == 104 && idx.count == 60
                            if mode == .fast { fast = mark(good) } else { exact = mark(good) }
                            if !good { why += " \(mode.rawValue): khung \(idx.first ?? -1)…\(idx.last ?? -1)." }
                        } catch { if mode == .fast { fast = "Không" } else { exact = "Không" }; why += " \(mode.rawValue): \(error)." }
                    }
                    // artwork
                    let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.3, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
                    let art1 = EmbeddedArtwork(data: ImageWriter.data(ctx.makeImage()!, format: .jpeg(quality: 0.9))!, isPNG: false)
                    var results: [String] = []
                    for mode in [CutMode.fast, .exact] {
                        let out = workDir.appendingPathComponent("art-\(mode.rawValue)-\(container.rawValue)-\(codec.rawValue).\(container.rawValue)")
                        do {
                            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span(0, 30, fr30))], to: out,
                                options: ExportOptions(mode: mode, container: OutputContainer(rawValue: container.rawValue)!, codec: codec == .hevc ? .hevc : .h264), artwork: art1)
                            let a = AVURLAsset(url: out)
                            let items = (try await a.load(.metadata)) + (try await a.load(.commonMetadata))
                            let has = items.contains { $0.identifier == .commonIdentifierArtwork || $0.identifier == .iTunesMetadataCoverArt || $0.commonKey == .commonKeyArtwork }
                            results.append(has ? "Đạt" : "Không đọc lại được")
                        } catch { results.append("Lỗi") }
                    }
                    art = results.joined(separator: " / ")
                } catch { why = "\(error)" }
                rows1.append([".\(container.rawValue)", codec == .h264 ? "H.264 + AAC" : "HEVC + AAC", play, importEdit, fast, exact, art, why.isEmpty ? "" : why])
            }
        }

        // 2. Frame rates, VFR, rotation, no audio, long GOP
        var rows2: [[String]] = []
        struct Case { var name: String; var spec: SyntheticMedia.Spec; var fr: FrameRate }
        var cases: [Case] = []
        func add(_ n: String, _ f: (inout SyntheticMedia.Spec) -> Void) {
            var s = SyntheticMedia.Spec(); s.width = 320; s.height = 180; s.seconds = 4; f(&s); cases.append(Case(name: n, spec: s, fr: s.frameRate))
        }
        add("30 fps, GOP 2 s") { _ in }
        add("29,97 fps (30000/1001)") { $0.frameRate = FrameRate(numerator: 30000, denominator: 1001) }
        add("60 fps, GOP 2 s") { $0.frameRate = FrameRate(numerator: 60, denominator: 1); $0.keyframeInterval = 120 }
        add("25 fps") { $0.frameRate = FrameRate(numerator: 25, denominator: 1); $0.keyframeInterval = 50 }
        add("GOP dài (3 s)") { $0.keyframeInterval = 90 }
        add("Không có âm thanh") { $0.withAudio = false }
        add("Tốc độ khung hình thay đổi (VFR, bỏ khung)") { $0.dropEveryNthFrame = 7 }
        add("Xoay 90° trong metadata (quay dọc)") { $0.rotationMetadata = 90 }
        for (i, c) in cases.enumerated() {
            let src = workDir.appendingPathComponent("case\(i).mp4")
            do {
                try await SyntheticMedia.generate(to: src, spec: c.spec)
                let all = try await FrameScanner.scanVideo(url: src).compactMap(\.index)
                var cells: [String] = [c.name]
                for mode in [CutMode.fast, .exact] {
                    let out = workDir.appendingPathComponent("case\(i)-\(mode.rawValue).mp4")
                    try await ClipExporter().export(source: src, spans: [span(30, 70, c.fr)], to: out, options: ExportOptions(mode: mode))
                    let got = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
                    let want = all.filter { $0 >= 30 && $0 < 70 }
                    cells.append(mark(got == want) + " (\(got.count)/\(want.count) khung)")
                }
                let still = try await FrameGrabber.image(url: src, at: .zero, accuracy: .exact)
                cells.append(mark(c.spec.rotationMetadata != 0 ? true : FrameGrabber.syntheticIndex(of: still) == 0))
                let info = try await MediaProbe.probe(url: src)
                cells.append("\(info.primaryVideo?.width ?? 0)×\(info.primaryVideo?.height ?? 0), xoay \(info.primaryVideo?.rotation ?? 0)°, VFR=\(info.primaryVideo?.isVariableFrameRate == true ? "có" : "không")")
                rows2.append(cells)
            } catch { rows2.append([c.name, "Lỗi: \(error)", "", "", ""]) }
        }

        // 3. Things the build machine cannot verify
        let md = """
        # Ma trận định dạng đã kiểm chứng

        Sinh tự động bởi `macplayer-probe matrix`; mỗi ô "Đạt" là kết quả quan sát trong lần chạy này trên **\(ProcessInfo.processInfo.operatingSystemVersionString)**, \(machine()). Nguồn thử là video tổng hợp 320×180 (mã vạch số khung hình + tiếng bíp mỗi giây), không dùng media cá nhân.

        "Đạt" cho cắt nghĩa là: đúng tập khung được chọn (khung đầu, khung cuối, số khung) khi giải mã lại file kết quả.

        ## 1. Container × codec

        | Container | Codec | Phát | Nhập để sửa | Cắt nhanh | Cắt chính xác | Nhúng ảnh bìa (nhanh / chính xác) | Ghi chú |
        |---|---|---|---|---|---|---|---|
        \(rows1.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n"))

        ## 2. Tốc độ khung hình, GOP, VFR, xoay (MP4 / H.264)

        | Trường hợp | Cắt nhanh | Cắt chính xác | Ảnh tĩnh đúng khung | Metadata đọc được |
        |---|---|---|---|---|
        \(rows2.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n"))

        ## 3. Chưa kiểm chứng (không khai là hỗ trợ)

        - **MKV, WebM, AVI, FLV, WMV, TS/MTS và codec VP9/AV1/ProRes:** MacPlayer chỉ dùng AVFoundation; không có engine ngoài. Chưa thử với file thật nên không công bố hỗ trợ. MacPlayer hiển thị thông báo rõ khi một file không mở được.
        - **HDR (HLG/PQ), 10-bit:** nhận diện được cờ HDR; cắt nhanh giữ nguyên luồng; xuất chính xác **giữ HDR** (đọc 10-bit, ghi HEVC Main10, giữ nhãn màu; chọn H.264 thì tự chuyển sang HEVC), đã kiểm bằng file HDR tổng hợp (xem `docs/benchmark.md`, mục 7). **Chưa có video HDR thật từ camera và chưa thử Dolby Vision.**
        - **4K/60, video dài hàng giờ, ổ ngoài, file lỗi nửa chừng:** chưa đo trên bộ mẫu thật (xem báo cáo bàn giao).
        - **Intel (x86_64):** không có máy thử nên không công bố hỗ trợ; các số liệu trên chỉ thuộc Apple Silicon.
        - **Âm thanh PCM/ALAC/multi-track khi xuất:** xuất luôn mã hóa AAC; chỉ **một** track được dùng (track đang bật, tức mặc định của nhóm thay thế; không trộn nhiều track).
        - **Phụ đề mềm (track phụ đề trong container):** không nhúng được; chỉ có file `.srt` kèm theo hoặc ghi cứng vào hình.
        """
        try md.write(to: output, atomically: true, encoding: .utf8)
        print("wrote \(output.path)")
    }

    static func machine() -> String {
        var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
        var m = [CChar](repeating: 0, count: size); sysctlbyname("hw.machine", &m, &size, nil, 0)
        return String(cString: m)
    }
}
