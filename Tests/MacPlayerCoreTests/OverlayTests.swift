import Foundation
import Testing
@testable import MacPlayerCore

private func t(_ s: Double) -> MediaTime { MediaTime(seconds: s, timescale: 600) }

private func pip(start: Double = 2, duration: Double = 6, lane: Int = 0) -> OverlayClip {
    OverlayClip(name: "PiP", kind: .video(sourceID: UUID(), sourceStart: t(0), sourceEnd: t(duration)), lane: lane, start: t(start), duration: t(duration))
}

@Suite struct OverlayAnimationTests {
    @Test func notOnScreenOutsideItsTimeRange() {
        let c = pip()
        #expect(c.state(at: t(1.99)) == nil && c.state(at: t(2)) != nil && c.state(at: t(7.99)) != nil && c.state(at: t(8)) == nil)
    }

    @Test func withoutKeyframesTheBaseTransformIsUsed() {
        var c = pip(); c.transform.centerX = 0.25; c.transform.width = 0.4; c.transform.opacity = 0.6
        let s = c.state(at: t(3))!
        #expect(s.centerX == 0.25 && s.width == 0.4 && s.opacity == 0.6)
    }

    @Test func keyframesChangeInAStraightLineAndHoldAtTheEnds() {
        var c = pip()   // 2...8 s on the timeline; keyframes are counted from the clip's own start
        c.keyframes = [OverlayKeyframe(time: t(1), centerX: 0.2, centerY: 0.5, width: 0.2, opacity: 0),
                       OverlayKeyframe(time: t(3), centerX: 0.8, centerY: 0.5, width: 0.4, opacity: 1)]
        let early = c.state(at: t(2.2))!                    // before the first keyframe: holds it
        #expect(early.centerX == 0.2 && early.opacity == 0)
        let mid = c.state(at: t(4))!                        // 2 s into the clip, halfway between 1 s and 3 s
        #expect(abs(mid.centerX - 0.5) < 1e-9 && abs(mid.width - 0.3) < 1e-9 && abs(mid.opacity - 0.5) < 1e-9)
        let late = c.state(at: t(7))!                       // after the last: holds it
        #expect(late.centerX == 0.8 && late.opacity == 1)
    }

    @Test func keyframesAreUsedInTimeOrderWhateverTheirStorageOrder() {
        var c = pip()
        c.keyframes = [OverlayKeyframe(time: t(3), centerX: 0.8, centerY: 0.5, width: 0.3, opacity: 1), OverlayKeyframe(time: t(1), centerX: 0.2, centerY: 0.5, width: 0.3, opacity: 1)]
        #expect(abs(c.state(at: t(4))!.centerX - 0.5) < 1e-9)
    }

    @Test func fadesMultiplyTheOpacity() {
        var c = pip(); c.fadeIn = 1; c.fadeOut = 2; c.transform.opacity = 0.8
        #expect(c.state(at: t(2))!.opacity == 0, "starts invisible")
        #expect(abs(c.state(at: t(2.5))!.opacity - 0.4) < 1e-6, "half way through a 1 s fade-in")
        #expect(abs(c.state(at: t(5))!.opacity - 0.8) < 1e-9, "fully visible in the middle")
        #expect(abs(c.state(at: t(7))!.opacity - 0.4) < 1e-6, "1 s into a 2 s fade-out")
    }

    @Test func layerSpecAnimatesExactlyLikeTheProjectClip() {
        var c = pip(); c.keyframes = [OverlayKeyframe(time: t(0), centerX: 0.1, centerY: 0.1, width: 0.2, opacity: 1), OverlayKeyframe(time: t(6), centerX: 0.9, centerY: 0.9, width: 0.5, opacity: 0.5)]
        c.fadeIn = 0.5
        var p = Project(name: "P", mode: .project)
        p.overlayClips = [c]
        let spec = p.layerSpecs(resolve: { _ in "/v/a.mp4" })[0]
        for x in stride(from: 2.0, to: 8.0, by: 0.37) { #expect(spec.state(at: t(x)) == c.state(at: t(x)), "same values at \(x) s") }
    }

    @Test func rectFollowsCentreWidthAndAspect() {
        let r = OverlayClip.rect(for: OverlayState(centerX: 0.75, centerY: 0.25, width: 0.4, opacity: 1), outputWidth: 1000, outputHeight: 500, aspect: 2)
        #expect(r.width == 400 && r.height == 200 && r.x == 550 && r.y == 25)
    }

    @Test func transformIsKeptInASafeRange() {
        var tr = OverlayTransform(); tr.width = 0; tr.opacity = 7; tr.borderWidth = 3; tr.centerX = 99
        let c = tr.clamped()
        #expect(c.width >= 0.02 && c.opacity == 1 && c.borderWidth <= 0.05 && c.centerX <= 1.5)
    }

    @Test func pipPresetsStayInsideThePicture() {
        // Output shapes and layer shapes that differ: a vertical output with a wide layer, a wide output with a square logo.
        let shapes: [(Double, Double)] = [(1.7778, 1.7778), (0.5625, 1.7778), (1.7778, 1.0), (1.0, 1.3333)]
        for (oa, la) in shapes {
            for p in OverlayEditor.Preset.allCases where p != .full {
                var tr = OverlayTransform(); tr.width = 0.3
                OverlayEditor.apply(p, to: &tr, outputAspect: oa, layerAspect: la)
                let w = 1000.0, h = w / oa
                let r = OverlayClip.rect(for: OverlayState(centerX: tr.centerX, centerY: tr.centerY, width: tr.width, opacity: 1), outputWidth: w, outputHeight: h, aspect: la)
                #expect(r.x >= 0 && r.y >= 0 && r.x + r.width <= w + 0.01 && r.y + r.height <= h + 0.01, "\(p) output \(oa) layer \(la) must stay inside: \(r)")
            }
        }
    }
}

@Suite struct OverlayEditingTests {
    @Test func theFirstFreeLaneSkipsBusyOnes() {
        let clips = [pip(start: 0, duration: 5, lane: 0), pip(start: 0, duration: 5, lane: 1)]
        #expect(OverlayEditor.firstFreeLane(clips, start: t(1), duration: t(2)) == 2)
        #expect(OverlayEditor.firstFreeLane(clips, start: t(6), duration: t(2)) == 0, "free again after they end")
        let full = clips + [pip(start: 0, duration: 5, lane: 2)]
        #expect(OverlayEditor.firstFreeLane(full, start: t(1), duration: t(2)) == nil)
        #expect(OverlayEditor.firstFreeLane(full, start: t(1), duration: t(2), ignoring: full[2].id) == 2, "a clip does not block itself")
    }

    @Test func movingNeverGoesBeforeZeroOrPastTheLimitOrOntoANeighbour() {
        var clips = [pip(start: 1, duration: 3), pip(start: 6, duration: 3)]
        #expect(OverlayEditor.move(&clips, id: clips[0].id, toStart: t(-5)) && clips[0].start == .zero)
        #expect(OverlayEditor.move(&clips, id: clips[0].id, toStart: t(50), limit: t(10)) == false, "would land on the neighbour: refused")
        #expect(clips[0].start == .zero, "a refused move changes nothing")
        let other = clips[1].id
        #expect(OverlayEditor.move(&clips, id: other, toStart: t(50), limit: t(10)) && clips[1].end == t(10), "kept inside the timeline")
        #expect(OverlayEditor.move(&clips, id: clips[0].id, toStart: t(5), lane: 1) && clips[0].lane == 1, "moving to a free lane is fine")
    }

    @Test func trimmingAVideoMovesItsSourceRangeNotItsPace() {
        var clips = [OverlayClip(name: "v", kind: .video(sourceID: UUID(), sourceStart: t(10), sourceEnd: t(20)), start: t(5), duration: t(10))]
        OverlayEditor.trim(&clips, id: clips[0].id, leftEdge: true, toTimelineTime: t(7), sourceDuration: t(30))
        guard case .video(_, let a, let b) = clips[0].kind else { Issue.record("not a video"); return }
        #expect(a == t(12) && b == t(20) && clips[0].start == t(7) && clips[0].duration == t(8), "2 s cut from the start of the picture")
        OverlayEditor.trim(&clips, id: clips[0].id, leftEdge: false, toTimelineTime: t(100), sourceDuration: t(30))
        guard case .video(_, _, let b2) = clips[0].kind else { return }
        #expect(b2 == t(30), "can be extended back out, but never past the video's own end (30 s)")
    }

    @Test func trimmingAPictureChangesItsLengthAndStopsAtNeighboursAndMinimum() {
        var clips = [OverlayClip(name: "logo", kind: .image(path: "/p.png", bookmark: nil), start: t(2), duration: t(4)), pip(start: 8, duration: 2)]
        OverlayEditor.trim(&clips, id: clips[0].id, leftEdge: false, toTimelineTime: t(20))
        #expect(clips[0].end == t(8), "stopped by the clip after it in the same lane")
        OverlayEditor.trim(&clips, id: clips[0].id, leftEdge: false, toTimelineTime: t(2))
        #expect(clips[0].duration >= t(0.1) && clips[0].start == t(2), "never shorter than a tenth of a second")
    }

    @Test func trimmingDropsKeyframesThatFallOutsideAndShiftsTheRest() {
        var c = pip(start: 0, duration: 10)
        c.keyframes = [OverlayKeyframe(time: t(1), centerX: 0.1, centerY: 0.1, width: 0.2, opacity: 1), OverlayKeyframe(time: t(6), centerX: 0.9, centerY: 0.9, width: 0.2, opacity: 1)]
        var clips = [c]
        OverlayEditor.trim(&clips, id: c.id, leftEdge: true, toTimelineTime: t(3))
        #expect(clips[0].keyframes.count == 1 && clips[0].keyframes[0].time == t(3), "the one at 6 s is now 3 s into the shorter clip; the one at 1 s is gone")
    }

    @Test func settingAKeyframeAtTheSameTimeReplacesIt() {
        var c = pip()
        let s = OverlayState(centerX: 0.3, centerY: 0.3, width: 0.3, opacity: 1)
        OverlayEditor.setKeyframe(&c, at: t(2), to: s)
        OverlayEditor.setKeyframe(&c, at: t(2.001), to: OverlayState(centerX: 0.9, centerY: 0.3, width: 0.3, opacity: 1))
        OverlayEditor.setKeyframe(&c, at: t(1), to: s)
        #expect(c.keyframes.count == 2 && c.keyframes.map(\.time) == [t(1), t(2)] && c.keyframes[1].centerX == 0.9)
    }

    @Test func editableStateIgnoresFadesSoEditingDoesNotBakeThemIn() {
        var c = pip(); c.fadeIn = 2; c.transform.opacity = 1
        #expect(OverlayEditor.editableState(c, at: c.start).opacity == 1)
    }
}

@Suite struct OverlayPersistenceTests {
    @Test func aProjectWithLayersRoundTrips() throws {
        var p = Project(name: "P", mode: .project)
        let s = p.addSource(SourceRef(path: "/v/a.mp4"))
        var c = OverlayClip(name: "cam", kind: .video(sourceID: s, sourceStart: t(1), sourceEnd: t(9)), lane: 1, start: t(2), duration: t(8))
        c.keyframes = [OverlayKeyframe(time: t(0), centerX: 0.1, centerY: 0.2, width: 0.3, opacity: 0.4)]
        c.transform.borderWidth = 0.01; c.fadeIn = 0.5
        p.overlayClips = [c, OverlayClip(name: "logo", kind: .image(path: "/p.png", bookmark: Data([1])), start: t(0), duration: t(5))]
        let back = try ProjectCodec.decode(ProjectCodec.encode(p))
        #expect(back == p && back.schemaVersion == 2)
    }

    @Test func aProjectSavedBeforeLayersExistedStillOpens() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectCodec.encode(Project(name: "Old", mode: .quick))) as? [String: Any])
        obj["schemaVersion"] = 1
        obj.removeValue(forKey: "overlayClips")
        let p = try ProjectCodec.decode(JSONSerialization.data(withJSONObject: obj))
        #expect(p.name == "Old" && p.overlayClips.isEmpty && p.schemaVersion == 2, "migrated one step, with no layers")
    }

    @Test func aQueueJobSavedBeforeLayersExistedStillLoads() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderRecipe())) as? [String: Any])
        obj.removeValue(forKey: "layers")
        let r = try JSONDecoder().decode(RenderRecipe.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(r.layers.isEmpty)
    }

    @Test func layersForceReencodingAndCountAsSourcesOfAJob() {
        var r = RenderRecipe()
        #expect(!r.needsReencode)
        r.layers = [LayerSpec(kind: .video(path: "/v/cam.mp4", sourceStart: .zero, sourceEnd: t(3)), lane: 0, start: .zero, duration: t(3))]
        #expect(r.needsReencode)
        let job = ExportJob(label: "x", pieces: [JobPiece(sourcePath: "/v/main.mp4", span: TimeSpan(start: .zero, end: t(5)))], recipe: r, options: ExportOptions(), target: .newCopy(path: "/o/x.mp4", overwrite: false))
        #expect(job.sourcePaths == ["/v/cam.mp4", "/v/main.mp4"], "an export must never be written over a layer's source either")
    }

    @Test func layersWithAMissingSourceAreLeftOutOfTheSpecs() {
        var p = Project(name: "P", mode: .project)
        let have = UUID(), gone = UUID()
        p.overlayClips = [OverlayClip(name: "a", kind: .video(sourceID: have, sourceStart: .zero, sourceEnd: t(3)), start: .zero, duration: t(3)),
                          OverlayClip(name: "b", kind: .video(sourceID: gone, sourceStart: .zero, sourceEnd: t(3)), start: .zero, duration: t(3)),
                          OverlayClip(name: "c", kind: .image(path: "/p.png", bookmark: nil), start: .zero, duration: t(3))]
        let specs = p.layerSpecs(resolve: { $0 == have ? "/v/a.mp4" : nil })
        #expect(specs.map(\.path) == ["/v/a.mp4", "/p.png"])
    }
}

@Suite struct OverlayDragTests {
    private let oa = 16.0 / 9
    private func state(x: Double = 0.5, y: Double = 0.5, w: Double = 0.3) -> OverlayState { OverlayState(centerX: x, centerY: y, width: w, opacity: 1) }

    @Test func rectMatchesTheRenderersRect() {
        // The same numbers the compositor uses: width * output width, height from the layer's own aspect.
        let s = OverlayState(centerX: 0.75, centerY: 0.25, width: 0.4, opacity: 1)
        let d = OverlayDrag.rect(s, outputAspect: 2, layerAspect: 2)
        let c = OverlayClip.rect(for: s, outputWidth: 1000, outputHeight: 500, aspect: 2)
        #expect(abs(d.x0 * 1000 - c.x) < 1e-9 && abs(d.y0 * 500 - c.y) < 1e-9 && abs(d.width * 1000 - c.width) < 1e-9 && abs(d.height * 500 - c.height) < 1e-9)
    }

    @Test func movingShiftsTheCentreAndIsKeptReachable() {
        let m = OverlayDrag.move(state(), dx: 0.1, dy: -0.2)
        #expect(abs(m.centerX - 0.6) < 1e-9 && abs(m.centerY - 0.3) < 1e-9 && m.width == 0.3)
        let far = OverlayDrag.move(state(), dx: 50, dy: -50)
        #expect(far.centerX == 1.2 && far.centerY == -0.2, "a drag far outside cannot lose the layer")
    }

    @Test func resizingKeepsTheOppositeCornerAndTheShape() {
        for corner in OverlayDrag.Corner.allCases {
            let start = state(x: 0.5, y: 0.5, w: 0.3)
            let r0 = OverlayDrag.rect(start, outputAspect: oa, layerAspect: oa)
            let opposite: OverlayDrag.Corner = { switch corner { case .topLeft: return .bottomRight; case .topRight: return .bottomLeft; case .bottomLeft: return .topRight; case .bottomRight: return .topLeft } }()
            let fixed = r0.corner(opposite)
            // Drag the corner outwards by 0.1 of the width.
            let c = r0.corner(corner)
            let sx: Double = (corner == .topRight || corner == .bottomRight) ? 1 : -1
            let grown = OverlayDrag.resize(start, corner: corner, to: (c.x + sx * 0.1, c.y), outputAspect: oa, layerAspect: oa)
            let r1 = OverlayDrag.rect(grown, outputAspect: oa, layerAspect: oa)
            let nowFixed = r1.corner(opposite)
            #expect(abs(nowFixed.x - fixed.x) < 1e-9 && abs(nowFixed.y - fixed.y) < 1e-9, "\(corner): the opposite corner stays put")
            #expect(abs(grown.width - 0.4) < 1e-9, "\(corner): width grew by the dragged distance")
            #expect(abs(r1.width / r1.height - r0.width / r0.height) < 1e-9, "\(corner): the shape is kept")
        }
    }

    @Test func resizingHasALowerAndAnUpperLimitAndNeverFlips() {
        let start = state()
        let r0 = OverlayDrag.rect(start, outputAspect: oa, layerAspect: oa)
        let tiny = OverlayDrag.resize(start, corner: .bottomRight, to: (r0.x0, r0.y0), outputAspect: oa, layerAspect: oa)
        #expect(tiny.width >= 0.05, "dragged onto the fixed corner: smallest size, not zero")
        let past = OverlayDrag.resize(start, corner: .bottomRight, to: (r0.x0 - 0.2, r0.y0 - 0.2), outputAspect: oa, layerAspect: oa)
        #expect(past.width > 0, "dragged past the fixed corner: still a positive width")
        let huge = OverlayDrag.resize(start, corner: .bottomRight, to: (50, 50), outputAspect: oa, layerAspect: oa)
        #expect(huge.width <= 2)
    }

    @Test func resizingWorksForALayerOfAnotherShape() {
        // A square logo in a wide picture: the height fraction must use both aspects.
        let start = state(x: 0.9, y: 0.1, w: 0.1)
        let r0 = OverlayDrag.rect(start, outputAspect: oa, layerAspect: 1)
        let grown = OverlayDrag.resize(start, corner: .bottomLeft, to: (r0.x0 - 0.05, r0.y1), outputAspect: oa, layerAspect: 1)
        let r1 = OverlayDrag.rect(grown, outputAspect: oa, layerAspect: 1)
        #expect(abs(r1.x1 - r0.x1) < 1e-9 && abs(r1.y0 - r0.y0) < 1e-9, "top-right stays")
        #expect(abs(r1.width * oa / r1.height - 1) < 1e-9, "still square on screen")
    }

    @Test func snapsToTheCentreAndToTheMarginsWithinTheTolerance() {
        let c = OverlayDrag.snapped(state(x: 0.503, y: 0.497), outputAspect: oa, layerAspect: oa)
        #expect(c.state.centerX == 0.5 && c.state.centerY == 0.5 && c.guideX == 0.5 && c.guideY == 0.5)
        // Right edge 0.009 inside the 3% margin snaps onto it.
        let m = OverlayDrag.snapped(state(x: 1 - 0.03 - 0.15 - 0.009, y: 0.3), outputAspect: oa, layerAspect: oa)
        #expect(abs(OverlayDrag.rect(m.state, outputAspect: oa, layerAspect: oa).x1 - 0.97) < 1e-9 && m.guideX == 0.97)
        let far = OverlayDrag.snapped(state(x: 0.7, y: 0.3), outputAspect: oa, layerAspect: oa)
        #expect(far.state == state(x: 0.7, y: 0.3) && far.guideX == nil && far.guideY == nil, "nothing close: left alone")
    }

    @Test func snapNeverChangesSizeOrOpacity() {
        var s = state(x: 0.5, y: 0.5, w: 0.37); s.opacity = 0.4
        let r = OverlayDrag.snapped(s, outputAspect: oa, layerAspect: oa)
        #expect(r.state.width == 0.37 && r.state.opacity == 0.4)
    }
}
