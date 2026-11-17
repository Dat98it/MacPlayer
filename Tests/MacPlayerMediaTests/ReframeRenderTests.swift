import AVFoundation
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

    @Test func theFrameStaysOnThePersonItFollows() {
        // Two players of about the same size: the one followed so far is kept, a far small one never counts.
        let a = CGRect(x: 0.1, y: 0.3, width: 0.1, height: 0.4), b = CGRect(x: 0.7, y: 0.3, width: 0.12, height: 0.4), crowd = CGRect(x: 0.45, y: 0.1, width: 0.02, height: 0.05)
        #expect(abs(PersonTracker.pick([a, b, crowd], near: nil)!.x - 0.76) < 0.001, "at the start: the biggest")
        #expect(abs(PersonTracker.pick([a, b, crowd], near: (0.16, 0.5))!.x - 0.15) < 0.001, "then the one near where the frame was")
        #expect(abs(PersonTracker.pick([b, crowd], near: (0.16, 0.5))!.x - 0.76) < 0.001, "gone: the biggest again")
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
            // How well a 9:16 frame cut from a 16:9 picture (a third of its width) keeps the biggest person in view, and how much it moves,
            // for a few settings and for a frame that stays in the middle.
            let half = (9.0 / 16) / (16.0 / 9) / 2
            let mains = s.compactMap { p in p.main.map { (p.time, $0.x) } }
            func score(_ k: [ReframeKey]) -> String {
                let inView = mains.filter { m in abs((Reframe.center(k, at: m.0)?.x ?? 0.5) - m.1) <= half }.count
                var travel = 0.0, prev = Reframe.center(k, at: a)?.x ?? 0.5
                for t in stride(from: a, through: a + d, by: 0.1) { let x = Reframe.center(k, at: t)?.x ?? 0.5; travel += abs(x - prev); prev = x }
                return String(format: "%d/%d %.1fw", inView, mains.count, travel)
            }
            var row = "middle " + score([ReframeKey(time: 0, x: 0.5, y: 0.5)])
            for (dz, sp, sm) in [(0.06, 0.35, 1.0), (0.06, 0.6, 0.6), (0.04, 0.8, 0.5), (0.08, 0.6, 1.0)] {
                row += String(format: " | dz%.2f sp%.1f sm%.1f ", dz, sp, sm) + score(Reframe.path(s, deadZone: dz, maxSpeed: sp, smoothing: sm))
            }
            print("FIT", (f[0] as NSString).lastPathComponent.prefix(14), row)
            print("PATH", k.map { String(format: "%.2f@%.1f", $0.x, $0.time) }.joined(separator: " "))
        }
    }
}

extension ReframeRenderTests {
    /// With MACPLAYER_SILENCE_FILES="path|…": the silences found in real recordings (read only), and whether recognised words fall inside
    /// them (needs speech recognition allowed; otherwise only the loudness inside and outside is compared). Printed, not a check.
    @Test func silencesInRealRecordings() async throws {
        guard let list = ProcessInfo.processInfo.environment["MACPLAYER_SILENCE_FILES"] else { return }
        for path in list.split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let dur = try await asset.load(.duration).seconds
            let r = try await AudioAnalysis.rms(asset: asset, range: CMTimeRange(start: .zero, duration: CMTime(seconds: dur, preferredTimescale: 600)), frameSeconds: 0.05)
            let sil = SilenceFinder.silences(rms: r.frames, frameSeconds: 0.05)
            let total = sil.reduce(0) { $0 + $1.end - $1.start }
            func meanDB(_ a: Double, _ b: Double) -> Double {
                let f = r.frames[max(0, Int(a / 0.05))..<min(r.frames.count, max(Int(a / 0.05) + 1, Int(b / 0.05)))]
                return 20 * log10(max(1e-6, Double(f.reduce(0, +)) / Double(max(1, f.count))))
            }
            let inside = sil.map { meanDB($0.start, $0.end) }.reduce(0, +) / Double(max(1, sil.count))
            var line = String(format: "SILENCE %@ %.0fs: %d silences, %.1fs (%.0f%%), level inside %.0f dB vs whole %.0f dB", String(url.lastPathComponent.prefix(20)), dur, sil.count, total, total / dur * 100, inside, meanDB(0, dur))
            // Speech recognition aborts a test process (no usage text in its Info.plist): words are only checked inside the app.
            if ProcessInfo.processInfo.environment["MACPLAYER_SILENCE_WORDS"] != nil, let words = try? await SpeechTranscriber.transcribe(source: url, span: nil, locale: Locale(identifier: "vi-VN")) {
                let cut = words.filter { w in sil.contains { w.start + w.duration / 2 > $0.start && w.start + w.duration / 2 < $0.end } }
                line += String(format: " | %d words heard, %d inside a silence: %@", words.count, cut.count, cut.prefix(8).map { "\($0.text)@\(String(format: "%.1f", $0.start))" }.joined(separator: " "))
            } else { line += " | speech recognition not available" }
            print(line)
            print("SPANS", sil.prefix(20).map { String(format: "%.1f–%.1f", $0.start, $0.end) }.joined(separator: " "))
        }
    }
}
