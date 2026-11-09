import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// A video whose data stops partway (an incomplete download): the header, written first, still promises the full length.
@Suite(.serialized) struct SourceHealthTests {
    private func folder(_ name: String) throws -> URL {
        let u = Fixtures.shared.root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Rewrites `source` with its header first (like a video made for streaming), then cuts the file off after `keep` of its bytes.
    private func truncatedCopy(of source: URL, keep: Double, in dir: URL) async throws -> URL {
        let streamable = dir.appendingPathComponent("streamable.mp4")
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough))
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: streamable, as: .mp4)
        let data = try Data(contentsOf: streamable)
        let cut = dir.appendingPathComponent("cut-off.mp4")
        try data.prefix(Int(Double(data.count) * keep)).write(to: cut)
        return cut
    }

    @Test func aHealthyFileHasNoDamage() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 6))
        #expect(await SourceHealth.tailDamage(of: src, endingAt: 6) == nil)
    }

    @Test func aFileThatIsCutOffIsFoundAndExactExportRefusesAtOnce() async throws {
        let dir = try folder("health")
        let src = try await Fixtures.shared.source(.init(seconds: 8, gop: 15))
        let cut = try await truncatedCopy(of: src, keep: 0.6, in: dir)
        let bad = try #require(await SourceHealth.tailDamage(of: cut, endingAt: 8), "the cut-off end is found")
        #expect(bad.declared > 7.5 && bad.readable >= 0 && bad.readable < 7.5, "the data stops partway: readable \(bad.readable) of \(bad.declared)")

        let out = dir.appendingPathComponent("out.mp4")
        let piece = RenderPiece(sourceURL: cut, span: TimeSpan(start: .zero, end: MediaTime(seconds: 8)))
        do {
            try await RenderExporter().export(pieces: [piece], to: out, options: ExportOptions(mode: .exact, container: .mp4, codec: .h264))
            Issue.record("exporting the whole cut-off file exactly should have been refused")
        } catch let e as ExportError {
            guard case .sourceDamaged(let readable, _) = e else { Issue.record("wrong error: \(e)"); return }
            #expect(readable < 7.5, "the refusal names a point before the end (\(readable))")
            #expect(SourceDamage.parse(e.description) != nil, "the message is the one the app can show in the person's language")
        }
        #expect(!FileManager.default.fileExists(atPath: out.path), "nothing was left behind")
    }

    @Test func aPartBeforeTheDamageStillExportsExactly() async throws {
        let dir = try folder("health-part")
        let src = try await Fixtures.shared.source(.init(seconds: 8, gop: 15))
        let cut = try await truncatedCopy(of: src, keep: 0.6, in: dir)
        let out = dir.appendingPathComponent("part.mp4")
        let piece = RenderPiece(sourceURL: cut, span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)))
        try await RenderExporter().export(pieces: [piece], to: out, options: ExportOptions(mode: .exact, container: .mp4, codec: .h264))
        let info = try await MediaProbe.probe(url: out)
        #expect(abs(info.duration.seconds - 1) < 0.2, "got \(info.duration.seconds) s")
    }
}
