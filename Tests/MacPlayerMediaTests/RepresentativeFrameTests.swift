import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

/// The picture shown for a video in lists and grids comes from the middle of it, not from the start.
struct RepresentativeFrameTests {
    @Test func theFrameComesFromTheMiddleOfTheVideo() async throws {
        // 8 s at 30 fps: the middle is frame 120. A nearby keyframe is allowed (a key frame every 30 frames).
        let src = try await Fixtures.shared.source(.init(seconds: 8, gop: 30))
        let img = try await FrameGrabber.representativeImage(url: src)
        let index = try #require(FrameGrabber.syntheticIndex(of: img), "the picture carries the frame number")
        #expect(abs(index - 120) <= 30, "got frame \(index), the middle is 120")
        #expect(index > 30, "not the first second, where the old thumbnail came from")
    }

    @Test func aSmallThumbnailIsStillScaledDown() async throws {
        let src = try await Fixtures.shared.source(.init(seconds: 4, gop: 30))
        let img = try await FrameGrabber.representativeImage(url: src, maxSize: CGSize(width: 120, height: 68))
        #expect(img.width <= 120 && img.height <= 68 && img.width > 0)
    }

    @Test func aFileThatCannotBeReadGivesAnErrorNotACrash() async {
        let missing = URL(fileURLWithPath: "/nonexistent/folder/none.mp4")
        await #expect(throws: (any Error).self) { _ = try await FrameGrabber.representativeImage(url: missing) }
    }
}
