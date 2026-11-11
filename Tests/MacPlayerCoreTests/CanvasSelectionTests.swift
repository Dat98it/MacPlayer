import Foundation
import Testing
@testable import MacPlayerCore

@Suite struct CanvasSelectionTests {
    private func project() -> (Project, [UUID]) {
        var p = Project(name: "P", kind: .video)
        let a = TextOverlay(text: "A", start: .zero, end: MediaTime(seconds: 3), x: 0.2, y: 0.2)
        let b = TextOverlay.shape(ShapeSpec(kind: .star), start: .zero, end: MediaTime(seconds: 3), x: 0.5, y: 0.5)
        let c = OverlayClip(name: "logo", kind: .image(path: "/l.png", bookmark: nil), lane: 0, start: .zero, duration: MediaTime(seconds: 3), transform: OverlayTransform())
        p.overlays = [a, b]; p.overlayClips = [c]
        return (p, [a.id, b.id, c.id])
    }

    @Test func groupsAreSelectedWholeAndCanBeUndone() {
        var (p, ids) = project()
        #expect(CanvasSelection.group([ids[0]], in: &p) == nil, "one thing is not a group")
        let g = CanvasSelection.group([ids[0], ids[2]], in: &p)
        #expect(g != nil && p.overlays[0].groupID == g && p.overlayClips[0].groupID == g && p.overlays[1].groupID == nil)
        #expect(CanvasSelection.expandingGroups([ids[2]], in: p) == [ids[0], ids[2]], "picking the logo picks its group")
        #expect(CanvasSelection.expandingGroups([ids[1]], in: p) == [ids[1]])
        CanvasSelection.ungroup([ids[0]], in: &p)
        #expect(p.overlays[0].groupID == nil && CanvasSelection.expandingGroups([ids[2]], in: p) == [ids[2]])
    }

    @Test func lockedThingsStayPutAndAreNotDeleted() {
        var (p, ids) = project()
        CanvasSelection.setLocked(true, [ids[1]], in: &p)
        CanvasSelection.nudge(Set(ids), dx: 0.1, dy: -0.05, in: &p)
        #expect(abs(p.overlays[0].x - 0.3) < 1e-9 && abs(p.overlays[0].y - 0.15) < 1e-9)
        #expect(p.overlays[1].x == 0.5 && p.overlays[1].y == 0.5, "the locked star did not move")
        #expect(abs(p.overlayClips[0].transform.centerX - (OverlayTransform().centerX + 0.1)) < 1e-9)
        let kept = CanvasSelection.delete(Set(ids), in: &p)
        #expect(kept == 1 && p.overlays.map(\.id) == [ids[1]] && p.overlayClips.isEmpty)
        CanvasSelection.setLocked(false, [ids[1]], in: &p)
        #expect(p.overlays[0].locked == nil, "unlocked leaves nothing in the file")
    }

    @Test func movesStayOnThePictureAndCarryKeyframes() {
        var (p, ids) = project()
        p.overlays[0].keyframes = [ElementKeyframe(time: 0, x: 0.2, y: 0.2), ElementKeyframe(time: 1, x: 0.95, y: 0.2)]
        CanvasSelection.nudge([ids[0]], dx: 0.1, dy: 0, in: &p)
        #expect(abs(p.overlays[0].keyframes![0].x - 0.3) < 1e-9 && p.overlays[0].keyframes![1].x == 1, "the whole animation moves, kept on the picture")
    }

    @Test func oldFilesHaveNoGroupsOrLocks() throws {
        let (p, _) = project()
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(p)) as? [String: Any])
        let text = String(data: try ProjectCodec.encode(p), encoding: .utf8) ?? ""
        #expect(!text.contains("groupID") && !text.contains("\"locked\""), "nothing is written when nothing is grouped or locked")
        obj["name"] = "Old"
        let back = try ProjectCodec.decode(try JSONSerialization.data(withJSONObject: obj))
        #expect(back.overlays.allSatisfy { $0.groupID == nil && $0.locked == nil })
    }
}
