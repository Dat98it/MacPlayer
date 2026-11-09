import Foundation

/// A ready-made colour treatment, one tap.
public enum FilterPreset: String, Codable, CaseIterable, Sendable {
    case none, vivid, warm, cool, cinematic, vintage, fade, film, mono, noir, dramatic
}

/// Looks beyond plain colour controls: a filter, edge darkening, blur, sharpening, and a blurred backdrop for video that does not
/// fill the frame. Part of `VideoLook`, so the preview and the export draw it the same way.
public struct LookEffects: Codable, Equatable, Sendable {
    public var filter: FilterPreset = .none
    /// How much of the filter shows: 0 = none, 1 = all of it.
    public var filterAmount = 1.0
    /// All 0...1 (0 = off).
    public var vignette = 0.0
    public var blur = 0.0
    public var sharpen = 0.0
    /// Fills the bars around a video that does not fit the frame with a blurred, enlarged copy of the video itself.
    public var blurBackground = false
    public var blurBackgroundAmount = 0.5

    public init() {}

    public var isNeutral: Bool { self == LookEffects() || (filter == .none && vignette == 0 && blur == 0 && sharpen == 0 && !blurBackground) }

    /// Keeps every value inside what the renderer expects.
    public func clamped() -> LookEffects {
        var e = self
        func c(_ x: Double) -> Double { min(max(x, 0), 1) }
        e.filterAmount = c(filterAmount); e.vignette = c(vignette); e.blur = c(blur); e.sharpen = c(sharpen); e.blurBackgroundAmount = c(blurBackgroundAmount)
        return e
    }
}

/// Makes one colour see-through (a green or blue backdrop), so what is behind a layer shows through it.
public struct ChromaKey: Codable, Equatable, Sendable {
    public var colorHex = "#00FF00"
    /// How far from the key colour a pixel may be and still disappear: 0...1.
    public var tolerance = 0.3
    /// How soft the edge between the removed and the kept parts is: 0...1.
    public var softness = 0.15
    public init(colorHex: String = "#00FF00", tolerance: Double = 0.3, softness: Double = 0.15) {
        self.colorHex = colorHex; self.tolerance = tolerance; self.softness = softness
    }
}
