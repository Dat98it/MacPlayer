import Foundation

public enum CutPlanning {
    /// Media files store timestamps rounded to their own timescale (600 for many writers), so a frame's real
    /// presentation time can sit a few microseconds before or after the ideal `index * 1001/30000`.
    ///
    /// AVFoundation keeps a frame when the frame's display interval `[t, t + duration)` overlaps the requested
    /// range (measured on the 29.97 fps sample: this rule, not "pts >= start"). A boundary placed exactly on an
    /// ideal frame time is therefore at the mercy of that rounding and can keep one frame too many.
    ///
    /// `span` names frame boundaries: `start` is the time of the first frame to keep, `end` the time of the
    /// first frame to drop. The start moves forward and the end backward by half a frame, so each boundary sits
    /// midway inside a frame interval and the same frames are kept whatever the rounding.
    public static func guarded(_ span: TimeSpan, frameRate: FrameRate, duration: MediaTime) -> TimeSpan {
        let half = MediaTime(value: Int64(frameRate.denominator), timescale: frameRate.numerator * 2)
        let start = span.start + half
        // Cutting to the very end of the file: nothing follows, so keep everything up to the duration.
        let end = span.end >= duration ? duration : span.end - half
        return TimeSpan(start: min(start, end), end: end)
    }

    /// The compositor path renders on a fixed grid of output frames (one every `frameDuration`) and asks the source for
    /// whatever is on screen at each grid time. So the output keeps exactly `span.duration` on the grid, and every grid time is
    /// aimed at the middle of its source frame (the source range moves forward half a frame), which survives the
    /// file's timestamp rounding. Trimming both ends, as `guarded` does for a straight copy, would leave the grid one frame short.
    public static func centerSampled(_ span: TimeSpan, frameRate: FrameRate, duration: MediaTime) -> (source: TimeSpan, length: MediaTime) {
        let half = MediaTime(value: Int64(frameRate.denominator), timescale: frameRate.numerator * 2)
        let start = min(span.start + half, duration)
        // The length is a whole number of output frames: the nearest one to the span. Real files store times rounded to a millisecond or a
        // 1/600 s tick, so a span between two frame times can come out a few hundredths of a frame long, and counting a partial frame as a
        // whole one would put the first frame after the cut at the end of the clip.
        let frames = max(1, (span.duration.seconds / frameRate.frameDuration.seconds).rounded())
        let length = MediaTime(value: Int64(frames) * Int64(frameRate.denominator), timescale: frameRate.numerator)
        // The source range is no longer than the grid: the composition's instructions have to cover all of the media in it.
        return (TimeSpan(start: start, end: min(start + length, duration)), length)
    }
}
