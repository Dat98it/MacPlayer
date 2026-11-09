import Foundation
import Testing
@testable import MacPlayerCore

struct ColorGradingTests {
    func close(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ tol: Double = 1e-6) -> Bool {
        abs(a.0 - b.0) < tol && abs(a.1 - b.1) < tol && abs(a.2 - b.2) < tol
    }

    // MARK: Settings

    @Test func aNewColourSettingIsNeutralAndOldProjectsOpenWithTheFinerToolsOff() throws {
        #expect(ColorAdjust().isNeutral && !ColorAdjust().needsGrade)
        let old = #"{"brightness":0.2,"contrast":0,"saturation":0.1,"temperature":0}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(ColorAdjust.self, from: old)
        #expect(c.brightness == 0.2 && c.saturation == 0.1 && !c.needsGrade && c.curves.isNeutral && c.hsl.isNeutral && c.lut == nil)
    }

    @Test func settingsSurviveSavingAndOpening() throws {
        var c = ColorAdjust()
        c.exposure = 0.3; c.tint = -0.2
        c.curves.setPoints([CurvePoint(x: 0.3, y: 0.2), CurvePoint(x: 0.8, y: 0.9)], for: .red)
        c.wheels.shadows = ColorWheel(x: 0.4, y: -0.2, luma: 0.1)
        c.hsl[.blue] = HSLAdjust(hue: 0.5, saturation: -0.3, luminance: 0.2)
        c.lut = LutRef(name: "Teal", path: "/tmp/teal.cube", strength: 0.6)
        let back = try JSONDecoder().decode(ColorAdjust.self, from: try JSONEncoder().encode(c))
        #expect(back == c && back.needsGrade)
    }

    // MARK: Curves

    @Test func noPointsIsAStraightLineAndPointsBendIt() {
        #expect(CurveMath.value([], at: 0.37) == 0.37)
        let up = [CurvePoint(x: 0.5, y: 0.7)]
        #expect(abs(CurveMath.value(up, at: 0.5) - 0.7) < 1e-9)
        #expect(CurveMath.value(up, at: 0) == 0 && CurveMath.value(up, at: 1) == 1, "the ends stay where they are")
    }

    @Test func aCurveNeverGoesBackwardsOrLeavesTheFrame() {
        let wild = [CurvePoint(x: 0.2, y: 0.9), CurvePoint(x: 0.4, y: 0.1), CurvePoint(x: 0.7, y: 1), CurvePoint(x: 0.9, y: 0)]
        let t = CurveMath.table(wild, size: 256)
        #expect(t.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Points that fall back make a flat stretch, not a hole: no step is more than a hair backwards.
        let steady = CurveMath.table([CurvePoint(x: 0.25, y: 0.1), CurvePoint(x: 0.75, y: 0.95)], size: 256)
        #expect(zip(steady, steady.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 })
    }

    @Test func pointsAreTidied() {
        let p = CurveMath.cleaned([CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 2, y: -3)])
        #expect(p.count == 2 && p.last == CurvePoint(x: 1, y: 0), "clamped into the frame")
        #expect(CurveMath.cleaned([CurvePoint(x: 0.4, y: 0.4)]).isEmpty, "a single point on the straight line changes nothing")
        let near = CurveMath.cleaned([CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.505, y: 0.9)])
        #expect(near.count == 1 && near[0].y == 0.9, "two points almost on top of each other become one")
    }

    // MARK: Grading

    @Test func aNeutralSettingGivesBackTheSameColours() {
        let plan = ColorGrading.Plan(ColorAdjust())
        for c in [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0), (0.2, 0.5, 0.8), (0.9, 0.1, 0.4)] {
            #expect(close(plan.transform(c.0, c.1, c.2), c, 1e-9))
        }
        let cube = ColorGrading.cube(for: ColorAdjust(), size: 5)
        #expect(cube.count == 5 * 5 * 5 * 4)
        // the grid point (1, 2, 3) of 0...4 is (0.25, 0.5, 0.75)
        let i = ((3 * 5 + 2) * 5 + 1) * 4
        #expect(abs(cube[i] - 0.25) < 1e-6 && abs(cube[i + 1] - 0.5) < 1e-6 && abs(cube[i + 2] - 0.75) < 1e-6 && cube[i + 3] == 1)
    }

    @Test func exposureBrightensAndDarkens() {
        var up = ColorAdjust(); up.exposure = 0.5
        var down = ColorAdjust(); down.exposure = -0.5
        let a = ColorGrading.Plan(up).transform(0.4, 0.4, 0.4), b = ColorGrading.Plan(down).transform(0.4, 0.4, 0.4)
        #expect(a.0 > 0.4 && b.0 < 0.4 && a.0 == a.1)
        #expect(ColorGrading.Plan(up).transform(1, 1, 1).0 == 1, "white stays inside the range")
    }

    @Test func shadowsMostlyMoveTheDarkPartsAndHighlightsTheLightOnes() {
        var s = ColorAdjust(); s.shadows = 1
        var h = ColorAdjust(); h.highlights = -1
        let ps = ColorGrading.Plan(s), ph = ColorGrading.Plan(h)
        let darkGain = ps.transform(0.1, 0.1, 0.1).0 - 0.1, lightGain = ps.transform(0.9, 0.9, 0.9).0 - 0.9
        #expect(darkGain > 0.1 && lightGain < 0.02 && darkGain > 5 * lightGain)
        let lightDrop = 0.9 - ph.transform(0.9, 0.9, 0.9).0, darkDrop = 0.1 - ph.transform(0.1, 0.1, 0.1).0
        #expect(lightDrop > 0.1 && darkDrop < 0.02)
    }

    @Test func aCurveBendsTheChosenChannelOnly() {
        var c = ColorAdjust()
        c.curves.setPoints([CurvePoint(x: 0.5, y: 0.8)], for: .red)
        let out = ColorGrading.Plan(c).transform(0.5, 0.5, 0.5)
        #expect(abs(out.0 - 0.8) < 1e-3 && abs(out.1 - 0.5) < 1e-9 && abs(out.2 - 0.5) < 1e-9)
        var m = ColorAdjust()
        m.curves.setPoints([CurvePoint(x: 0.5, y: 0.8)], for: .master)
        let all = ColorGrading.Plan(m).transform(0.5, 0.2, 0.9)
        #expect(all.0 > 0.7 && all.1 > 0.2 && all.2 >= 0.9)
    }

    @Test func aWheelTintsItsOwnPartOfThePicture() {
        var c = ColorAdjust()
        c.wheels.shadows = ColorWheel(x: 1, y: 0)         // towards red
        let plan = ColorGrading.Plan(c)
        let dark = plan.transform(0.1, 0.1, 0.1), light = plan.transform(0.9, 0.9, 0.9)
        #expect(dark.0 > dark.1 && dark.0 > dark.2, "dark parts turn red")
        #expect(abs(light.0 - light.1) < 0.03, "light parts hardly change")
        var blue = ColorAdjust(); blue.wheels.highlights = ColorWheel(x: 0, y: 0, luma: -1)
        #expect(ColorGrading.Plan(blue).transform(0.9, 0.9, 0.9).0 < 0.8, "luma − makes that part darker")
    }

    @Test func aWheelKeepsTheDirectionOfItsPuck() {
        let right = ColorWheel(x: 1, y: 0), up = ColorWheel(x: 0, y: -1)      // up on screen is −y
        #expect(abs(right.hue - 0) < 1e-9 && abs(up.hue - 0.25) < 1e-9 && right.amount == 1)
        #expect(ColorWheel(x: 3, y: 4).clamped().amount == 1, "the puck stays inside the circle")
        let t = ColorGrading.Plan.wheelTint(ColorWheel(x: 0.6, y: 0.2))
        #expect(abs(t.0 + t.1 + t.2) < 1e-9, "a tint does not change brightness")
    }

    @Test func hslMovesOnlyTheColoursNearTheChosenBand() {
        var c = ColorAdjust()
        c.hsl[.blue] = HSLAdjust(hue: 0, saturation: -1, luminance: 0)
        let plan = ColorGrading.Plan(c)
        let sky = plan.transform(0.2, 0.4, 0.9)
        #expect(abs(sky.0 - sky.2) < 0.45 * abs(0.2 - 0.9), "blue loses its colour")
        #expect(close(plan.transform(0.9, 0.2, 0.2), (0.9, 0.2, 0.2), 1e-6), "red is not touched")
        #expect(close(plan.transform(0.5, 0.5, 0.5), (0.5, 0.5, 0.5), 1e-9), "grey is not touched")
        var shift = ColorAdjust(); shift.hsl[.red] = HSLAdjust(hue: 1, saturation: 0, luminance: 0)
        let moved = ColorGrading.Plan(shift).transform(0.9, 0.2, 0.2)
        #expect(moved.1 > 0.2, "red turns a little towards orange")
    }

    @Test func vibranceHelpsDullColoursMoreThanVividOnes() {
        var c = ColorAdjust(); c.vibrance = 1
        let plan = ColorGrading.Plan(c)
        func chroma(_ x: (Double, Double, Double)) -> Double { max(x.0, x.1, x.2) - min(x.0, x.1, x.2) }
        let dullBefore = chroma((0.5, 0.45, 0.4)), vividBefore = chroma((0.9, 0.1, 0.1))
        let dullGain = chroma(plan.transform(0.5, 0.45, 0.4)) / dullBefore, vividGain = chroma(plan.transform(0.9, 0.1, 0.1)) / vividBefore
        #expect(dullGain > vividGain && dullGain > 1.2)
    }

    @Test func tintMovesBetweenGreenAndMagenta() {
        var c = ColorAdjust(); c.tint = 1
        let m = ColorGrading.Plan(c).transform(0.5, 0.5, 0.5)
        #expect(m.1 < 0.5 && m.0 > 0.5)
        c.tint = -1
        let g = ColorGrading.Plan(c).transform(0.5, 0.5, 0.5)
        #expect(g.1 > 0.5 && g.0 < 0.5)
    }

    // MARK: Look files

    let identity2 = """
    # a look that changes nothing
    TITLE "Plain"
    LUT_3D_SIZE 2
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

    @Test func aCubeFileIsRead() throws {
        let l = try CubeLUT.parse(identity2)
        #expect(l.size == 2 && l.title == "Plain" && l.data.count == 24)
        let s = l.sample(r: 0.3, g: 0.6, b: 0.9)
        #expect(abs(s.0 - 0.3) < 1e-6 && abs(s.1 - 0.6) < 1e-6 && abs(s.2 - 0.9) < 1e-6, "an identity look gives the same colour")
    }

    @Test func aLookThatSwapsColoursIsFollowed() throws {
        // red and blue swapped
        let swap = """
        LUT_3D_SIZE 2
        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """
        let l = try CubeLUT.parse(swap)
        let s = l.sample(r: 1, g: 0, b: 0)
        #expect(abs(s.0 - 0) < 1e-6 && abs(s.2 - 1) < 1e-6)
        var c = ColorAdjust(); c.lut = LutRef(name: "swap", path: "x", strength: 1)
        let out = ColorGrading.Plan(c, lut: l).transform(1, 0, 0)
        #expect(close(out, (0, 0, 1)))
        c.lut = LutRef(name: "swap", path: "x", strength: 0.5)
        #expect(close(ColorGrading.Plan(c, lut: l).transform(1, 0, 0), (0.5, 0, 0.5)), "strength mixes the look with the picture")
        c.lut = nil
        #expect(close(ColorGrading.Plan(c, lut: l).transform(1, 0, 0), (1, 0, 0)), "no look chosen: not used even if one is handed in")
    }

    @Test func badCubeFilesAreRefusedWithAReason() {
        #expect(throws: CubeLUT.ParseError.oneDimensional) { try CubeLUT.parse("LUT_1D_SIZE 16\n0 0 0") }
        #expect(throws: CubeLUT.ParseError.noSize) { try CubeLUT.parse("0 0 0") }
        #expect(throws: CubeLUT.ParseError.badSize(200)) { try CubeLUT.parse("LUT_3D_SIZE 200") }
        #expect(throws: CubeLUT.ParseError.wrongCount(expected: 8, found: 1)) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0") }
        #expect(throws: CubeLUT.ParseError.self) { try CubeLUT.parse("LUT_3D_SIZE 2\n0 x 0") }
        #expect(!CubeLUT.ParseError.oneDimensional.description.isEmpty)
    }

    // MARK: Histogram

    @Test func theHistogramCountsPixelsAndFindsClipping() {
        // 2×2: black, white, mid grey, pure red
        let px: [UInt8] = [0, 0, 0, 255,  255, 255, 255, 255,  128, 128, 128, 255,  255, 0, 0, 255]
        let h = Histogram.compute(bytes: px, width: 2, height: 2, bytesPerRow: 8)
        #expect(h.pixels == 4 && h.red[255] == 2 && h.red[0] == 1 && h.green[0] == 2 && h.luma[128] == 1)
        #expect(h.clippedDark == 0.25 && h.clippedLight == 0.25)
        #expect(Histogram.compute(bytes: [], width: 4, height: 4, bytesPerRow: 16).pixels == 0, "too little data counts nothing")
        let bgra = Histogram.compute(bytes: [10, 20, 30, 255], width: 1, height: 1, bytesPerRow: 4, red: 2, green: 1, blue: 0)
        #expect(bgra.red[30] == 1 && bgra.blue[10] == 1)
    }

    @Test func barHeightsAreNotFlattenedByASpikeAtTheEnd() {
        var counts = [Int](repeating: 0, count: 256)
        counts[0] = 10_000; counts[100] = 50; counts[101] = 25
        let h = Histogram().heights(of: counts)
        #expect(h[100] == 1 && h[101] == 0.5 && h[0] == 1, "the spike is cut at the top, the rest is readable")
    }
}
