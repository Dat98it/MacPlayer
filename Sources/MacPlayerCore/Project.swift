import Foundation

/// A source video as the project knows it. The `fingerprint` taken when it was added is how an outside change is noticed.
public struct SourceRef: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    /// Security-scoped bookmark made by the app; opaque to Core.
    public var bookmark: Data?
    public var fingerprint: FileFingerprint?
    public var info: MediaInfo?
    /// Set when the source was replaced through "Apply changes to the original": other projects using it must
    /// re-check their timing (design section 6).
    public var changedAfterReplace: Bool

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, fingerprint: FileFingerprint? = nil, info: MediaInfo? = nil, changedAfterReplace: Bool = false) {
        self.id = id; self.path = path; self.bookmark = bookmark; self.fingerprint = fingerprint; self.info = info; self.changedAfterReplace = changedAfterReplace
    }
}

/// Normalised crop rectangle (0...1, origin top-left) in the source picture.
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isFull: Bool { x == 0 && y == 0 && width == 1 && height == 1 }

    /// Clamped inside the picture with a minimum size, so a bad drag can never produce an empty or inverted crop.
    public func clamped(minSize: Double = 0.02) -> CropRect {
        let w = min(1, max(minSize, width)), h = min(1, max(minSize, height))
        return CropRect(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), width: w, height: h)
    }

    /// Crop of the given aspect ratio, as large as fits, centred (for 9:16 / 1:1 / 4:3 canvases).
    public static func centered(aspect: Double, sourceWidth: Double, sourceHeight: Double) -> CropRect {
        let srcAspect = sourceWidth / sourceHeight
        if srcAspect > aspect {
            let w = aspect / srcAspect
            return CropRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = srcAspect / aspect
            return CropRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }
}

public enum CanvasPreset: String, Codable, CaseIterable, Sendable {
    case source, landscape16x9, portrait9x16, square1x1, standard4x3
    public var aspect: Double? {
        switch self {
        case .source: return nil
        case .landscape16x9: return 16.0 / 9
        case .portrait9x16: return 9.0 / 16
        case .square1x1: return 1
        case .standard4x3: return 4.0 / 3
        }
    }
}

public struct ColorAdjust: Codable, Equatable, Sendable {
    /// All in -1...1 (0 = unchanged), except saturation/contrast where 0 also means unchanged.
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var saturation: Double = 0
    public var temperature: Double = 0
    public init() {}
    public var isNeutral: Bool { self == ColorAdjust() }
}

public struct AudioSettings: Codable, Equatable, Sendable {
    public var gainDB: Double = 0
    public var muted: Bool = false
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    /// Shift audio against video: positive delays the audio. Seconds.
    public var offsetSeconds: Double = 0
    /// Replace the source's audio with this file (kept as a reference, never modified).
    public var replacementPath: String?
    /// Noise reduction strength 0...1 (nil = off).
    public var denoise: Double?
    public init() {}
    public var isNeutral: Bool { self == AudioSettings() }
}

public enum FitMode: String, Codable, CaseIterable, Sendable { case fit, fill }

/// Everything that changes how the picture looks. Applied identically by the preview and the export.
public struct VideoLook: Codable, Equatable, Sendable {
    public var crop: CropRect = .full
    /// Clockwise quarter turns: 0, 90, 180, 270.
    public var rotation: Int = 0
    public var flipHorizontal = false
    public var flipVertical = false
    public var canvas: CanvasPreset = .source
    public var fit: FitMode = .fit
    public var color = ColorAdjust()
    /// Playback speed of the clip (1 = normal).
    public var speed: Double = 1
    public var effects = LookEffects()
    /// Zoom and move of the picture over the clip (none = still).
    public var motion: [MotionKeyframe] = []
    /// How this clip arrives from the one before it (project mode).
    public var transitionIn: ClipTransition?
    /// Steadies shaky footage: 0 = off, up to 1 = as steady as it gets (and the most cropped in).
    public var stabilize: Double = 0
    public init() {}

    public var changesPicture: Bool {
        !crop.isFull || rotation % 360 != 0 || flipHorizontal || flipVertical || canvas != .source || !color.isNeutral || !effects.isNeutral || !motion.isEmpty || transitionIn != nil || stabilize > 0
    }
    public var isNeutral: Bool { !changesPicture && speed == 1 }
}

extension VideoLook {
    enum CodingKeys: String, CodingKey { case crop, rotation, flipHorizontal, flipVertical, canvas, fit, color, speed, effects, motion, transitionIn, stabilize }

    /// Projects saved before `effects` existed have no such key: they open with no effects.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop) ?? .full
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        canvas = try c.decodeIfPresent(CanvasPreset.self, forKey: .canvas) ?? .source
        fit = try c.decodeIfPresent(FitMode.self, forKey: .fit) ?? .fit
        color = try c.decodeIfPresent(ColorAdjust.self, forKey: .color) ?? ColorAdjust()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        effects = try c.decodeIfPresent(LookEffects.self, forKey: .effects) ?? LookEffects()
        motion = try c.decodeIfPresent([MotionKeyframe].self, forKey: .motion) ?? []
        transitionIn = try c.decodeIfPresent(ClipTransition.self, forKey: .transitionIn)
        stabilize = try c.decodeIfPresent(Double.self, forKey: .stabilize) ?? 0
    }
}

public enum TextAlignmentChoice: String, Codable, CaseIterable, Sendable { case left, center, right }

public struct TextOverlay: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var start: MediaTime
    public var end: MediaTime
    public var fontName: String
    /// Font size as a fraction of the picture height, so it scales with the output size.
    public var sizeFraction: Double
    public var colorHex: String
    public var backgroundHex: String?
    public var alignment: TextAlignmentChoice
    /// Centre of the text box, normalised (0...1, origin top-left).
    public var x: Double
    public var y: Double
    public var fade: Double
    // Added later; all optional, so older projects open unchanged.
    /// Outline, shadow, letter spacing, capitals.
    public var flair: TextFlair?
    /// When set, a shape is drawn instead of text.
    public var shape: ShapeSpec?
    public var animationIn: ElementAnimation?
    public var animationOut: ElementAnimation?
    public var keyframes: [ElementKeyframe]?
    /// Size multiplier and turn (degrees clockwise) of the whole element.
    public var scale: Double?
    public var rotation: Double?

    public init(id: UUID = UUID(), text: String, start: MediaTime, end: MediaTime, fontName: String = "Helvetica-Bold", sizeFraction: Double = 0.06,
                colorHex: String = "#FFFFFF", backgroundHex: String? = nil, alignment: TextAlignmentChoice = .center,
                x: Double = 0.5, y: Double = 0.85, fade: Double = 0.2) {
        self.id = id; self.text = text; self.start = start; self.end = end; self.fontName = fontName; self.sizeFraction = sizeFraction
        self.colorHex = colorHex; self.backgroundHex = backgroundHex; self.alignment = alignment; self.x = x; self.y = y; self.fade = fade
    }

    /// A shape (or sticker-like drawing) at the same place in the model as text.
    public static func shape(_ spec: ShapeSpec, start: MediaTime, end: MediaTime, x: Double = 0.5, y: Double = 0.5) -> TextOverlay {
        var o = TextOverlay(text: "", start: start, end: end, x: x, y: y, fade: 0.15)
        o.shape = spec
        return o
    }

    public var isShape: Bool { shape != nil }
}

/// The three thumbnail features are separate on purpose (design section 9). Each has its own choice here.
public struct ThumbnailChoices: Codable, Equatable, Sendable {
    /// 1. Picture shown inside MacPlayer (library/playlist). Changes nothing outside the app.
    public var libraryTime: MediaTime?
    public var libraryImagePath: String?
    /// 2. Still exported as PNG/JPEG for the user to use elsewhere.
    public var exportTime: MediaTime?
    /// 3. Artwork embedded into the exported file, only where the container supports it.
    public var embedTime: MediaTime?
    public init() {}
}

/// One piece of the timeline: a range of one source, in order. Quick-edit mode has no timeline clips: the whole
/// source is the video and the selections say what to export.
public struct TimelineClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var sourceStart: MediaTime
    public var sourceEnd: MediaTime
    public var name: String
    public var look: VideoLook
    public var audio: AudioSettings

    public init(id: UUID = UUID(), sourceID: UUID, sourceStart: MediaTime, sourceEnd: MediaTime, name: String = "",
                look: VideoLook = VideoLook(), audio: AudioSettings = AudioSettings()) {
        self.id = id; self.sourceID = sourceID; self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.name = name; self.look = look; self.audio = audio
    }

    public var sourceSpan: TimeSpan { TimeSpan(start: sourceStart, end: sourceEnd) }
    /// Length on the timeline, after speed.
    public var duration: MediaTime {
        let d = sourceEnd - sourceStart
        return look.speed == 1 ? d : MediaTime(seconds: d.seconds / max(0.01, look.speed), timescale: d.timescale)
    }
}

public enum WorkMode: String, Codable, Sendable { case quick, project }

public struct Project: Codable, Identifiable, Equatable, Sendable {
    /// 1: first format. 2: adds `overlayClips` (layers over the main timeline).
    public static let currentSchema = 2

    public var schemaVersion: Int = Project.currentSchema
    public var id: UUID
    public var name: String
    public var mode: WorkMode
    public var sources: [SourceRef]
    /// Project mode: clips in timeline order. Quick mode: empty.
    public var timeline: [TimelineClip]
    public var selections: SelectionList
    public var markers: [Marker]
    /// Applied to the whole video in quick mode (and to every clip that has no look of its own in project mode).
    public var look: VideoLook
    public var audio: AudioSettings
    public var overlays: [TextOverlay]
    public var subtitles: SubtitleDocument
    public var thumbnails: ThumbnailChoices
    public var export: ExportOptions
    public var namingTemplate: NamingTemplate
    public var outputFolder: String?
    /// Videos and pictures laid over the main timeline (project mode).
    public var overlayClips: [OverlayClip]
    /// Music, voice-overs and sound effects on the timeline (project mode). Use `soundClips`.
    public var soundClipStore: [SoundClip]?
    /// The clip the Picture and Audio tools edit in project mode (nil = the whole-video settings of quick mode).
    public var activeClipID: UUID?
    /// Last playhead, so reopening continues where the user was.
    public var playhead: MediaTime
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), name: String, mode: WorkMode = .quick, sources: [SourceRef] = [], now: Date = Date()) {
        self.id = id; self.name = name; self.mode = mode; self.sources = sources
        timeline = []; overlayClips = []; selections = SelectionList(); markers = []; look = VideoLook(); audio = AudioSettings(); overlays = []
        subtitles = SubtitleDocument(); thumbnails = ThumbnailChoices(); export = ExportOptions(); namingTemplate = .default
        outputFolder = nil; activeClipID = nil; playhead = .zero; created = now; modified = now
    }

    public func source(_ id: UUID) -> SourceRef? { sources.first { $0.id == id } }

    /// The look the Picture tool edits: the selected clip's in project mode, the whole video's in quick mode.
    public var activeLook: VideoLook {
        get { activeClipIndex.map { timeline[$0].look } ?? look }
        set { if let i = activeClipIndex { timeline[i].look = newValue } else { look = newValue } }
    }

    public var activeAudio: AudioSettings {
        get { activeClipIndex.map { timeline[$0].audio } ?? audio }
        set { if let i = activeClipIndex { timeline[i].audio = newValue } else { audio = newValue } }
    }

    private var activeClipIndex: Int? {
        guard mode == .project, let id = activeClipID else { return nil }
        return timeline.firstIndex { $0.id == id }
    }

    /// Adds a source (or returns the one already there for the same file).
    @discardableResult
    public mutating func addSource(_ ref: SourceRef) -> UUID {
        let key = (ref.path as NSString).standardizingPath
        if let existing = sources.first(where: { ($0.path as NSString).standardizingPath == key }) { return existing.id }
        sources.append(ref)
        return ref.id
    }

    /// The layers as render specs. Layers whose video source is not in `resolve` are left out.
    public func layerSpecs(resolve: (UUID) -> String?) -> [LayerSpec] {
        overlayClips.compactMap { c in
            let kind: LayerSpec.Kind
            switch c.kind {
            case .video(let sid, let a, let b): guard let p = resolve(sid) else { return nil }; kind = .video(path: p, sourceStart: a, sourceEnd: b)
            case .image(let path, _): kind = .image(path: path)
            }
            return LayerSpec(id: c.id, kind: kind, lane: c.lane, start: c.start, duration: c.duration, transform: c.transform, keyframes: c.keyframes,
                             audio: c.audio, fadeIn: c.fadeIn, fadeOut: c.fadeOut)
        }
    }

    /// The timeline as pieces to render, in order. Clips whose source is missing are left out (and reported by the caller).
    public func renderPieces() -> [JobPiece] {
        timeline.compactMap { c in
            guard let src = source(c.sourceID) else { return nil }
            return JobPiece(sourcePath: src.path, span: c.sourceSpan, look: c.look, audio: c.audio)
        }
    }

    /// Applying changes to the original is only possible when exactly one source is involved (design section 6).
    public var canReplaceOriginal: Bool {
        switch mode {
        case .quick: return sources.count == 1
        case .project: return Set(timeline.map(\.sourceID)).count == 1 && sources.count == 1
        }
    }

    public var timelineDuration: MediaTime { timeline.reduce(.zero) { $0 + $1.duration } }

    /// Sources whose file is not on disk (checked by the caller with the file system).
    public func missingSources(fs: FileSystem) -> [SourceRef] { sources.filter { !fs.exists($0.path) } }

    /// Sources another app changed since they were added.
    public func changedSources(fs: FileSystem) -> [SourceRef] {
        sources.filter { s in
            guard let old = s.fingerprint, let now = try? fs.fingerprint(s.path) else { return false }
            return old != now
        }
    }
}

// MARK: Timeline editing (project mode)

public enum TimelineEditor {
    /// Splits the clip containing `at` (a timeline time, before speed) into two. Returns false if `at` is at an edge.
    @discardableResult
    public static func split(_ clips: inout [TimelineClip], clipID: UUID, atSourceTime t: MediaTime) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return false }
        let c = clips[i]
        guard t > c.sourceStart, t < c.sourceEnd else { return false }
        var a = c, b = c
        a.sourceEnd = t
        b.id = UUID(); b.sourceStart = t
        // The second part starts later in the animation: what the picture does from there on stays the same.
        b.look.motion = Motion.shifted(c.look.motion, by: -((t - c.sourceStart).seconds / max(0.01, c.look.speed)))
        if !c.name.isEmpty { a.name = c.name; b.name = c.name + " 2" }
        clips.replaceSubrange(i...i, with: [a, b])
        return true
    }

    /// Trims the clip's start or end in the source. Never empty, never outside `0...sourceDuration`.
    public static func trim(_ clips: inout [TimelineClip], clipID: UUID, start: MediaTime? = nil, end: MediaTime? = nil, sourceDuration: MediaTime) {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let minLen = MediaTime(value: 1, timescale: 30)
        var s = start ?? clips[i].sourceStart, e = end ?? clips[i].sourceEnd
        s = max(.zero, s); e = min(sourceDuration, e)
        if e - s < minLen { if start != nil { s = e - minLen } else { e = s + minLen } }
        guard s >= .zero, e <= sourceDuration, e > s else { return }
        if s != clips[i].sourceStart {
            clips[i].look.motion = Motion.shifted(clips[i].look.motion, by: -((s - clips[i].sourceStart).seconds / max(0.01, clips[i].look.speed)))
        }
        clips[i].sourceStart = s; clips[i].sourceEnd = e
    }

    /// Removes clips and closes the gap (ripple: later clips slide earlier, which is what the timeline already does).
    public static func rippleDelete(_ clips: inout [TimelineClip], ids: Set<UUID>) { clips.removeAll { ids.contains($0.id) } }

    public static func move(_ clips: inout [TimelineClip], fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { clips[$0] }
        for i in fromOffsets.sorted(by: >) { clips.remove(at: i) }
        let dest = toOffset - fromOffsets.filter { $0 < toOffset }.count
        clips.insert(contentsOf: moving, at: max(0, min(dest, clips.count)))
    }

    @discardableResult
    public static func duplicate(_ clips: inout [TimelineClip], id: UUID) -> UUID? {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
        var c = clips[i]; c.id = UUID()
        clips.insert(c, at: i + 1)
        return c.id
    }

    /// Timeline start time of each clip.
    public static func starts(_ clips: [TimelineClip]) -> [UUID: MediaTime] {
        var t = MediaTime.zero
        var out: [UUID: MediaTime] = [:]
        for c in clips { out[c.id] = t; t = t + c.duration }
        return out
    }
}


/// Where a timeline time falls: which clip, and the matching time in that clip's source.
public enum TimelineMap {
    public struct Location: Equatable, Sendable {
        public var index: Int
        public var clipID: UUID
        public var sourceTime: MediaTime
        public var timelineStart: MediaTime
    }

    /// Clamped into the timeline. The very end maps to the last instant of the last clip.
    public static func locate(_ clips: [TimelineClip], at t: MediaTime) -> Location? {
        guard !clips.isEmpty else { return nil }
        var start = MediaTime.zero
        for (i, c) in clips.enumerated() {
            let end = start + c.duration
            if t < end || i == clips.count - 1 {
                let into = min(max(t - start, .zero), c.duration)
                let src = c.sourceStart + MediaTime(seconds: into.seconds * max(0.01, c.look.speed), timescale: 6000)
                return Location(index: i, clipID: c.id, sourceTime: min(src, c.sourceEnd), timelineStart: start)
            }
            start = end
        }
        return nil
    }

    /// The timeline time at which `sourceTime` of clip `id` plays, or nil if that part of the source is not in the clip.
    public static func timelineTime(for sourceTime: MediaTime, inClip id: UUID, of clips: [TimelineClip]) -> MediaTime? {
        var start = MediaTime.zero
        for c in clips {
            if c.id == id {
                guard sourceTime >= c.sourceStart, sourceTime <= c.sourceEnd else { return nil }
                return start + MediaTime(seconds: (sourceTime - c.sourceStart).seconds / max(0.01, c.look.speed), timescale: 6000)
            }
            start = start + c.duration
        }
        return nil
    }
}
