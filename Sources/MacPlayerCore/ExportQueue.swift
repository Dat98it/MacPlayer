import Foundation

/// What to draw and change while exporting: the same description the preview uses, so the result matches it.
public struct RenderRecipe: Codable, Equatable, Sendable {
    public var look: VideoLook
    public var audio: AudioSettings
    public var overlays: [TextOverlay]
    public var subtitleStyle: SubtitleStyle
    /// Cues already shifted to the output's own time (0 = first frame of the exported file).
    public var burnedInCues: [SubtitleCue]
    /// Videos and pictures laid over the main picture, with their own times on the output timeline.
    public var layers: [LayerSpec]
    /// Music, voice-overs and effects on the output timeline.
    public var soundClips: [SoundClip] = []

    public init(look: VideoLook = VideoLook(), audio: AudioSettings = AudioSettings(), overlays: [TextOverlay] = [],
                subtitleStyle: SubtitleStyle = SubtitleStyle(), burnedInCues: [SubtitleCue] = [], layers: [LayerSpec] = [], soundClips: [SoundClip] = []) {
        self.soundClips = soundClips
        self.look = look; self.audio = audio; self.overlays = overlays; self.subtitleStyle = subtitleStyle; self.burnedInCues = burnedInCues; self.layers = layers
    }

    private enum CodingKeys: String, CodingKey { case look, audio, overlays, subtitleStyle, burnedInCues, layers, soundClips }

    /// Queue files saved before layers existed have no `layers` key.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        look = try c.decode(VideoLook.self, forKey: .look); audio = try c.decode(AudioSettings.self, forKey: .audio)
        overlays = try c.decode([TextOverlay].self, forKey: .overlays); subtitleStyle = try c.decode(SubtitleStyle.self, forKey: .subtitleStyle)
        burnedInCues = try c.decode([SubtitleCue].self, forKey: .burnedInCues); layers = try c.decodeIfPresent([LayerSpec].self, forKey: .layers) ?? []
        soundClips = try c.decodeIfPresent([SoundClip].self, forKey: .soundClips) ?? []
    }

    /// True when the picture or sound must be processed, so a stream copy ("fast cut") is not possible.
    public var needsReencode: Bool { !layers.isEmpty || !soundClips.isEmpty || audio.denoise != nil || audio.fx != nil || look.changesPicture || !overlays.isEmpty || !burnedInCues.isEmpty || audio.gainDB != 0 || audio.muted || audio.fadeIn > 0 || audio.fadeOut > 0 || look.speed != 1 || audio.replacementPath != nil || audio.offsetSeconds != 0 }
}

/// Where a finished export goes.
public enum SaveTarget: Codable, Equatable, Sendable {
    /// A new file. Never overwrites unless `overwrite` was confirmed.
    case newCopy(path: String, overwrite: Bool)
    /// Replace the source (explicit confirmation happened before this job was queued).
    case replaceOriginal(path: String, expected: FileFingerprint, backupFolder: String?)
}

public enum JobState: Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded(path: String)
    case failed(message: String)
    case cancelled

    public var isFinished: Bool {
        switch self { case .succeeded, .failed, .cancelled: return true; default: return false }
    }
}

public struct ExportJob: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var sourcePaths: [String]
    /// Source ranges laid end to end in the output (one range for a plain clip).
    public var pieces: [JobPiece]
    public var recipe: RenderRecipe
    public var options: ExportOptions
    public var target: SaveTarget
    public var state: JobState
    public var progress: Double
    public var priority: Int
    public var created: Date
    public var finished: Date?
    /// Still image to export next to the video (per-clip thumbnail), if chosen.
    public var thumbnailTime: MediaTime?
    /// Set when a job that was running when the app quit is queued again.
    public var restoredAfterCrash: Bool
    /// Frame to embed as the file's cover art (third thumbnail feature), if chosen and the container supports it.
    public var embedArtworkTime: MediaTime?
    /// Subtitles written next to the video as an .srt file (when they are not burned in). Already in output time.
    public var sidecarSubtitles: [SubtitleCue]

    public init(id: UUID = UUID(), label: String, pieces: [JobPiece], recipe: RenderRecipe = RenderRecipe(), options: ExportOptions,
                target: SaveTarget, priority: Int = 0, thumbnailTime: MediaTime? = nil, embedArtworkTime: MediaTime? = nil,
                sidecarSubtitles: [SubtitleCue] = [], now: Date = Date()) {
        self.id = id; self.label = label; self.pieces = pieces; self.recipe = recipe; self.options = options; self.target = target
        self.sourcePaths = Array(Set(pieces.map(\.sourcePath) + recipe.layers.map(\.path))).sorted()
        state = .queued; progress = 0; self.priority = priority; created = now; finished = nil; self.thumbnailTime = thumbnailTime
        restoredAfterCrash = false; self.embedArtworkTime = embedArtworkTime; self.sidecarSubtitles = sidecarSubtitles
    }

    public var outputPath: String {
        switch target { case .newCopy(let p, _): return p; case .replaceOriginal(let p, _, _): return p }
    }
}

public struct JobPiece: Codable, Equatable, Sendable {
    public var sourcePath: String
    public var span: TimeSpan
    /// This piece's own look/sound (project clips). nil = use the job's recipe.
    public var look: VideoLook?
    public var audio: AudioSettings?
    public init(sourcePath: String, span: TimeSpan, look: VideoLook? = nil, audio: AudioSettings? = nil) {
        self.sourcePath = sourcePath; self.span = span; self.look = look; self.audio = audio
    }
}

/// The export queue's state. Execution lives elsewhere; this decides what runs next and survives a crash.
/// One job failing never affects the others (design section 11 and flow B).
public struct ExportQueueModel: Codable, Equatable, Sendable {
    public var jobs: [ExportJob] = []
    public var maxConcurrent = 1

    public init() {}

    public mutating func enqueue(_ job: ExportJob) { jobs.append(job) }

    public mutating func enqueue(_ list: [ExportJob]) { jobs.append(contentsOf: list) }

    public var running: [ExportJob] { jobs.filter { $0.state == .running } }
    public var pending: [ExportJob] { jobs.filter { $0.state == .queued } }
    public var hasWork: Bool { !running.isEmpty || !pending.isEmpty }

    /// Jobs to start now: highest priority first, then oldest, within the concurrency limit.
    public func nextToStart() -> [ExportJob] {
        let free = max(0, maxConcurrent - running.count)
        return Array(pending.sorted { ($0.priority, $1.created) > ($1.priority, $0.created) }.prefix(free))
    }

    private mutating func update(_ id: UUID, _ f: (inout ExportJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { f(&jobs[i]) }
    }

    public mutating func markRunning(_ id: UUID) { update(id) { if $0.state == .queued { $0.state = .running; $0.progress = 0 } } }
    public mutating func setProgress(_ id: UUID, _ p: Double) { update(id) { if $0.state == .running { $0.progress = max($0.progress, min(1, p)) } } }
    public mutating func markSucceeded(_ id: UUID, path: String, at: Date = Date()) { update(id) { $0.state = .succeeded(path: path); $0.progress = 1; $0.finished = at } }
    public mutating func markFailed(_ id: UUID, message: String, at: Date = Date()) { update(id) { $0.state = .failed(message: message); $0.finished = at } }

    /// Cancels a queued or running job. A running one is stopped by the executor, which then reports back.
    public mutating func cancel(_ id: UUID, at: Date = Date()) {
        update(id) { if !$0.state.isFinished { $0.state = .cancelled; $0.finished = at } }
    }

    public mutating func retry(_ id: UUID) {
        update(id) {
            switch $0.state { case .failed, .cancelled: $0.state = .queued; $0.progress = 0; $0.finished = nil; default: break }
        }
    }

    public mutating func retryAllFailed() { for j in jobs where { if case .failed = j.state { return true }; return false }() { retry(j.id) } }
    public mutating func removeFinished() { jobs.removeAll { $0.state.isFinished } }
    public mutating func remove(_ id: UUID) { jobs.removeAll { $0.id == id && $0.state != .running } }
    public mutating func setPriority(_ id: UUID, _ p: Int) { update(id) { $0.priority = p } }

    /// After a crash or quit mid-export: running jobs go back to the queue (no checkpoint resume), flagged so the
    /// UI can say so. Their partial files are removed by the executor via the recorded temp path convention.
    public mutating func restoreAfterCrash() {
        for i in jobs.indices where jobs[i].state == .running {
            jobs[i].state = .queued; jobs[i].progress = 0; jobs[i].restoredAfterCrash = true
        }
    }

    public var summary: (succeeded: Int, failed: Int, cancelled: Int, remaining: Int) {
        var s = 0, f = 0, c = 0, r = 0
        for j in jobs {
            switch j.state { case .succeeded: s += 1; case .failed: f += 1; case .cancelled: c += 1; default: r += 1 }
        }
        return (s, f, c, r)
    }
}

/// Keeps the queue on disk so it comes back after a crash.
public final class QueueStore {
    private let fs: FileSystem
    private let path: String

    public init(fs: FileSystem, path: String) { self.fs = fs; self.path = path }

    public func save(_ q: ExportQueueModel) throws {
        try fs.writeAtomically(try JSONEncoder().encode(q), to: path)
    }

    /// Loads and applies crash restore. A damaged queue file is set aside (not deleted) and an empty queue is used.
    public func load() -> ExportQueueModel {
        guard fs.exists(path), let data = try? fs.read(path) else { return ExportQueueModel() }
        guard var q = try? JSONDecoder().decode(ExportQueueModel.self, from: data) else {
            try? fs.move(from: path, to: path + ".damaged-\(Int(Date().timeIntervalSince1970))")
            return ExportQueueModel()
        }
        q.restoreAfterCrash()
        return q
    }
}
