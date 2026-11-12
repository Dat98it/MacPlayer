import Foundation

/// A source video as the project knows it. The `fingerprint` taken when it was added is how an outside change is noticed.
public struct SourceRef: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    /// Security-scoped bookmark made by the app; opaque to Core.
    public var bookmark: Data?
    public var fingerprint: FileFingerprint?
    public var info: MediaInfo?
    /// Set when this source is a photo on the main track: the photo's path. `path` is then the short video MacPlayer made of it in its own
    /// folder, which is made again from the photo when it is gone (0.10).
    public var stillOf: String?
    /// Set when this source is a sound (a song, a recording) on the main track: the sound's path. `path` is then the video MacPlayer made
    /// of it in its own folder (its cover picture with the sound), which is made again from the sound when it is gone (0.16).
    public var soundOf: String?

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, fingerprint: FileFingerprint? = nil, info: MediaInfo? = nil, stillOf: String? = nil, soundOf: String? = nil) {
        self.id = id; self.path = path; self.bookmark = bookmark; self.fingerprint = fingerprint; self.info = info; self.stillOf = stillOf; self.soundOf = soundOf
    }

    /// The file the person chose: the photo for a photo clip, the sound for a sound clip, else the video.
    public var mediaPath: String { stillOf ?? soundOf ?? path }
    /// A source MacPlayer made from another file (a photo or a sound), rather than a video of the person's.
    public var isMade: Bool { stillOf != nil || soundOf != nil }
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
    /// 0.14: Instagram's tall post.
    case portrait4x5
    public var aspect: Double? {
        switch self {
        case .source: return nil
        case .landscape16x9: return 16.0 / 9
        case .portrait9x16: return 9.0 / 16
        case .square1x1: return 1
        case .standard4x3: return 4.0 / 3
        case .portrait4x5: return 4.0 / 5
        }
    }
}

public struct ColorAdjust: Codable, Equatable, Hashable, Sendable {
    /// All in -1...1 (0 = unchanged), except saturation/contrast where 0 also means unchanged.
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var saturation: Double = 0
    public var temperature: Double = 0
    /// The finer tools (all -1...1, 0 = unchanged). They are drawn together with the curves, wheels, HSL and LUT in one pass (`ColorGrading`).
    public var exposure: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var vibrance: Double = 0
    /// Green (−) to magenta (+).
    public var tint: Double = 0
    public var curves = ColorCurves()
    public var wheels = ColorWheels()
    public var hsl = ColorHSL()
    public var lut: LutRef?
    public init() {}
    public var isNeutral: Bool { self == ColorAdjust() }

    /// Whether anything beyond the four basic sliders is set (those are drawn with Core Image's own colour filters, as they always were).
    public var needsGrade: Bool { exposure != 0 || highlights != 0 || shadows != 0 || vibrance != 0 || tint != 0 || !curves.isNeutral || !wheels.isNeutral || !hsl.isNeutral || lut != nil }
}

extension ColorAdjust {
    enum CodingKeys: String, CodingKey { case brightness, contrast, saturation, temperature, exposure, highlights, shadows, vibrance, tint, curves, wheels, hsl, lut }

    /// Projects saved before the finer tools existed have only the four basic values: the rest open unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        curves = try c.decodeIfPresent(ColorCurves.self, forKey: .curves) ?? ColorCurves()
        wheels = try c.decodeIfPresent(ColorWheels.self, forKey: .wheels) ?? ColorWheels()
        hsl = try c.decodeIfPresent(ColorHSL.self, forKey: .hsl) ?? ColorHSL()
        lut = try c.decodeIfPresent(LutRef.self, forKey: .lut)
    }
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
    /// Bass, treble, a higher or lower voice, a room, an echo (nil = none).
    public var fx: SoundFX?
    public init() {}
    public var isNeutral: Bool { self == AudioSettings() }

    enum CodingKeys: String, CodingKey { case gainDB, muted, fadeIn, fadeOut, offsetSeconds, replacementPath, denoise, fx }

    /// Every key is optional, so a file saved before a setting existed (or one that lacks a setting) still opens with that setting off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        offsetSeconds = try c.decodeIfPresent(Double.self, forKey: .offsetSeconds) ?? 0
        replacementPath = try c.decodeIfPresent(String.self, forKey: .replacementPath)
        denoise = try c.decodeIfPresent(Double.self, forKey: .denoise)
        fx = try c.decodeIfPresent(SoundFX.self, forKey: .fx)
    }
}

public enum FitMode: String, Codable, CaseIterable, Sendable { case fit, fill }

/// Everything that changes how the picture looks. Applied identically by the preview and the export.
public struct VideoLook: Codable, Equatable, Sendable {
    /// The slowest a clip may play. A freeze frame is one frame played this slowly, so the limit must be small; every length that
    /// depends on speed uses it, so the timeline, the preview and the export agree on how long a clip is.
    public static let minimumSpeed = 0.0001
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
    /// A colour made see-through (green screen), so the backdrop shows there.
    public var chromaKey: ChromaKey?
    /// Keeps only a shape of the picture.
    public var mask: MaskSpec?
    /// Cuts the person (or the main subject) out and drops the background.
    public var isolateSubject = false
    /// What fills the parts the picture no longer covers (after a cut-out, a mask or a key): a colour, or nil for black.
    public var backdropHex: String?
    public init() {}

    /// Whether anything makes parts of the picture see-through.
    public var cutsOut: Bool { chromaKey != nil || mask != nil || isolateSubject }

    public var changesPicture: Bool {
        !crop.isFull || rotation % 360 != 0 || flipHorizontal || flipVertical || canvas != .source || !color.isNeutral || !effects.isNeutral || !motion.isEmpty || transitionIn != nil || stabilize > 0 || cutsOut
    }
    public var isNeutral: Bool { !changesPicture && speed == 1 }
}

extension VideoLook {
    enum CodingKeys: String, CodingKey { case crop, rotation, flipHorizontal, flipVertical, canvas, fit, color, speed, effects, motion, transitionIn, stabilize, chromaKey, mask, isolateSubject, backdropHex }

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
        chromaKey = try c.decodeIfPresent(ChromaKey.self, forKey: .chromaKey)
        mask = try c.decodeIfPresent(MaskSpec.self, forKey: .mask)
        isolateSubject = try c.decodeIfPresent(Bool.self, forKey: .isolateSubject) ?? false
        backdropHex = try c.decodeIfPresent(String.self, forKey: .backdropHex)
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
    /// Elements and layers with the same group move and get selected together (0.12).
    public var groupID: UUID?
    /// A locked element cannot be moved, resized or deleted on the picture (0.12).
    public var locked: Bool?

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

/// One piece of the timeline of a video project: a range of one source, in order.
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
        return look.speed == 1 ? d : MediaTime(seconds: d.seconds / max(VideoLook.minimumSpeed, look.speed), timescale: d.timescale)
    }
}

/// How MacPlayer 0.7 and older kept an edit: "quick" (one video or photo, edited directly) or "project" (a timeline).
/// Only read from old files; `ProjectUpgrade` turns it into a `ProjectKind`.
public enum WorkMode: String, Codable, Sendable { case quick, project }

/// A project is either a video project (a timeline of videos) or a photo project (exactly one photo).
public enum ProjectKind: String, Codable, CaseIterable, Sendable { case video, photo }

public struct Project: Codable, Identifiable, Equatable, Sendable {
    /// 1: first format. 2: adds `overlayClips` (layers over the main timeline). 3: `kind` (video or photo) replaces `mode`.
    public static let currentSchema = 3

    public var schemaVersion: Int = Project.currentSchema
    public var id: UUID
    public var name: String
    public var kind: ProjectKind
    /// Only set while an old file (schema 2 or older) is being read; never written again (nil is left out of the JSON).
    public var mode: WorkMode?
    /// A photo project: 0 or 1 photo. A video project: the videos its timeline uses.
    public var sources: [SourceRef]
    /// Video project: clips in timeline order. Photo project: empty.
    public var timeline: [TimelineClip]
    /// In/Out ranges made by MacPlayer 0.7 and older. Kept in the file so nothing is lost; not shown or used any more.
    public var selections: SelectionList
    public var markers: [Marker]
    /// Photo project: the edit of the photo. Video project: unused (each clip has its own look).
    public var look: VideoLook
    public var audio: AudioSettings
    public var overlays: [TextOverlay]
    public var subtitles: SubtitleDocument
    public var thumbnails: ThumbnailChoices
    public var export: ExportOptions
    public var namingTemplate: NamingTemplate
    public var outputFolder: String?
    /// Video project: videos and pictures laid over the main timeline. Photo project: logos (pictures only, no time).
    public var overlayClips: [OverlayClip]
    /// Music, voice-overs and sound effects on the timeline (video project). Use `soundClips`.
    public var soundClipStore: [SoundClip]?
    /// The files brought into the project's library (0.9). Use `mediaBin`. Left out of the file when empty, so older MacPlayers still read it.
    public var binStore: [BinItem]?
    /// The clip the Picture and Audio tools edit in a video project.
    public var activeClipID: UUID?
    /// Last playhead, so reopening continues where the user was.
    public var playhead: MediaTime
    public var created: Date
    public var modified: Date
    /// An old one-video edit whose video length was not known when it was upgraded: the app makes its one clip once it has read the video.
    public var pendingQuickUpgrade: Bool?

    public init(id: UUID = UUID(), name: String, kind: ProjectKind, sources: [SourceRef] = [], now: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.mode = nil; self.sources = sources
        timeline = []; overlayClips = []; selections = SelectionList(); markers = []; look = VideoLook(); audio = AudioSettings(); overlays = []
        subtitles = SubtitleDocument(); thumbnails = ThumbnailChoices(); export = ExportOptions(); namingTemplate = .default
        outputFolder = nil; activeClipID = nil; playhead = .zero; created = now; modified = now; pendingQuickUpgrade = nil
    }

    public var isPhoto: Bool { kind == .photo }
    public var isVideo: Bool { kind == .video }

    public func source(_ id: UUID) -> SourceRef? { sources.first { $0.id == id } }

    /// The look the Picture tool edits: the photo's own in a photo project, the selected clip's in a video project.
    public var activeLook: VideoLook {
        get { activeClipIndex.map { timeline[$0].look } ?? look }
        set { if let i = activeClipIndex { timeline[i].look = newValue } else { look = newValue } }
    }

    public var activeAudio: AudioSettings {
        get { activeClipIndex.map { timeline[$0].audio } ?? audio }
        set { if let i = activeClipIndex { timeline[i].audio = newValue } else { audio = newValue } }
    }

    private var activeClipIndex: Int? {
        guard kind == .video, let id = activeClipID else { return nil }
        return timeline.firstIndex { $0.id == id }
    }

    /// Adds a source (or returns the one already there for the same file).
    @discardableResult
    public mutating func addSource(_ ref: SourceRef) -> UUID {
        if let existing = sources.first(where: { PathUtil.same($0.path, ref.path) }) { return existing.id }
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
                             audio: c.audio, fadeIn: c.fadeIn, fadeOut: c.fadeOut, animationIn: c.animationIn, animationOut: c.animationOut)
        }
    }

    /// The timeline as pieces to render, in order. Clips whose source is missing are left out (and reported by the caller).
    public func renderPieces() -> [JobPiece] {
        timeline.compactMap { c in
            guard let src = source(c.sourceID) else { return nil }
            return JobPiece(sourcePath: src.path, span: c.sourceSpan, look: c.look, audio: c.audio)
        }
    }

    /// A fast cut copies the stored picture and sound, so it is only possible when nothing changes either. This one test is used by the
    /// Export panel (to say so) and by the export plan (to refuse), so they can never disagree.
    public var allowsFastCut: Bool {
        look.isNeutral && overlays.isEmpty && audio.isNeutral && soundClips.isEmpty && !(subtitles.burnIn && !subtitles.cues.isEmpty)
            && timeline.allSatisfy { $0.look.isNeutral && $0.audio.isNeutral } && overlayClips.isEmpty
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
        b.look.motion = Motion.shifted(c.look.motion, by: -((t - c.sourceStart).seconds / max(VideoLook.minimumSpeed, c.look.speed)))
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
            clips[i].look.motion = Motion.shifted(clips[i].look.motion, by: -((s - clips[i].sourceStart).seconds / max(VideoLook.minimumSpeed, clips[i].look.speed)))
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
                let src = c.sourceStart + MediaTime(seconds: into.seconds * max(VideoLook.minimumSpeed, c.look.speed), timescale: 6000)
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
                return start + MediaTime(seconds: (sourceTime - c.sourceStart).seconds / max(VideoLook.minimumSpeed, c.look.speed), timescale: 6000)
            }
            start = start + c.duration
        }
        return nil
    }
}
