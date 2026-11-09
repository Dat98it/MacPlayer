import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

func peakLevel(_ u: URL) async throws -> Float {
    let a = AVURLAsset(url: u)
    guard let t = try await a.loadTracks(withMediaType: .audio).first else { return 0 }
    let r = try AVAssetReader(asset: a)
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
    r.add(o); r.startReading()
    var p: Float = 0
    while let sb = o.copyNextSampleBuffer(), let b = CMSampleBufferGetDataBuffer(sb) {
        let n = CMBlockBufferGetDataLength(b)
        var d = [Float](repeating: 0, count: n / 4)
        d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
        p = max(p, d.map(abs).max() ?? 0)
    }
    return p
}

private func firstOnset(_ u: URL) async throws -> Double? { try await FrameScanner.beepOnsets(url: u).first?.seconds }

@Suite(.serialized) struct SoundControlTests {
    private func export(_ src: URL, audio: AudioSettings = AudioSettings(), replacement: URL? = nil, name: String) async throws -> URL {
        var a = audio; a.replacementPath = replacement?.path
        let out = Fixtures.shared.outputURL(name)
        let recipe = RenderRecipe(audio: a)
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 90), audio: audio)], recipe: recipe, to: out, options: ExportOptions(mode: .exact))
        return out
    }

    @Test func delayingTheSoundMovesItLaterAndAdvancingMovesItEarlier() async throws {
        let src = try await Fixtures.shared.source()
        let base = try #require(try await firstOnset(try await export(src, name: "off0")))
        var later = AudioSettings(); later.offsetSeconds = 0.2
        let delayed = try #require(try await firstOnset(try await export(src, audio: later, name: "off+")))
        #expect(abs(base) < 0.03 && abs(delayed - 0.2) < 0.03, "base \(base), +0.2 s gives \(delayed)")
        var earlier = AudioSettings(); earlier.offsetSeconds = -0.1
        let advanced = try #require(try await firstOnset(try await export(src, audio: earlier, name: "off-")))
        // The first beep is 0..0.1 s; starting the sound 0.1 s into the source skips it, so the next one (at 1 s) lands at 0.9 s.
        #expect(abs(advanced - 0.9) < 0.03, "-0.1 s gives \(advanced)")
    }

    @Test func aReplacementSoundtrackReplacesTheOriginal() async throws {
        let src = try await Fixtures.shared.source()
        let rep = Fixtures.shared.outputURL("replacement", ext: "m4a")
        try await AudioExporter.export(source: src, span: TimeSpan(start: MediaTime(seconds: 0.5, timescale: 600), end: MediaTime(seconds: 3.5, timescale: 600)), audio: AudioSettings(), to: rep)
        let out = try await export(src, replacement: rep, name: "rep")
        let t = try #require(try await firstOnset(out))
        #expect(abs(t - 0.5) < 0.05, "the replacement starts 0.5 s into the beep pattern, so its first beep is at ~0.5 s, not 0: \(t)")
        // A silent source gets a soundtrack too.
        let silent = try await Fixtures.shared.source(.init(audio: false))
        let out2 = try await export(silent, replacement: rep, name: "rep2")
        #expect(try await MediaProbe.probe(url: out2).hasAudio)
    }

    @Test func aFastCutRefusesASoundChange() async throws {
        let src = try await Fixtures.shared.source()
        var a = AudioSettings(); a.offsetSeconds = 0.1
        await #expect(throws: ExportError.self) {
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 30), audio: a)], recipe: RenderRecipe(audio: a), to: Fixtures.shared.outputURL("nofast2"), options: ExportOptions(mode: .fast))
        }
    }

    @Test func audioOnlyExportIsAnM4aWithTheRightLengthAndLevel() async throws {
        let src = try await Fixtures.shared.source()
        let span = TimeSpan(start: MediaTime(seconds: 1, timescale: 600), end: MediaTime(seconds: 3, timescale: 600))
        let a = Fixtures.shared.outputURL("audio", ext: "m4a")
        try await AudioExporter.export(source: src, span: span, audio: AudioSettings(), to: a)
        let info = try await MediaProbe.probe(url: a)
        #expect(!info.hasVideo && info.hasAudio && abs(info.duration.seconds - 2) < 0.1, "audio only, 2 s: \(info.duration.seconds)")
        var quiet = AudioSettings(); quiet.gainDB = -12
        let q = Fixtures.shared.outputURL("audio-q", ext: "m4a")
        try await AudioExporter.export(source: src, span: span, audio: quiet, to: q)
        let loud = try await peakLevel(a), low = try await peakLevel(q)
        #expect(low < loud * 0.4 && low > loud * 0.15, "-12 dB: \(loud) -> \(low)")
        var muted = AudioSettings(); muted.muted = true
        let m = Fixtures.shared.outputURL("audio-m", ext: "m4a")
        try await AudioExporter.export(source: src, span: span, audio: muted, to: m)
        #expect(try await peakLevel(m) < 0.01, "muted is silent")
    }

    @Test func audioOnlyExportRefusesExistingFilesAndSilentSources() async throws {
        let src = try await Fixtures.shared.source()
        let exists = Fixtures.shared.outputURL("exists", ext: "m4a"); try Data("keep".utf8).write(to: exists)
        await #expect(throws: ExportError.self) { try await AudioExporter.export(source: src, span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)), audio: AudioSettings(), to: exists) }
        #expect(try String(contentsOf: exists, encoding: .utf8) == "keep")
        let silent = try await Fixtures.shared.source(.init(audio: false))
        await #expect(throws: ExportError.self) { try await AudioExporter.export(source: silent, span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)), audio: AudioSettings(), to: Fixtures.shared.outputURL("none", ext: "m4a")) }
    }
}

@Suite(.serialized) struct StillImageTests {
    private func size(_ u: URL) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    @Test func aStillIsTheRequestedFrameInTheRequestedShapeAndFormat() async throws {
        let src = try await Fixtures.shared.source()   // 320x180
        let png = Fixtures.shared.outputURL("still", ext: "png")
        try await StillExporter.export(source: src, at: fr30(45), format: .png, to: png)
        #expect(size(png)! == (320, 180))
        #expect(try Data(contentsOf: png).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "a real PNG")
        let img = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL, nil)!, 0, nil))
        #expect(FrameGrabber.syntheticIndex(of: img) == 45, "it is frame 45")

        let sq = Fixtures.shared.outputURL("still-sq", ext: "jpg")
        try await StillExporter.export(source: src, at: fr30(10), aspect: .square1x1, format: .jpeg(quality: 0.9), to: sq)
        #expect(size(sq)! == (180, 180))
        #expect(try Data(contentsOf: sq).prefix(3) == Data([0xFF, 0xD8, 0xFF]), "a real JPEG")
        let tall = Fixtures.shared.outputURL("still-tall", ext: "png")
        try await StillExporter.export(source: src, at: fr30(10), aspect: .portrait9x16, format: .png, to: tall)
        let t = size(tall)!; #expect(abs(Double(t.0) / Double(t.1) - 9.0 / 16) < 0.01 && t.1 == 180)
        let small = Fixtures.shared.outputURL("still-small", ext: "png")
        try await StillExporter.export(source: src, at: fr30(10), format: .png, maxWidth: 160, to: small)
        #expect(size(small)! == (160, 90), "scaled down, shape kept")
    }

    @Test func overwritingKeepsTheOldImageIfTheNewOneFails() async throws {
        let src = try await Fixtures.shared.source()
        let dest = Fixtures.shared.outputURL("still-keep", ext: "png")
        try Data("old image".utf8).write(to: dest)
        await #expect(throws: (any Error).self) { try await StillExporter.export(source: src, at: MediaTime(seconds: 999), format: .png, to: dest) } // past the end
        #expect(try String(contentsOf: dest, encoding: .utf8) == "old image")
        let dir = dest.deletingLastPathComponent().path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains("still-keep") && $0.contains(".macplayer-") }.isEmpty)
    }
}

private func rms(_ u: URL, from: Double, to: Double) async throws -> Float {
    let a = AVURLAsset(url: u)
    guard let t = try await a.loadTracks(withMediaType: .audio).first else { return 0 }
    let r = try AVAssetReader(asset: a)
    r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
    r.add(o); r.startReading()
    var sum: Float = 0, n = 0
    while let sb = o.copyNextSampleBuffer(), let b = CMSampleBufferGetDataBuffer(sb) {
        let len = CMBlockBufferGetDataLength(b)
        var d = [Float](repeating: 0, count: len / 4)
        d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        for v in d { sum += v * v }; n += d.count
    }
    return n == 0 ? 0 : (sum / Float(n)).squareRoot()
}

@Suite(.serialized) struct AudioTrackTests {
    private func make(alternate: Bool) async throws -> URL {
        var spec = SyntheticMedia.Spec(); spec.container = .mov; spec.width = 320; spec.height = 180; spec.seconds = 3
        spec.secondAudioTrack = true; spec.alternateAudioTracks = alternate
        let src = Fixtures.shared.outputURL("twoaudio-\(alternate)", ext: "mov")
        try await SyntheticMedia.generate(to: src, spec: spec)
        return src
    }

    @Test func alternativeTracksAreOfferedForChoosingAndOnlyTheDefaultIsExported() async throws {
        let src = try await make(alternate: true)
        #expect(try await MediaProbe.probe(url: src).audio.count == 2)
        let group = try await AVURLAsset(url: src).loadMediaSelectionGroup(for: .audible)
        #expect(group?.options.count == 2, "the player offers both")
        let out = Fixtures.shared.outputURL("alt-out")
        try await ClipExporter().export(source: src, spans: [span30(0, 60)], to: out, options: ExportOptions(mode: .exact))
        do {
            let quiet = try await rms(out, from: 1.2, to: 1.8)
            #expect(quiet < 0.02, "between beeps the default track is silent: the 440 Hz alternative is not mixed in (rms \(quiet))")
        } catch { Issue.record("measuring the exported sound failed: \(error)") }
        #expect(try await FrameScanner.beepOnsets(url: out).count >= 1)
    }

    @Test func tracksThatAreNotAlternativesPlayTogetherInTheExportAsTheyDoInThePlayer() async throws {
        let src = try await make(alternate: false)
        let group = try await AVURLAsset(url: src).loadMediaSelectionGroup(for: .audible)
        #expect(group == nil, "no choice is offered: the player plays both")
        let out = Fixtures.shared.outputURL("mixed-out")
        try await ClipExporter().export(source: src, spans: [span30(0, 60)], to: out, options: ExportOptions(mode: .exact))
        #expect(try await rms(out, from: 1.2, to: 1.8) > 0.1, "the continuous 440 Hz track is heard between the beeps")
        #expect(try await MediaProbe.probe(url: out).audio.count == 1, "mixed into one track")
        var quiet = AudioSettings(); quiet.muted = true
        let muted = Fixtures.shared.outputURL("mixed-muted")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 60), audio: quiet)], recipe: RenderRecipe(audio: quiet), to: muted, options: ExportOptions(mode: .exact))
        #expect(try await peakLevel(muted) < 0.01, "muting silences every track")
    }
}

@Suite(.serialized) struct FileNameTests {
    private let fs = RealFileSystem()

    @Test func vietnameseNamesWorkInBothUnicodeFormsForCopyAndReplace() async throws {
        let master = try await Fixtures.shared.source()
        let dir = Fixtures.shared.root.appendingPathComponent("tên-thư-mục Việt \(UUID().uuidString.prefix(4))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nfc = "Bài giảng – Phần 1 (tập 2) ✓.mp4"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        for (i, name) in [nfc, nfd].enumerated() {
            let src = dir.appendingPathComponent(i == 0 ? name : "x" + name)
            try FileManager.default.copyItem(at: master, to: src)
            let saver = SafeSaver(fs: fs, journalFolder: dir.appendingPathComponent("journal").path)
            let runner = ExportRunner(saver: saver, fs: fs)
            let dest = dir.appendingPathComponent("Phỏng vấn – bản cắt \(i).mp4")
            let job = ExportJob(label: "v", pieces: [JobPiece(sourcePath: src.path, span: span30(30, 90))], options: ExportOptions(mode: .exact), target: .newCopy(path: dest.path, overwrite: false))
            let r = try await runner.run(job: job)
            #expect(r.outcome.finalPath == dest.path && FileManager.default.fileExists(atPath: dest.path))
            #expect(try await FrameScanner.scanVideo(url: dest).compactMap(\.index) == Array(30..<90))
            // Replace the original under that name, with a backup kept beside it.
            let fp = try fs.fingerprint(src.path)
            let rj = ExportJob(label: "r", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 30))], options: ExportOptions(mode: .exact), target: .replaceOriginal(path: src.path, expected: fp, backupFolder: dir.appendingPathComponent("Bản sao lưu").path))
            let rr = try await runner.run(job: rj)
            #expect(try await FrameScanner.scanVideo(url: src).compactMap(\.index) == Array(0..<30))
            #expect(rr.outcome.backupPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        }
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.contains(".macplayer-") }
        #expect(leftovers.isEmpty, "no temp files: \(leftovers)")
    }
}

@Suite(.serialized) struct DamagedFileTests {
    private let fs = RealFileSystem()

    private func runner(_ dir: URL) -> ExportRunner {
        ExportRunner(saver: SafeSaver(fs: fs, journalFolder: dir.appendingPathComponent("journal").path), fs: fs)
    }

    private func folder(_ n: String) throws -> URL {
        let u = Fixtures.shared.root.appendingPathComponent("\(n)-\(UUID().uuidString.prefix(5))", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    private func attempt(_ src: URL, in dir: URL) async -> (error: Error?, out: URL) {
        let out = dir.appendingPathComponent("out.mp4")
        let job = ExportJob(label: "d", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 60))], options: ExportOptions(mode: .exact), target: .newCopy(path: out.path, overwrite: false))
        do { _ = try await runner(dir).run(job: job); return (nil, out) } catch { return (error, out) }
    }

    @Test func aTruncatedFileFailsCleanlyAndIsLeftAlone() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try folder("trunc")
        let src = dir.appendingPathComponent("cut-off.mp4")
        let data = try Data(contentsOf: master)
        try data.prefix(data.count * 2 / 5).write(to: src)
        let before = try Data(contentsOf: src)
        let r = await attempt(src, in: dir)
        #expect(r.error != nil, "a file with its end missing cannot be exported")
        #expect(!FileManager.default.fileExists(atPath: r.out.path))
        #expect(try Data(contentsOf: src) == before)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".macplayer-") }.isEmpty)
    }

    @Test func aFileWithDamagedBytesInTheMiddleNeverCrashesAndNeverLeavesAFalseResult() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try folder("damaged")
        let src = dir.appendingPathComponent("glitch.mp4")
        var data = try Data(contentsOf: master)
        let mid = data.count / 2
        for i in mid..<min(data.count, mid + 20_000) { data[i] = UInt8.random(in: 0...255) }
        try data.write(to: src)
        let r = await attempt(src, in: dir)
        if r.error == nil {
            // It exported: then the result must be a file that passed the check, not a partial.
            let info = try await MediaProbe.probe(url: r.out)
            #expect(info.hasVideo && info.duration.seconds > 1, "a success must be a readable file")
        } else {
            #expect(!FileManager.default.fileExists(atPath: r.out.path), "a failure leaves no output")
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".macplayer-") }.isEmpty)
    }

    @Test func emptyAndMisnamedFilesAreRefusedWithAReason() async throws {
        let dir = try folder("junk")
        let empty = dir.appendingPathComponent("empty.mp4"); try Data().write(to: empty)
        let text = dir.appendingPathComponent("notes.mov"); try Data("hello".utf8).write(to: text)
        for f in [empty, text] {
            await #expect(throws: MediaProbeError.self) { _ = try await MediaProbe.probe(url: f) }
            #expect(await attempt(f, in: dir).error != nil)
        }
    }

    @Test func aSourceWithNoPermissionIsReportedAndNothingIsWritten() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try folder("noperm")
        let src = dir.appendingPathComponent("locked.mp4"); try FileManager.default.copyItem(at: master, to: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: src.path) }
        let r = await attempt(src, in: dir)
        #expect(r.error != nil && !FileManager.default.fileExists(atPath: r.out.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".macplayer-") }.isEmpty)
    }

    @Test func aReadOnlySourceCannotBeReplacedButCanBeCopied() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try folder("readonly-src")
        let src = dir.appendingPathComponent("ro.mp4"); try FileManager.default.copyItem(at: master, to: src)
        let fp = try fs.fingerprint(src.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: src.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let rj = ExportJob(label: "r", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 30))], options: ExportOptions(mode: .exact), target: .replaceOriginal(path: src.path, expected: fp, backupFolder: nil))
        await #expect(throws: SaveError.self) { _ = try await runner(dir).run(job: rj) }
        #expect(try fs.fingerprint(src.path) == fp, "the original is as it was")
        let other = try folder("copy-target")
        let cj = ExportJob(label: "c", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 30))], options: ExportOptions(mode: .exact), target: .newCopy(path: other.appendingPathComponent("c.mp4").path, overwrite: false))
        _ = try await runner(other).run(job: cj)
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("c.mp4").path), "copying from a read-only file is fine")
    }
}

/// A real, small disk: created and mounted with hdiutil, so "disk full", "read-only" and "unplugged while writing" are the
/// operating system's own, not simulated.
final class DiskImage {
    let mount: URL
    private let image: URL
    private(set) var attached = true

    init(megabytes: Int, readOnly: Bool = false) throws {
        let base = Fixtures.shared.root.appendingPathComponent("disk-\(UUID().uuidString.prefix(6))", isDirectory: true)
        mount = base.appendingPathComponent("mnt", isDirectory: true)
        image = base.appendingPathComponent("d.dmg")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run(["create", "-size", "\(megabytes)m", "-fs", "HFS+J", "-volname", "MVTest", "-ov", image.path])
        var args = ["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-noverify", "-noautoopen"]
        if readOnly { args.append("-readonly") }
        try Self.run(args)
    }

    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw NSError(domain: "hdiutil", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out]) }
        return out
    }

    var freeBytes: Int64 { ((try? FileManager.default.attributesOfFileSystem(forPath: mount.path))?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 }

    /// Fills the disk until about `leaving` bytes are left.
    func fill(leaving: Int64) throws {
        let filler = mount.appendingPathComponent("filler.bin")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let h = try FileHandle(forWritingTo: filler)
        // `volumeAvailableCapacity` is cached and runs ahead of the writes; the file system's own figure is exact.
        func free() -> Int64 { ((try? FileManager.default.attributesOfFileSystem(forPath: mount.path))?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 }
        while free() > leaving {
            let n = Int(min(64 * 1024, free() - leaving))
            guard n > 0 else { break }
            do { try h.write(contentsOf: Data(repeating: 7, count: n)) } catch { break }   // the disk is as full as it gets
        }
        try? h.synchronize(); try? h.close()
    }

    func detach(force: Bool = false) {
        guard attached else { return }
        attached = false
        _ = try? Self.run(["detach", mount.path] + (force ? ["-force"] : []))
    }

    deinit { if attached { _ = try? Self.run(["detach", mount.path, "-force"]) } }
}

@Suite(.serialized) struct RealDiskTests {
    private let fs = RealFileSystem()

    private func runner(_ journal: URL) -> (ExportRunner, SafeSaver) {
        let s = SafeSaver(fs: fs, journalFolder: journal.path); return (ExportRunner(saver: s, fs: fs), s)
    }

    private func big() async throws -> URL { try await Fixtures.shared.source(.init(seconds: 4, width: 1280, height: 720)) }

    private func leftovers(_ d: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.contains(".macplayer-") } }

    @Test func aFullDiskIsRefusedBeforeAnyWorkStarts() async throws {
        let disk = try DiskImage(megabytes: 8); defer { disk.detach(force: true) }
        try disk.fill(leaving: 60_000)
        let src = try await big()
        let (runner, _) = runner(Fixtures.shared.root.appendingPathComponent("j1"))
        let dest = disk.mount.appendingPathComponent("out.mp4")
        let job = ExportJob(label: "f", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 120))], options: ExportOptions(mode: .exact), target: .newCopy(path: dest.path, overwrite: false))
        do { _ = try await runner.run(job: job); Issue.record("expected a space error") }
        catch let e as SaveError { if case .notEnoughSpace = e {} else { Issue.record("wrong error \(e)") } }
        #expect(!FileManager.default.fileExists(atPath: dest.path) && leftovers(disk.mount).isEmpty)
    }

    @Test func runningOutOfSpaceWhileWritingFailsCleanlyAndLeavesNothing() async throws {
        let disk = try DiskImage(megabytes: 8); defer { disk.detach(force: true) }
        try disk.fill(leaving: 300_000)          // less than the ~1.6 MB the export needs, but the estimate below says 1 byte
        let src = try await big()
        let (_, saver) = runner(Fixtures.shared.root.appendingPathComponent("j2"))
        let dest = disk.mount.appendingPathComponent("out.mp4")
        let pieces = [RenderPiece(sourceURL: src, span: span30(0, 120))]
        do {
            _ = try await saver.saveCopy(sourcePath: src.path, destination: dest.path, overwrite: false, estimatedBytes: 1,
                produce: { temp in try await RenderExporter().export(pieces: pieces, to: URL(fileURLWithPath: temp), options: ExportOptions(mode: .exact)) },
                verify: { _ in })
            Issue.record("the disk is too small, this cannot succeed")
        } catch { /* any failure is right; what matters is what is left behind */ }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "no half file under the real name")
        #expect(leftovers(disk.mount).isEmpty, "the partial temp file is removed: \(leftovers(disk.mount))")
        #expect(FileManager.default.fileExists(atPath: disk.mount.appendingPathComponent("filler.bin").path), "the disk is still fine")
    }

    @Test func aReadOnlyDiskIsReportedBeforeAnything() async throws {
        let disk = try DiskImage(megabytes: 8, readOnly: true); defer { disk.detach(force: true) }
        let src = try await Fixtures.shared.source()
        let (runner, _) = runner(Fixtures.shared.root.appendingPathComponent("j3"))
        let dest = disk.mount.appendingPathComponent("out.mp4")
        let job = ExportJob(label: "ro", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 30))], options: ExportOptions(mode: .exact), target: .newCopy(path: dest.path, overwrite: false))
        await #expect(throws: SaveError.destinationFolderNotWritable(disk.mount.path)) { _ = try await runner.run(job: job) }
    }

    @Test func unpluggingTheDiskWhileWritingNeitherCrashesNorHangsNorHurtsTheSource() async throws {
        let disk = try DiskImage(megabytes: 40); defer { disk.detach(force: true) }
        let src = try await big()
        let before = try Data(contentsOf: src)
        let (runner, _) = runner(Fixtures.shared.root.appendingPathComponent("j4"))
        let dest = disk.mount.appendingPathComponent("out.mp4")
        let job = ExportJob(label: "u", pieces: [JobPiece(sourcePath: src.path, span: span30(0, 120))], options: ExportOptions(mode: .exact), target: .newCopy(path: dest.path, overwrite: false))
        let started = Date()
        let task = Task { () -> Bool in do { _ = try await runner.run(job: job); return true } catch { return false } }
        try await Task.sleep(nanoseconds: 150_000_000)
        disk.detach(force: true)
        let finished = await withTaskGroup(of: Bool?.self) { g -> Bool? in
            g.addTask { await task.value }
            g.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll(); return first
        }
        #expect(finished != nil, "the export ended (success or failure) instead of hanging; took \(Date().timeIntervalSince(started)) s")
        #expect(try Data(contentsOf: src) == before, "the source, on another disk, is untouched")
    }
}

// MARK: HDR sources

private func bitsPerComponent(_ u: URL) async throws -> Int? {
    let a = AVURLAsset(url: u)
    guard let t = try await a.loadTracks(withMediaType: .video).first, let fd = try await t.load(.formatDescriptions).first,
          let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] else { return nil }
    return (ext["BitsPerComponent"] as? NSNumber)?.intValue
}

/// An HDR source (HEVC Main10, BT.2020, HLG or PQ) must stay HDR when exported with re-encoding: 10 bits, same colour tags.
/// Found by the benchmark: it used to come out as 8-bit HEVC with HDR tags, while the interface said "converted to SDR".
@Suite(.serialized) struct HDRSourceTests {
    private func hdrSource(_ kind: SyntheticMedia.Spec.HDRKind) async throws -> URL {
        var s = SyntheticMedia.Spec(); s.container = .mov; s.codec = .hevc; s.width = 320; s.height = 180; s.seconds = 3; s.keyframeInterval = 30; s.hdr = kind
        let u = Fixtures.shared.outputURL("hdr-src-\(kind)", ext: "mov")
        try await SyntheticMedia.generate(to: u, spec: s)
        return u
    }

    @Test func theGeneratedSourceIsReallyTenBitAndDetectedAsHDR() async throws {
        for kind in [SyntheticMedia.Spec.HDRKind.hlg, .pq] {
            let src = try await hdrSource(kind)
            #expect(try await bitsPerComponent(src) == 10)
            let v = try #require(try await MediaProbe.probe(url: src).primaryVideo)
            #expect(v.isHDR)
            #expect(v.transferFunction == (kind == .hlg ? "ITU_R_2100_HLG" : "SMPTE_ST_2084_PQ"))
        }
    }

    @Test func exactExportKeepsTenBitsAndTheHDRTags() async throws {
        for kind in [SyntheticMedia.Spec.HDRKind.hlg, .pq] {
            let src = try await hdrSource(kind)
            let src0 = try #require(try await MediaProbe.probe(url: src).primaryVideo)
            // Asking for H.264 must not lose the HDR: it is written as HEVC.
            for codec in [VideoCodecChoice.hevc, .h264] {
                let out = Fixtures.shared.outputURL("hdr-out", ext: "mov")
                try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(15, 75))], to: out, options: ExportOptions(mode: .exact, container: .mov, codec: codec))
                let v = try #require(try await MediaProbe.probe(url: out).primaryVideo)
                #expect(v.codec == "hvc1", "HDR is written as HEVC even when \(codec) is chosen")
                #expect(try await bitsPerComponent(out) == 10, "10-bit, not squeezed into 8")
                #expect(v.isHDR && v.transferFunction == src0.transferFunction && v.colorPrimaries == src0.colorPrimaries)
                let idx = try await FrameScanner.scanVideo(url: out).compactMap(\.index)
                #expect(idx.count == 60 && idx.first == 15 && idx.last == 74, "frames are still exact: \(idx.first ?? -1)…\(idx.last ?? -1) (\(idx.count))")
            }
        }
    }

    @Test func editedHDRStaysTenBitToo() async throws {
        let src = try await hdrSource(.hlg)
        var look = VideoLook(); look.color.brightness = 0.1
        let out = Fixtures.shared.outputURL("hdr-edit", ext: "mov")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(15, 75), look: look)], to: out, options: ExportOptions(mode: .exact, container: .mov, codec: .hevc))
        let v = try #require(try await MediaProbe.probe(url: out).primaryVideo)
        #expect(try await bitsPerComponent(out) == 10)
        #expect(v.isHDR)
        // The colour change makes the barcode harder to read, so count frames rather than reading their numbers.
        #expect(try await FrameScanner.scanVideo(url: out).count == 60)
    }

    /// Mean luma (0-255) of the nth decoded frame, read as 8-bit.
    private func meanLuma(_ url: URL, frame n: Int) async throws -> Double {
        let a = AVURLAsset(url: url)
        let t = try #require(try await a.loadTracks(withMediaType: .video).first)
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        r.add(o); r.startReading()
        var i = 0
        while let sb = o.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if i == n {
                CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
                var sum = 0.0, count = 0.0
                for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) { sum += Double(base[y * row + x]); count += 1 } }
                return sum / count
            }
            i += 1
        }
        return .nan
    }

    @Test func editedHDRKeepsItsPictureNotJustItsTags() async throws {
        // Through the compositor the HDR pictures used to arrive as tone-mapped SDR and leave tagged HDR: right tags, wrong picture (20-30 levels off).
        for kind in [SyntheticMedia.Spec.HDRKind.hlg, .pq] {
            let src = try await hdrSource(kind)
            var look = VideoLook(); look.color.brightness = 0.0001         // forces the compositor without changing the picture
            let edited = Fixtures.shared.outputURL("hdr-edit-picture", ext: "mov")
            let plain = Fixtures.shared.outputURL("hdr-plain-picture", ext: "mov")
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(15, 75), look: look)], to: edited, options: ExportOptions(mode: .exact, container: .mov, codec: .hevc))
            try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(15, 75))], to: plain, options: ExportOptions(mode: .exact, container: .mov, codec: .hevc))
            let a = try await meanLuma(edited, frame: 30), b = try await meanLuma(plain, frame: 30)
            #expect(abs(a - b) < 4, "\(kind): the edited export looks like the plain one (\(a) vs \(b))")
            #expect(try await MediaProbe.probe(url: edited).primaryVideo?.transferFunction == (kind == .hlg ? "ITU_R_2100_HLG" : "SMPTE_ST_2084_PQ"))
        }
    }

    @Test func joiningHDRWithSDRGivesAnSDRFile() async throws {
        let hdr = try await hdrSource(.hlg)
        let sdr = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("mixed-join", ext: "mov")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: hdr, span: span30(0, 30)), RenderPiece(sourceURL: sdr, span: span30(0, 30))], to: out, options: ExportOptions(mode: .exact, container: .mov, codec: .hevc))
        let v = try #require(try await MediaProbe.probe(url: out).primaryVideo)
        let depth = try await bitsPerComponent(out)
        #expect(!v.isHDR && depth == 8, "a mix is written as SDR, with honest tags, rather than SDR pictures labelled HDR")
    }

    @Test func fastCutKeepsTheStreamAsItIs() async throws {
        let src = try await hdrSource(.pq)
        let out = Fixtures.shared.outputURL("hdr-fast", ext: "mov")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(15, 75))], to: out, options: ExportOptions(mode: .fast, container: .mov, codec: .hevc))
        #expect(try await bitsPerComponent(out) == 10)
        #expect(try await MediaProbe.probe(url: out).primaryVideo?.isHDR == true)
    }

    @Test func sdrSourcesAreUnchangedByTheHDRRule() async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("sdr-out")
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(15, 75))], to: out, options: ExportOptions(mode: .exact, codec: .h264))
        let v = try #require(try await MediaProbe.probe(url: out).primaryVideo)
        #expect(v.codec == "avc1" && !v.isHDR)
        #expect(try await bitsPerComponent(out) ?? 8 == 8)      // H.264 does not state a depth; it must not become 10
    }
}
