import Foundation
import Testing
@testable import MacPlayerCore

/// 0.20: texts and layers share one stack; Bring Forward / Send Backward move things in it.
struct LayerOrderTests {
    private func s(_ x: Double) -> MediaTime { MediaTime(seconds: x, timescale: 600) }

    /// Two layers (lanes 0 and 1) and two texts, all on screen 0–10 s, and a text alone at 20–25 s.
    private func project() -> Project {
        var p = Project(name: "Stack", kind: .video)
        p.overlayClips = [OverlayClip(name: "A", kind: .image(path: "/a.png", bookmark: nil), lane: 0, start: .zero, duration: s(10)),
                          OverlayClip(name: "B", kind: .image(path: "/b.png", bookmark: nil), lane: 1, start: .zero, duration: s(10))]
        p.overlays = [TextOverlay(text: "T1", start: .zero, end: s(10)), TextOverlay(text: "T2", start: .zero, end: s(10)), TextOverlay(text: "Late", start: s(20), end: s(25))]
        return p
    }
    private func names(_ p: Project) -> [String] {
        LayerOrder.stack(p).map { id in p.overlays.first { $0.id == id.id }?.text ?? p.overlayClips.first { $0.id == id.id }!.name }
    }

    @Test func untouchedProjectsKeepTheOldOrder() {
        #expect(names(project()) == ["A", "B", "T1", "T2", "Late"], "layers by lane, then texts in the order they were added")
    }

    @Test func aLayerCanGoAboveTheTexts() {
        var p = project()
        #expect(LayerOrder.move([p.overlayClips[0].id], .toFront, in: &p, timed: true))
        #expect(names(p) == ["B", "T1", "T2", "A", "Late"], "above the topmost thing on screen with it; the late text is not its neighbour")
        #expect(!LayerOrder.canMove([p.overlayClips[0].id], .toFront, in: p, timed: true), "already on top")
        #expect(LayerOrder.move([p.overlayClips[0].id], .backward, in: &p, timed: true))
        #expect(names(p) == ["B", "T1", "A", "T2", "Late"])
    }

    @Test func forwardSkipsThingsNotOnScreenAtTheSameTime() {
        var p = project()
        let t2 = p.overlays[1].id
        #expect(!LayerOrder.canMove([t2], .forward, in: p, timed: true), "only the late text is above it, and it is never on screen with it")
        #expect(LayerOrder.canMove([t2], .forward, in: p, timed: false), "on a photo everything is on screen")
    }

    @Test func aTextCanGoUnderEveryLayer() {
        var p = project()
        #expect(LayerOrder.move([p.overlays[1].id], .toBack, in: &p, timed: true))
        #expect(names(p) == ["T2", "A", "B", "T1", "Late"])
        #expect(p.overlays.allSatisfy { ($0.z ?? 0) < 0 } && p.overlayClips.allSatisfy { ($0.z ?? 0) < 0 })
    }

    @Test func thingsAddedLaterLandOnTop() {
        var p = project()
        LayerOrder.move([p.overlays[0].id], .toBack, in: &p, timed: true)
        p.overlayClips.append(OverlayClip(name: "New", kind: .image(path: "/n.png", bookmark: nil), lane: 0, start: .zero, duration: s(10)))
        p.overlays.append(TextOverlay(text: "NewT", start: .zero, end: s(10)))
        #expect(names(p).suffix(2) == ["New", "NewT"])
    }

    @Test func severalSelectedMoveTogetherKeepingTheirOrder() {
        var p = project()
        let ids: Set = [p.overlayClips[0].id, p.overlayClips[1].id]
        #expect(LayerOrder.move(ids, .toFront, in: &p, timed: true))
        #expect(names(p) == ["T1", "T2", "A", "B", "Late"])
    }

    @Test func oldFilesWithoutAPlaceStillOpen() throws {
        let p = project()
        var json = String(data: try JSONEncoder().encode(p.overlays[0]), encoding: .utf8)!
        #expect(!json.contains("\"z\""))
        json = json.replacingOccurrences(of: "\"text\"", with: "\"z\":-3,\"text\"")
        #expect(try JSONDecoder().decode(TextOverlay.self, from: Data(json.utf8)).z == -3)
        let spec = try JSONDecoder().decode(LayerSpec.self, from: JSONEncoder().encode(p.layerSpecs(resolve: { _ in nil }).first ?? LayerSpec(kind: .image(path: "/x"), lane: 2, start: .zero, duration: s(1))))
        #expect(spec.z == 2 || spec.z == 0)
    }
}
