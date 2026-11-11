import AVFoundation
import CoreGraphics
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// The save flows on the real disk, with real encoders.
@Suite(.serialized) struct SaveFlowTests {
    private let fs = RealFileSystem()

    private func workFolder(_ name: String) throws -> URL {
        let u = Fixtures.shared.root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func runner(_ folder: URL) -> (ExportRunner, SafeSaver) {
        let saver = SafeSaver(fs: fs, journalFolder: folder.appendingPathComponent("journal").path)
        return (ExportRunner(saver: saver, fs: fs), saver)
    }

    private func job(source: URL, from: Int64 = 30, to: Int64 = 90, target: SaveTarget, options: ExportOptions = ExportOptions(mode: .exact),
                     thumbnail: MediaTime? = nil) -> ExportJob {
        ExportJob(label: "t", pieces: [JobPiece(sourcePath: source.path, span: span30(from, to))], options: options, target: target, thumbnailTime: thumbnail)
    }

    private func leftovers(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains(".macplayer-") }
    }

    @Test func saveCopyLeavesTheSourceByteForByteUntouched() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try workFolder("copy")
        let src = dir.appendingPathComponent("talk.mp4")
        try FileManager.default.copyItem(at: master, to: src)
        let before = try Data(contentsOf: src)
        let (runner, _) = runner(dir)
        let dest = dir.appendingPathComponent("talk-edited.mp4")
        let r = try await runner.run(job: job(source: src, target: .newCopy(path: dest.path, overwrite: false)))
        #expect(r.outcome.finalPath == dest.path && FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: src) == before, "the source must be identical to the byte")
        #expect(abs(try await MediaProbe.probe(url: dest).duration.seconds - 2.0) < 0.2)
        #expect(leftovers(in: dir).isEmpty)
    }

    @Test func saveCopyRefusesToOverwriteAndToTargetTheSource() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try workFolder("nooverwrite")
        let src = dir.appendingPathComponent("a.mp4"); try FileManager.default.copyItem(at: master, to: src)
        let existing = dir.appendingPathComponent("b.mp4"); try Data("precious".utf8).write(to: existing)
        let (runner, _) = runner(dir)
        await #expect(throws: SaveError.destinationExists(existing.path)) {
            try await runner.run(job: job(source: src, target: .newCopy(path: existing.path, overwrite: false)))
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "precious")
        await #expect(throws: SaveError.destinationIsSource) {
            try await runner.run(job: job(source: src, target: .newCopy(path: src.path, overwrite: true)))
        }
        #expect(try Data(contentsOf: src) == (try Data(contentsOf: master)))
    }

    @Test func anOldReplaceJobFailsWithoutTouchingTheSource() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try workFolder("legacy-replace")
        let src = dir.appendingPathComponent("lecture.mp4"); try FileManager.default.copyItem(at: master, to: src)
        let original = try Data(contentsOf: src)
        let (runner, _) = runner(dir)
        await #expect(throws: SaveError.produceFailed(SaveTarget.legacyReplaceMessage)) {
            try await runner.run(job: job(source: src, target: .legacyReplaceOriginal(path: src.path)))
        }
        #expect(try Data(contentsOf: src) == original, "MacPlayer never writes over an original")
        #expect(leftovers(in: dir).isEmpty)
    }

    @Test func aReadOnlyFolderIsReportedAndNothingIsWritten() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try workFolder("readonly")
        let src = dir.appendingPathComponent("a.mp4"); try FileManager.default.copyItem(at: master, to: src)
        let out = try workFolder("ro-out")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
        let (runner, _) = runner(dir)
        await #expect(throws: SaveError.destinationFolderNotWritable(out.path)) {
            try await runner.run(job: job(source: src, target: .newCopy(path: out.appendingPathComponent("x.mp4").path, overwrite: false)))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: out.path))?.isEmpty == true)
    }

    @Test func aMissingSourceFailsCleanly() async throws {
        let dir = try workFolder("missing")
        let (runner, _) = runner(dir)
        let ghost = dir.appendingPathComponent("ghost.mp4")
        await #expect(throws: (any Error).self) {
            try await runner.run(job: job(source: ghost, target: .newCopy(path: dir.appendingPathComponent("o.mp4").path, overwrite: false)))
        }
        #expect(leftovers(in: dir).isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("o.mp4").path))
    }

    @Test func aCorruptSourceIsReportedNotCrashed() async throws {
        let dir = try workFolder("corrupt")
        let bad = dir.appendingPathComponent("bad.mp4"); try Data("this is not a video".utf8).write(to: bad)
        let (runner, _) = runner(dir)
        await #expect(throws: (any Error).self) {
            try await runner.run(job: job(source: bad, target: .newCopy(path: dir.appendingPathComponent("o.mp4").path, overwrite: false)))
        }
        #expect(try String(contentsOf: bad, encoding: .utf8) == "this is not a video")
        await #expect(throws: MediaProbeError.self) { _ = try await MediaProbe.probe(url: bad) }
    }

    @Test func aThumbnailIsExportedNextToTheClip() async throws {
        let master = try await Fixtures.shared.source()
        let dir = try workFolder("thumb")
        let src = dir.appendingPathComponent("a.mp4"); try FileManager.default.copyItem(at: master, to: src)
        let (runner, _) = runner(dir)
        let dest = dir.appendingPathComponent("clip.mp4")
        let r = try await runner.run(job: job(source: src, target: .newCopy(path: dest.path, overwrite: false), thumbnail: fr30(45)))
        let thumb = try #require(r.thumbnailPath)
        #expect(thumb.hasSuffix("clip.jpg") && FileManager.default.fileExists(atPath: thumb))
        let src2 = CGImageSourceCreateWithURL(URL(fileURLWithPath: thumb) as CFURL, nil)
        #expect(src2 != nil && CGImageSourceGetCount(src2!) == 1)
        // The still is frame 45 of the source, at the source's own size.
        let img = CGImageSourceCreateImageAtIndex(src2!, 0, nil)!
        #expect(img.width == 320 && img.height == 180)
        // A second export does not overwrite the first still.
        let dest2 = dir.appendingPathComponent("clip.mov")
        let r2 = try await runner.run(job: job(source: src, target: .newCopy(path: dest2.path, overwrite: false), options: ExportOptions(mode: .exact, container: .mov), thumbnail: fr30(45)))
        #expect(r2.thumbnailPath != thumb && r2.thumbnailPath != nil)
    }

    @Test func recoveryAfterACrashDuringTheSwapRestoresTheOriginal() async throws {
        // MacPlayer 0.7 died after the original was moved aside (real file system): the update still puts it back.
        let master = try await Fixtures.shared.source()
        let dir = try workFolder("crash")
        let src = dir.appendingPathComponent("a.mp4"); try FileManager.default.copyItem(at: master, to: src)
        let original = try Data(contentsOf: src)
        let journalDir = dir.appendingPathComponent("journal"); try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        let aside = dir.appendingPathComponent(".a.macplayer-old-zz.mp4"), temp = dir.appendingPathComponent(".a.macplayer-partial-zz.mp4")
        try FileManager.default.moveItem(at: src, to: aside)
        try Data("half".utf8).write(to: temp)
        let j = ["id": "zz", "source": src.path, "temp": temp.path, "aside": aside.path]
        try JSONSerialization.data(withJSONObject: j).write(to: journalDir.appendingPathComponent("zz.journal.json"))
        let reports = SafeSaver(fs: fs, journalFolder: journalDir.path).recoverLegacyReplaceJournals()
        #expect(reports.map(\.action) == [.restoredOriginal])
        #expect(try Data(contentsOf: src) == original && leftovers(in: dir).isEmpty)
    }
}

@Suite(.serialized) struct ArtworkTests {
    private func artwork() -> EmbeddedArtwork {
        let ctx = CGContext(data: nil, width: 120, height: 68, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.3, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 68))
        return EmbeddedArtwork(data: ImageWriter.data(ctx.makeImage()!, format: .jpeg(quality: 0.9))!, isPNG: false)
    }

    static func hasArtwork(_ url: URL) async throws -> Bool {
        let a = AVURLAsset(url: url)
        var items = try await a.load(.metadata)
        items += try await a.load(.commonMetadata)
        for i in items {
            if i.identifier == .commonIdentifierArtwork || i.identifier == .iTunesMetadataCoverArt { return true }
            if i.commonKey == .commonKeyArtwork { return true }
        }
        return false
    }

    @Test(arguments: [OutputContainer.mp4, .m4v], [CutMode.exact, CutMode.fast])
    func coverArtIsEmbeddedAndReadsBack(container: OutputContainer, mode: CutMode) async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("art", ext: container.rawValue)
        try await RenderExporter().export(pieces: [RenderPiece(sourceURL: src, span: span30(0, 30))], to: out,
                                          options: ExportOptions(mode: mode, container: container), artwork: artwork())
        #expect(try await Self.hasArtwork(out), "\(container) \(mode): artwork should read back")
        // The video itself is still fine.
        #expect(try await FrameScanner.scanVideo(url: out).compactMap(\.index).count == 30)
    }

    @Test func withoutArtworkNothingIsEmbedded() async throws {
        let src = try await Fixtures.shared.source()
        let out = Fixtures.shared.outputURL("noart")
        try await ClipExporter().export(source: src, spans: [span30(0, 30)], to: out, options: ExportOptions(mode: .exact))
        #expect(try await Self.hasArtwork(out) == false)
    }
}
