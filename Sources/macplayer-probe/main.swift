import AVFoundation
import Foundation
import MacPlayerCore
import MacPlayerMedia

// macplayer-probe: media spikes for MacPlayer. Reads files, writes only into the folder you name.
//   macplayer-probe gen <out.mp4|mov> [h264|hevc] [seconds] [fps] [gop]
//   macplayer-probe info <file>
//   macplayer-probe spike <work-dir>        (generate, cut fast/exact, measure accuracy and A/V sync)

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: macplayer-probe gen|info|spike ...") }

func run() async throws {
    switch args[1] {
    case "gen":
        guard args.count >= 3 else { fail("gen <out> [h264|hevc] [seconds] [fps] [gop] [WxH]") }
        var s = SyntheticMedia.Spec()
        let url = URL(fileURLWithPath: args[2])
        s.container = SyntheticMedia.Container(rawValue: url.pathExtension.lowercased()) ?? .mp4
        if args.count > 3 { s.codec = SyntheticMedia.Codec(rawValue: args[3]) ?? .h264 }
        if args.count > 4 { s.seconds = Double(args[4]) ?? 10 }
        if args.count > 5 { s.frameRate = FrameRate(approximately: Double(args[5]) ?? 30) }
        if args.count > 6 { s.keyframeInterval = Int(args[6]) ?? 60 }
        if args.count > 7 { let wh = args[7].split(separator: "x").compactMap { Int($0) }; if wh.count == 2 { s.width = wh[0]; s.height = wh[1] } }
        try await SyntheticMedia.generate(to: url, spec: s)
        print("wrote \(url.path)")
    case "tags":
        // tags <sound>…: what MacPlayer reads from each sound (title, artist, album, artwork size). Only reads.
        for a in args.dropFirst(2) {
            let i = await AudioCover.info(of: URL(fileURLWithPath: a))
            print("\(URL(fileURLWithPath: a).lastPathComponent.prefix(45)) | title=\(i.title.prefix(60)) | artist=\(i.artist ?? "–") | album=\(i.album ?? "–") | artwork=\(i.artwork?.count ?? 0)")
        }
    case "cover":
        // cover <sound> <out-dir>: the video MacPlayer makes of a sound for a project (0.16), timed, with its size. The sound is only read.
        guard args.count >= 4 else { fail("cover <sound> <out-dir>") }
        AudioCover.cacheFolder = URL(fileURLWithPath: args[3], isDirectory: true)
        let src = URL(fileURLWithPath: args[2])
        let t0 = Date()
        let out = try await AudioCover.make(from: src)
        let took = Date().timeIntervalSince(t0)
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let srcSize = ((try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let a = try await MediaProbe.probe(url: src), b = try await MediaProbe.probe(url: out)
        print(String(format: "made %@ in %.1f s; %.1f MB (source %.1f MB); length %.3f s (source %.3f s); sound %@",
                     out.lastPathComponent, took, Double(size) / 1e6, Double(srcSize) / 1e6, b.duration.seconds, a.duration.seconds, b.audio.first?.codec ?? "none"))
    case "info":
        guard args.count >= 3 else { fail("info <file>") }
        let info = try await MediaProbe.probe(url: URL(fileURLWithPath: args[2]))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(info), as: UTF8.self))
    case "mkproject":
        // mkproject <video> <out.macplayer>: a one-clip project, for testing "open a project file" without the interface.
        guard args.count >= 4 else { fail("mkproject <video> <out.macplayer>") }
        let v = URL(fileURLWithPath: args[2])
        let info = try await MediaProbe.probe(url: v)
        let src = SourceRef(path: v.path, fingerprint: try? RealFileSystem().fingerprint(v.path), info: info)
        var p = Project(name: v.deletingPathExtension().lastPathComponent, kind: .video, sources: [src])
        p.timeline = [TimelineClip(sourceID: src.id, sourceStart: .zero, sourceEnd: info.duration, name: p.name)]
        p.activeClipID = p.timeline.first?.id
        try ProjectCodec.encode(p).write(to: URL(fileURLWithPath: args[3]))
        print("wrote \(args[3])")
    case "samples":
        guard args.count >= 3 else { fail("samples <file>") }
        if let r = try await SampleInspector.inspect(url: URL(fileURLWithPath: args[2])) {
            print("samples=\(r.sampleCount) sync=\(r.syncSampleCount) firstPTS=\(r.firstSampleTime) firstIsSync=\(r.firstSampleIsSync) size=\(r.width)x\(r.height) bytes=\(r.totalBytes)")
            for m in r.timeMappings { print("  edit: source \(m.source)+\(m.sourceDuration) -> target \(m.target)+\(m.targetDuration)") }
        }
    case "seekdiag":
        // seekdiag <file> <frame>: where does frame N really sit, and what do stills around that time return?
        guard args.count >= 4, let n = Int64(args[3]) else { fail("seekdiag <file> <frame>") }
        let url = URL(fileURLWithPath: args[2])
        let info = try await MediaProbe.probe(url: url)
        let fr = info.frameRateForStepping
        let frames = try await FrameScanner.scanVideo(url: url)
        if let f = frames.first(where: { $0.index == Int(n) }) { print("decoded frame \(n): pts=\(f.time.value)/\(f.time.timescale) = \(f.time.seconds)") }
        let asked = MediaTime.frameStart(index: n, frameRate: fr)
        print("asked  frameStart=\(asked.value)/\(asked.timescale) = \(asked.seconds)")
        for d in [-2.0, -1.0, 0.0, 1.0, 2.0] {
            let t = MediaTime(value: asked.value + Int64(d), timescale: asked.timescale)
            let img = try await FrameGrabber.image(url: url, at: t, accuracy: .exact)
            print("  still at \(t.value)/\(t.timescale) (\(d >= 0 ? "+" : "")\(Int(d)) tick) -> frame \(FrameGrabber.syntheticIndex(of: img).map(String.init) ?? "nil")")
        }
    case "matrix":
        guard args.count >= 4 else { fail("matrix <work-dir> <out.md>") }
        try await Matrix.run(workDir: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
    case "bench":
        guard args.count >= 4 else { fail("bench <work-dir> <out.md> [--quick]") }
        try await Bench.run(workDir: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]), quick: args.contains("--quick"))
    case "realcheck":
        guard args.count >= 5 else { fail("realcheck <folder-with-videos> <work-dir> <out.md> [--light]") }
        try await RealCheck.run(dir: URL(fileURLWithPath: args[2]), workDir: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4]), light: args.contains("--light"))
    case "rpu":
        // rpu <file>: does the file really carry Dolby Vision RPUs, or only the header that names them?
        guard args.count >= 3 else { fail("rpu <file>") }
        let u = URL(fileURLWithPath: args[2])
        print("boxes: \(await RealCheck.dolbyVisionBoxes(u))")
        if let q = await RealCheck.rpuFrames(u) { print("RPU in \(q.withRPU) of the first \(q.total) frames") } else { print("not HEVC") }
    case "cut":
        // cut <in> <out> <startSec> <endSec> [fast|exact] [h264|hevc]: one export through the same exporter the app uses.
        guard args.count >= 6, let a = Double(args[4]), let b = Double(args[5]) else { fail("cut <in> <out> <startSec> <endSec> [fast|exact] [h264|hevc]") }
        let mode: CutMode = args.count > 6 && args[6] == "fast" ? .fast : .exact
        let codec: VideoCodecChoice = args.count > 7 && args[7] == "h264" ? .h264 : .hevc
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: URL(fileURLWithPath: args[2]), span: TimeSpan(start: MediaTime(seconds: a), end: MediaTime(seconds: b)))], to: URL(fileURLWithPath: args[3]), options: ExportOptions(mode: mode, container: .mp4, codec: codec))
        print("wrote \(args[3])")
    case "decodescan":
        // decodescan <file> [video|audio]: decodes every frame / packet and says where (and with what error) decoding stops, if it does. Read only.
        guard args.count >= 3 else { fail("decodescan <file> [video|audio]") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
        for kind in (args.count > 3 ? [args[3]] : ["video", "audio"]) {
            guard let track = try await asset.loadTracks(withMediaType: kind == "video" ? .video : .audio).first else { print("\(kind): no track"); continue }
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = kind == "video"
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(out)
            let t0 = Date()
            guard reader.startReading() else { print("\(kind): cannot start: \(String(describing: reader.error))"); continue }
            var n = 0, last = 0.0, empty = 0
            while let sb = out.copyNextSampleBuffer() {
                last = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if CMSampleBufferGetNumSamples(sb) == 0 { empty += 1 }
                n += 1
            }
            print("\(kind): \(n) buffers (\(empty) empty), last time \(String(format: "%.3f", last)) s, status \(reader.status.rawValue) in \(String(format: "%.0f", Date().timeIntervalSince(t0))) s")
            if let e = reader.error as NSError? {
                print("  ERROR \(e.domain) \(e.code): \(e.localizedDescription)")
                if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { print("  underlying \(u.domain) \(u.code) (\(String(format: "0x%08X", UInt32(truncatingIfNeeded: u.code))))") }
            }
        }
    case "cutart":
        // cutart <in> <out> <startSec> <endSec> <artworkSec|none> [fast|exact]: like `cut` (H.264, MP4), with a frame embedded as cover art the way the app does it.
        guard args.count >= 7, let a = Double(args[4]), let b = Double(args[5]) else { fail("cutart <in> <out> <startSec> <endSec> <artworkSec|none> [fast|exact]") }
        var art: EmbeddedArtwork?
        if let t = Double(args[6]) {
            let img = try await FrameGrabber.image(url: URL(fileURLWithPath: args[2]), at: MediaTime(seconds: t), accuracy: .exact)
            art = ImageWriter.data(img, format: .jpeg(quality: 0.9)).map { EmbeddedArtwork(data: $0, isPNG: false) }
            print("artwork frame read: \(art?.data.count ?? 0) bytes")
        }
        let mode: CutMode = args.count > 7 && args[7] == "exact" ? .exact : .fast
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: URL(fileURLWithPath: args[2]), span: TimeSpan(start: MediaTime(seconds: a), end: MediaTime(seconds: b)))], to: URL(fileURLWithPath: args[3]), options: ExportOptions(mode: mode, container: .mp4, codec: .h264), artwork: art)
        print("wrote \(args[3])")
    case "cutframes":
        // cutframes <file> <firstFrame> <count> [brightness]: exports `count` frames from frame number `firstFrame` of the file's own table and says what came out.
        guard args.count >= 5, let a0 = Int(args[3]), let n = Int(args[4]) else { fail("cutframes <file> <firstFrame> <count> [brightness] [mirror]") }
        let u = URL(fileURLWithPath: args[2])
        let times = await RealCheck.frameTimes(u)
        guard a0 + n < times.count else { fail("the file has only \(times.count) frames") }
        var look = VideoLook()
        if args.count > 5, let b = Double(args[5]) { look.color.brightness = b }
        if args.count > 6, args[6] == "mirror" { look.flipHorizontal = true }
        let span = TimeSpan(start: MediaTime(value: times[a0].value, timescale: times[a0].timescale), end: MediaTime(value: times[a0 + n].value, timescale: times[a0 + n].timescale))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cutframes-\(UUID().uuidString.prefix(6)).mp4")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: u, span: span, look: look)], to: out, options: ExportOptions(mode: .exact, container: .mp4, codec: .h264))
        let fps = (try await MediaProbe.probe(url: u)).primaryVideo?.frameRate?.framesPerSecond ?? 30
        let dec = (await RealCheck.decode(out, fps: fps, tenBit: false, keep: [])).times.map { CMTime(seconds: $0, preferredTimescale: 60000) }
        print(String(format: "source: frames %d..%d at %.5f fps, span %.5f–%.5f s (%.5f s = %.3f frames)", a0, a0 + n, fps, span.start.seconds, span.end.seconds, span.duration.seconds, span.duration.seconds * fps))
        print("source frame times around the start: \(times[max(0, a0 - 1)...a0 + 2].map { String(format: "%.5f", $0.seconds) })")
        print("source frame times around the end:   \(times[(a0 + n - 2)...(a0 + n + 1)].map { String(format: "%.5f", $0.seconds) })")
        print("output: \(dec.count) frames; first \(dec.prefix(3).map { String(format: "%.5f", $0.seconds) }), last \(dec.suffix(3).map { String(format: "%.5f", $0.seconds) })")
        // How close the picture is to the source frames it was cut from (mean absolute luma difference, 0-255).
        let mirror = args.count > 6 && args[6] == "mirror"
        let srcD = await RealCheck.decode(u, from: times[max(0, a0 - 3)], frames: n + 8, fps: fps, tenBit: false, keep: Set(0..<(n + 8)))
        let outD = await RealCheck.decode(out, fps: fps, tenBit: false, keep: [0, dec.count / 2, dec.count - 1], mirrorX: mirror)
        // Source frame k of the span sits at index k + lead in `srcD` (the reader starts at frame a0-3, but may begin a frame or two off).
        let lead = a0 >= 3 ? 3 : a0
        func best(_ outIndex: Int, expected: Int) -> String {
            guard let o = outD.luma[outIndex] else { return "?" }
            let scored = (-3...3).compactMap { δ -> (Int, Double)? in srcD.luma[expected + lead + δ].map { (δ, RealCheck.meanAbsDiff($0, o)) } }
            let b = scored.min { $0.1 < $1.1 }!
            return "best match is source frame \(b.0 >= 0 ? "+" : "")\(b.0) from the expected (\(String(format: "%.2f", b.1)); at the expected \(String(format: "%.2f", scored.first { $0.0 == 0 }?.1 ?? .nan)))"
        }
        print("first frame: \(best(0, expected: 0))")
        print("middle frame: \(best(dec.count / 2, expected: dec.count / 2))")
        print("last frame: \(best(dec.count - 1, expected: dec.count - 1))")
        try? FileManager.default.removeItem(at: out)
    case "spike":
        guard args.count >= 3 else { fail("spike <work-dir>") }
        try await Spike.run(workDir: URL(fileURLWithPath: args[2]))
    default:
        fail("unknown command \(args[1])")
    }
}

do { try await run() } catch { fail("error: \(error)") }
