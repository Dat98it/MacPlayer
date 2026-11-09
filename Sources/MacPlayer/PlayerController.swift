import AVFoundation
import AppKit
import Combine
import MacPlayerCore
import MacPlayerMedia

enum LoopMode: Equatable { case off, whole, range(TimeSpan) }

/// Playback: open, play, seek (always to the exact frame), step by frame, speed, A-B loop, sequences of ranges.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    let player = AVPlayer()
    @Published private(set) var currentTime: MediaTime = .zero
    @Published private(set) var duration: MediaTime = .zero
    @Published private(set) var isPlaying = false
    @Published private(set) var speed: Float = 1
    @Published var loop: LoopMode = .off { didSet { installBoundary() } }
    @Published var failure: String?
    @Published var volume: Float = 1 { didSet { player.volume = volume } }
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var legibleOptions: [AVMediaSelectionOption] = []

    var onEnded: (() -> Void)?
    var preservePitch = true

    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var seekInFlight = false
    private var pendingSeek: MediaTime?
    /// Ranges to play one after another ("preview the chosen clips").
    private var sequence: [TimeSpan] = []
    private var sequenceIndex = 0

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.isNumeric else { return }
                self.currentTime = MediaTime(t)
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    deinit { if let o = timeObserver { player.removeTimeObserver(o) } }

    // MARK: Loading

    /// Opens a source for viewing. `preview` plays the edited composition (same renderer as the export).
    /// How many seeks have been asked for so far. A caller that builds a preview slowly notes this first and passes it back,
    /// so that a seek made while it was building is not undone.
    var seekGeneration: Int { seekCount }

    func load(url: URL, preview: BuiltRender?, at requestedStart: MediaTime? = nil, since generation: Int? = nil) async {
        var start = requestedStart
        if let g = generation, g != seekCount { start = effectiveTime }   // the user moved while the preview was being built
        pause()
        failure = nil
        let newItem: AVPlayerItem
        if let p = preview {
            newItem = AVPlayerItem(asset: p.composition)
            newItem.videoComposition = p.videoComposition
            newItem.audioMix = p.audioMix
        } else {
            newItem = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        }
        newItem.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
        install(newItem)
        // The playhead stays where it is going to be, from the start of the load: it must not flash back to 0 (the timecode
        // would flicker and an edit made at that moment would use the wrong time), and a seek that arrives meanwhile wins.
        currentTime = start ?? .zero
        let seeksBefore = seekCount
        if let d = try? await newItem.asset.load(.duration), d.isNumeric { duration = MediaTime(d) }
        // Put the playhead back where it was, unless a newer seek happened while this was loading (that one wins).
        if let s = start, s > .zero, seekCount == seeksBefore { await performSeek(to: s) }
        await loadSelectionGroups(newItem.asset)
    }

    /// Nothing to show (a project whose media is missing).
    func unload() {
        pause()
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObservation = nil
        item = nil
        player.replaceCurrentItem(with: nil)
        duration = .zero; currentTime = .zero
    }

    private func install(_ newItem: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        statusObservation = nil
        item = newItem
        player.replaceCurrentItem(with: newItem)
        statusObservation = newItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            let failed = it.status == .failed
            let message = it.error?.localizedDescription
            Task { @MainActor in if failed { self?.failure = message ?? L("This file cannot be played.") } }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }
        installBoundary()
    }

    private func loadSelectionGroups(_ asset: AVAsset) async {
        if let g = try? await asset.loadMediaSelectionGroup(for: .audible) { audioOptions = g.options } else { audioOptions = [] }
        if let g = try? await asset.loadMediaSelectionGroup(for: .legible) { legibleOptions = g.options } else { legibleOptions = [] }
    }

    func selectAudio(_ option: AVMediaSelectionOption) async {
        guard let item, let g = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        item.select(option, in: g)
    }

    func selectLegible(_ option: AVMediaSelectionOption?) async {
        guard let item, let g = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if let o = option { item.select(o, in: g) } else { item.select(nil, in: g) }
    }

    // MARK: Transport

    func play() {
        guard item != nil else { return }
        if duration > .zero, currentTime >= duration - MediaTime(value: 1, timescale: 30) { Task { await seek(to: .zero); player.rate = speed } }
        else { player.rate = speed }
        isPlaying = true
    }

    func pause() { player.pause(); isPlaying = false; sequence = [] }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Speed 0.25x...4x (design section 4).
    func setSpeed(_ s: Float) {
        speed = max(0.25, min(4, s))
        if isPlaying { player.rate = speed }
    }

    /// Counts the seeks the user (or the UI) asked for, so a rebuild that finishes later does not undo a newer one.
    private var seekCount = 0

    /// Exact seek: the frame at `t`, not the nearest keyframe.
    func seek(to t: MediaTime) async {
        seekCount += 1
        let mine = seekCount
        latestTarget = t
        await performSeek(to: t)
        if seekCount == mine { latestTarget = nil }
    }

    /// Where the last seek is heading while it is still under way (nil once it has arrived).
    private(set) var latestTarget: MediaTime?

    /// The position to keep when something rebuilds the preview: the target of a seek in flight, else the current time.
    /// (`currentTime` alone is still the old position until the seek lands, and a rebuild would put the playhead back there.)
    var effectiveTime: MediaTime { latestTarget ?? currentTime }

    private func performSeek(to t: MediaTime) async {
        let clamped = min(max(t, .zero), duration > .zero ? duration : t)
        let itemAtStart = player.currentItem
        await player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        // If the item was replaced while seeking (a rebuilt preview), this seek was cut short and the new item's time is
        // not its result; the rebuild puts the playhead where it belongs.
        guard player.currentItem === itemAtStart else { return }
        currentTime = MediaTime(player.currentTime())
    }

    /// For dragging the playhead: always chases the latest target, never queues up old ones.
    func scrub(to t: MediaTime) {
        pendingSeek = t
        guard !seekInFlight else { return }
        seekInFlight = true
        Task { @MainActor in
            while let target = pendingSeek { pendingSeek = nil; await seek(to: target) }
            seekInFlight = false
        }
    }

    /// Set by the session: finds the frame `count` frames from a time using the file's real frame times.
    var frameStepper: FrameStepper?

    /// One frame (or `count` frames) forward or back, using the file's real frame times.
    func step(frames count: Int) {
        pause()
        let from = currentTime
        Task { @MainActor in
            if let target = await frameStepper?.step(from: from, by: count) {
                await seek(to: target)
            } else {
                item?.step(byCount: count)
                try? await Task.sleep(nanoseconds: 120_000_000)
                currentTime = MediaTime(player.currentTime())
            }
        }
    }

    /// Draws the frame on screen again (after a live change to a layer). While playing, the next frame already does.
    func refreshFrame() {
        guard !isPlaying, item != nil else { return }
        scrub(to: currentTime)
    }

    func skip(seconds: Double) { Task { await seek(to: currentTime + MediaTime(seconds: seconds, timescale: 600)) } }

    // MARK: Loop, A-B and sequences

    private func installBoundary() {
        if let o = boundaryObserver { player.removeTimeObserver(o); boundaryObserver = nil }
        var end: MediaTime?
        if case .range(let r) = loop { end = r.end }
        if let e = sequence.first(where: { _ in true }).map({ _ in sequence[sequenceIndex].end }) { end = e }
        guard let e = end else { return }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: e.cmTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.didReachBoundary() }
        }
    }

    private func didReachBoundary() {
        if !sequence.isEmpty {
            sequenceIndex += 1
            if sequenceIndex < sequence.count {
                let next = sequence[sequenceIndex]
                Task { await seek(to: next.start); player.rate = speed; installBoundary() }
            } else { sequence = []; pause() }
            return
        }
        if case .range(let r) = loop { Task { await seek(to: r.start); if isPlaying { player.rate = speed } } }
    }

    /// Plays the given ranges one after the other, then stops.
    func playSequence(_ spans: [TimeSpan]) {
        guard let first = spans.first else { return }
        sequence = spans; sequenceIndex = 0
        Task { await seek(to: first.start); installBoundary(); player.rate = speed; isPlaying = true }
    }

    private func didReachEnd() {
        isPlaying = false
        if loop == .whole { Task { await seek(to: .zero); play() }; return }
        onEnded?()
    }
}
