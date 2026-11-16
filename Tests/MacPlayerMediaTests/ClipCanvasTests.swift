import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct ClipCanvasTests {
    // Decode the new optional field, so this also reproduces the old renderer ignoring it.
    private func portraitLook() throws -> VideoLook {
        var look = VideoLook(); look.canvas = .landscape16x9; look.fit = .fill
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(look)) as? [String: Any])
        json["clipCanvas"] = "portrait9x16"
        return try JSONDecoder().decode(VideoLook.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func onlyTheChosenPieceGetsAPortraitFrame() async throws {
        let source = try await Fixtures.shared.source()
        var plain = VideoLook(); plain.canvas = .landscape16x9
        for selected in [0, 3] {
            let pieces = try (0..<4).map { i in
                RenderPiece(sourceURL: source, span: span30(0, 15), look: i == selected ? try portraitLook() : plain)
            }
            let preview = try await CompositionBuilder.build(pieces: pieces, includeAudio: false, frameAccurate: false)
            #expect(preview.renderSize == CGSize(width: 320, height: 180), "a clip edit must not resize the whole timeline")
            let generator = AVAssetImageGenerator(asset: preview.composition)
            generator.videoComposition = preview.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let output = Fixtures.shared.outputURL("clip-canvas-\(selected)")
            try await RenderExporter().export(pieces: pieces, to: output, options: ExportOptions(mode: .exact, includeAudio: false))
            for i in 0..<4 {
                let time = Double(i) * 0.5 + 0.2
                let (cg, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                let shown = Pixels(cg), saved = try await frame(output, at: time)
                for image in [shown, saved] {
                    if i == selected {
                        #expect(image.isBlack(5, 90) && image.isBlack(315, 90), "only clip \(selected + 1) has portrait side bars")
                        #expect(!image.isBlack(160, 20) && !image.isBlack(160, 160), "fill covers that clip's own frame")
                    } else {
                        #expect(image.isRed(300, 20), "clip \(i + 1) keeps its landscape corner")
                    }
                }
                #expect(shown.meanAbsDiff(saved) < 3, "preview and export agree")
            }
        }
    }
}
