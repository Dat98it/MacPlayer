import CoreImage
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// 0.21: a wide picture in a tall frame, moved along the path of the people.
@Suite(.serialized) struct ReframeRenderTests {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// 320×180: red on the left third, green in the middle, blue on the right third.
    private var wide: CIImage {
        let r = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 107, height: 180))
        let g = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 107, y: 0, width: 106, height: 180))
        let b = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 213, y: 0, width: 107, height: 180))
        return r.composited(over: g).composited(over: b)
    }

    private func middle(_ keys: [ReframeKey]?, at t: Double, sourceStart: Double = 0, speed: Double = 1) -> (r: UInt8, g: UInt8, b: UInt8) {
        var look = VideoLook(); look.canvas = .portrait9x16; look.fit = .fill; look.reframe = keys
        var plan = PiecePlan(look: look, trackOrientation: .up, storedSize: PixelSize(width: 320, height: 180))
        plan.sourceStart = sourceStart; plan.speed = speed
        let out = RecipeCompositor.mainPicture(base: wide, plan: plan, time: t, outputSize: CGSize(width: 90, height: 160))
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 45, y: 80, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (px[0], px[1], px[2])
    }

    @Test func theFrameGoesWhereThePathSays() {
        #expect(middle(nil, at: 0).g > 200, "no path: the middle of the picture")
        let path = [ReframeKey(time: 0, x: 0.15, y: 0.5), ReframeKey(time: 10, x: 0.85, y: 0.5)]
        #expect(middle(path, at: 0).r > 200, "at the start: the left of the picture")
        #expect(middle(path, at: 10).b > 200, "at the end: the right")
        #expect(middle(path, at: 5).g > 200, "half way: the middle")
    }

    @Test func pathTimesAreSourceTimes() {
        // A clip from 10 s of its source at double speed: 2.5 s into the clip is 15 s of the source.
        let path = [ReframeKey(time: 10, x: 0.15, y: 0.5), ReframeKey(time: 15, x: 0.85, y: 0.5)]
        #expect(middle(path, at: 2.5, sourceStart: 10, speed: 2).b > 200)
    }

    @Test func theEdgeNeverShows() {
        // Asked for the very edge, the frame stops where the picture ends: no black.
        let p = middle([ReframeKey(time: 0, x: 0, y: 0.5)], at: 0)
        #expect(p.r > 200)
    }

    @Test func peopleFoundByAStandInDetectorGiveTheirMiddle() async throws {
        PersonTracker.detector = { _ in [CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.6), CGRect(x: 0.8, y: 0.8, width: 0.05, height: 0.1)] }
        defer { PersonTracker.detector = nil }
        let url = try await Fixtures.shared.source()
        let s = try await PersonTracker.track(url: url, span: TimeSpan(start: .zero, end: MediaTime(seconds: 1)), every: 0.25)
        #expect(s.count == 4)
        let c = try #require(s.first?.center)
        #expect(c.x < 0.3 && abs(c.y - 0.5) < 0.1, "the big person counts most: \(c)")
    }
}

extension ReframeRenderTests {
    /// With MACPLAYER_TRACK_FILES="path@start@seconds|…": where Vision finds people in real videos (read only), printed (not a check).
    @Test func peopleInRealVideos() async throws {
        guard let list = ProcessInfo.processInfo.environment["MACPLAYER_TRACK_FILES"] else { return }
        for item in list.split(separator: "|") {
            let f = item.split(separator: "@").map(String.init)
            let a = Double(f[1]) ?? 0, d = Double(f[2]) ?? 30
            let t0 = Date()
            let s = try await PersonTracker.track(url: URL(fileURLWithPath: f[0]), span: TimeSpan(start: MediaTime(seconds: a), end: MediaTime(seconds: a + d)), every: 0.5)
            let k = Reframe.path(s)
            let seen = s.filter { $0.center != nil }.count
            print("TRACK", (f[0] as NSString).lastPathComponent.prefix(24), "seen", seen, "of", s.count, String(format: "%.1fs", Date().timeIntervalSince(t0)),
                  "x", s.prefix(30).map { $0.center.map { String(format: "%.2f", $0.x) } ?? "-" }.joined(separator: " "))
            print("PATH", k.map { String(format: "%.2f@%.1f", $0.x, $0.time) }.joined(separator: " "))
        }
    }
}
