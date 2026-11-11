import Foundation

/// One choice for how big and how good an exported video is (0.14). "Quality" and "Size" were two menus that looked alike and were easy
/// to mix up; each choice here sets both.
public enum ExportPreset: String, CaseIterable, Sendable {
    case original, uhd2160, fullHD1080, hd720, small480

    public var quality: QualityLevel {
        switch self { case .original, .uhd2160, .fullHD1080: return .high; case .hd720: return .medium; case .small480: return .small }
    }
    public var resolution: ResolutionLimit {
        switch self { case .original: return .source; case .uhd2160: return .p2160; case .fullHD1080: return .p1080; case .hd720: return .p720; case .small480: return .p480 }
    }

    /// The choice the options already match, if any.
    public init?(options o: ExportOptions) {
        guard let p = ExportPreset.allCases.first(where: { $0.quality == o.quality && $0.resolution == o.resolution }) else { return nil }
        self = p
    }

    public func apply(to o: inout ExportOptions) { o.quality = quality; o.resolution = resolution }
}

/// The shape of the finished video and what fills it, set on the whole project at once (the picture of every clip).
public enum FrameFill: String, CaseIterable, Sendable {
    /// The whole picture, with black bars where it does not fill the frame.
    case fit
    /// The frame filled, the edges of the picture cut off.
    case fill
    /// The whole picture over a blurred, enlarged copy of itself (no black bars).
    case blurredBars
}

public extension Project {
    /// The shape of the finished video (the first clip's: the export takes its size from it).
    var frameShape: CanvasPreset { timeline.first?.look.canvas ?? look.canvas }

    var frameFill: FrameFill {
        let l = timeline.first?.look ?? look
        if l.fit == .fill { return .fill }
        return l.effects.blurBackground ? .blurredBars : .fit
    }

    /// Gives every clip (a photo project: the photo) the same frame shape and the same way of filling it.
    mutating func setFrame(_ shape: CanvasPreset, fill: FrameFill) {
        func apply(_ l: inout VideoLook) {
            l.canvas = shape
            l.fit = fill == .fill ? .fill : .fit
            l.effects.blurBackground = fill == .blurredBars
        }
        if timeline.isEmpty { apply(&look) } else { for i in timeline.indices { apply(&timeline[i].look) } }
    }
}
