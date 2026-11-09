import Foundation
import Testing
@testable import MacPlayerCore

struct CropGeometryTests {
    private func near(_ a: CropRect, _ b: CropRect, _ tol: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    @Test func aFrameSurvivesTheTripToTheShownPictureAndBackForEveryTurnAndFlip() {
        let r = CropRect(x: 0.1, y: 0.25, width: 0.4, height: 0.5)
        for rotation in [0, 90, 180, 270] { for fh in [false, true] { for fv in [false, true] {
            let shown = CropGeometry.toDisplay(r, rotation: rotation, flipH: fh, flipV: fv)
            #expect(near(CropGeometry.toSource(shown, rotation: rotation, flipH: fh, flipV: fv), r), "rotation \(rotation) flips \(fh)/\(fv)")
            #expect(shown.x >= -1e-9 && shown.y >= -1e-9 && shown.x + shown.width <= 1 + 1e-9 && shown.y + shown.height <= 1 + 1e-9)
        } } }
    }

    @Test func aQuarterTurnMovesTheTopLeftCornerToTheTopRight() {
        // The clockwise quarter turn: what was at the top left is at the top right.
        let corner = CropRect(x: 0, y: 0, width: 0.2, height: 0.1)
        let shown = CropGeometry.toDisplay(corner, rotation: 90, flipH: false, flipV: false)
        #expect(near(shown, CropRect(x: 0.9, y: 0, width: 0.1, height: 0.2)), "\(shown)")
        let half = CropGeometry.toDisplay(CropRect(x: 0, y: 0, width: 0.5, height: 1), rotation: 0, flipH: true, flipV: false)
        #expect(near(half, CropRect(x: 0.5, y: 0, width: 0.5, height: 1)), "flipped sideways, the left half is on the right")
    }

    @Test func shownSizeSwapsSidesForAQuarterTurn() {
        #expect(CropGeometry.shownSize(width: 400, height: 300, rotation: 90) == (300, 400))
        #expect(CropGeometry.shownSize(width: 400, height: 300, rotation: 180) == (400, 300))
        #expect(CropGeometry.shownSize(width: 400, height: 300, rotation: 270) == (300, 400))
    }

    @Test func aFreeCornerFollowsTheMouseAndStaysInsideThePicture() {
        let start = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        #expect(near(CropGeometry.drag(.bottomRight, from: start, dx: 0.1, dy: 0.05), CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.55)))
        #expect(near(CropGeometry.drag(.topLeft, from: start, dx: -0.1, dy: -0.1), CropRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)))
        let out = CropGeometry.drag(.bottomRight, from: start, dx: 5, dy: 5)
        #expect(near(out, CropRect(x: 0.2, y: 0.2, width: 0.8, height: 0.8)), "stops at the picture's edge: \(out)")
        let tiny = CropGeometry.drag(.bottomRight, from: start, dx: -5, dy: -5)
        #expect(tiny.width >= 0.04 - 1e-9 && tiny.height >= 0.04 - 1e-9 && tiny.x == 0.2, "never turned inside out: \(tiny)")
        #expect(near(CropGeometry.drag(.right, from: start, dx: 0.1, dy: 0.9), CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)), "an edge moves one side only")
    }

    @Test func movingKeepsTheSizeAndStopsAtTheEdges() {
        let start = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        #expect(near(CropGeometry.drag(.move, from: start, dx: 0.1, dy: -0.1), CropRect(x: 0.3, y: 0.1, width: 0.5, height: 0.5)))
        #expect(near(CropGeometry.drag(.move, from: start, dx: 9, dy: 9), CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        #expect(near(CropGeometry.drag(.move, from: start, dx: -9, dy: -9), CropRect(x: 0, y: 0, width: 0.5, height: 0.5)))
    }

    @Test func aFixedShapeKeepsItsPixelRatioWhileDragging() {
        // A 3:2 picture; the frame is kept square (1:1 in pixels).
        let aspect = 1.5
        let start = CropGeometry.largest(ratio: 1, pictureAspect: aspect)
        #expect(abs(start.width * aspect / start.height - 1) < 1e-9 && start.height == 1, "largest square: \(start)")
        for handle in CropGeometry.Handle.allCases where handle != .move {
            let small = CropRect(x: 0.3, y: 0.2, width: 0.4 / aspect, height: 0.4)          // square in pixels
            let r = CropGeometry.drag(handle, from: small, dx: 0.07, dy: -0.05, ratio: 1, pictureAspect: aspect)
            #expect(abs(r.width * aspect / r.height - 1) < 1e-6, "\(handle) kept the shape: \(r)")
            #expect(r.x >= -1e-9 && r.y >= -1e-9 && r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9, "\(handle) stays inside: \(r)")
        }
        let grown = CropGeometry.drag(.bottomRight, from: CropRect(x: 0.5, y: 0.5, width: 0.2, height: 0.3), dx: 5, dy: 5, ratio: 1, pictureAspect: 1)
        #expect(grown.x + grown.width <= 1 + 1e-9 && grown.y + grown.height <= 1 + 1e-9 && abs(grown.width - grown.height) < 1e-6, "as large as fits and still square: \(grown)")
    }

    @Test func theLargestFrameOfAShapeIsCentredOrAroundTheOldOne() {
        let wide = CropGeometry.largest(ratio: 16.0 / 9, pictureAspect: 1)           // a square picture
        #expect(near(wide, CropRect(x: 0, y: (1 - 9.0 / 16) / 2, width: 1, height: 9.0 / 16)), "\(wide)")
        let tall = CropGeometry.largest(ratio: 9.0 / 16, pictureAspect: 16.0 / 9, around: CropRect(x: 0.8, y: 0, width: 0.2, height: 1))
        #expect(tall.x + tall.width <= 1 + 1e-9 && tall.x >= 0, "stays inside the picture even when centred near the edge")
    }
}
