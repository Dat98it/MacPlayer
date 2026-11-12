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
    /// Which of `audioOptions` is playing now (the picker shows it).
    @Published private(set) var audioSelectionIndex = 0
    @Published private(set) var legibleOptions: [AVMediaSelectionOption] = []
    /// Playing from a web link (0.15): the player waits for data now (a spinner over the picture).
    @Published private(set) var isWaiting = false
    /// The item can play (false while a link is still connecting).
    @Published private(set) var isReady = false
    /// How far the data has arrived from the playhead on (a link), for the bar under the picture.
    @Published private(set) var bufferedUntil: MediaTime = .zero
    /// A live stream: no end, no seeking.
    @Published private(set) var isLive = false
    /// The picture's size as the item reports it (a stream says nothing else about itself).
    @Published private(set) var presentationSize: CGSize = .zero

    var onEnded: (() -> Void)?
    var preservePitch = true

    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservations: [NSKeyValueObservation] = []
    /// A link that stops sending data would leave the spinner turning for ever: after this long without any progress while
    /// it cannot play, it is stopped and the reason is shown (with Try Again).
    static var stallTimeout: TimeInterval = 20
    private var stallTimer: Timer?
    private var lastProgress = Date()
    private var lastMark: (MediaTime, MediaTime) = (.zero, .zero)
    private var waitObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var seekInFlight = false
    private var pendingSeek: MediaTime?
    /// Ranges to play one after another ("preview the chosen clips").
    private var sequence: [TimeSpan] = []
    private var sequenceIndex = 0

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        waitObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in if self?.isWaiting != waiting { self?.isWaiting = waiting } }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.isNumeric else { return }
                self.currentTime = MediaTime(t)
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    deinit { if let o = timeObserver { player.removeTimeObserver(o) }; stallTimer?.invalidate() }

    // MARK: Loading

    /// Opens a source for viewing. `preview` plays the edited composition (same renderer as the export).
    /// How many seeks have been asked for so far. A caller that builds a preview slowly notes this first and passes it back,
    /// so that a seek made while it was building is not undone.
    var seekGeneration: Int { seekCount }

    /// `streaming`: a web link (0.15). It is opened without asking for exact timing up front (that would read the whole file before the
    /// first frame), and a stream with no end is taken as live.
    func load(url: URL, preview: BuiltRender?, at requestedStart: MediaTime? = nil, since generation: Int? = nil, streaming: Bool = false, mimeType: String? = nil) async {
        var start = requestedStart
        if let g = generation, g != seekCount { start = effectiveTime }   // the user moved while the preview was being built
        pause()
        failure = nil
        let newItem: AVPlayerItem
        if let p = preview {
            newItem = AVPlayerItem(asset: p.composition)
            newItem.videoComposition = p.videoComposition
            newItem.audioMix = p.audioMix
        } else if streaming {
            newItem = AVPlayerItem(asset: AVURLAsset(url: url, options: mimeType.map { [AVURLAssetOverrideMIMETypeKey: $0] } ?? [:]))
            // Start soon rather than wait for a big buffer; the player keeps loading as it plays.
            newItem.preferredForwardBufferDuration = 0
        } else {
            newItem = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        }
        newItem.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
        install(newItem)
        if streaming { watchForStall() }
        // The playhead stays where it is going to be, from the start of the load: it must not flash back to 0 (the timecode
        // would flicker and an edit made at that moment would use the wrong time), and a seek that arrives meanwhile wins.
        currentTime = start ?? .zero
        let seeksBefore = seekCount
        if streaming {
            // Nothing here waits for the network (a server that stops answering would hold the window back for ever): the length
            // comes from the item once it is ready, the audio and subtitle choices when the asset has them.
            Task { [weak self] in await self?.loadSelectionGroups(newItem.asset) }
            return
        }
        if let d = try? await newItem.asset.load(.duration), d.isNumeric { duration = MediaTime(d) }
        // Put the playhead back where it was, unless a newer seek happened while this was loading (that one wins).
        if let s = start, s > .zero, seekCount == seeksBefore { await performSeek(to: s) }
        await loadSelectionGroups(newItem.asset)
    }

    private func watchForStall() {
        stallTimer?.invalidate()
        lastProgress = Date(); lastMark = (.zero, .zero)
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkStall() } }
    }

    private func checkStall() {
        guard item != nil, failure == nil else { return }
        let mark = (currentTime, bufferedUntil)
        if mark.0 != lastMark.0 || mark.1 != lastMark.1 { lastMark = mark; lastProgress = Date(); return }
        // Paused and ready is not stuck; connecting, or playing but waiting for data, is.
        let stuck = !isReady || isWaiting
        if !stuck { lastProgress = Date(); return }
        if Date().timeIntervalSince(lastProgress) > Self.stallTimeout {
            stallTimer?.invalidate(); stallTimer = nil
            pause()
            failure = L("The link stopped sending data. The server may have closed the connection, or the network is too slow.")
        }
    }

    /// Nothing to show (a project whose media is missing).
    func unload() {
        stallTimer?.invalidate(); stallTimer = nil
        pause()
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObservation = nil
        itemObservations = []
        item = nil
        player.replaceCurrentItem(with: nil)
        duration = .zero; currentTime = .zero
    }

    private func install(_ newItem: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        statusObservation = nil
        itemObservations = []
        stallTimer?.invalidate(); stallTimer = nil
        item = newItem
        isReady = false; isLive = false; bufferedUntil = .zero; presentationSize = .zero
        player.replaceCurrentItem(with: newItem)
        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            let status = it.status
            let message = it.error.map(PlayerController.describe)
            let d = it.duration
            Task { @MainActor in
                guard let self, self.item === it else { return }
                switch status {
                case .failed: self.failure = message ?? L("This file cannot be played."); self.isReady = false
                case .readyToPlay:
                    self.isReady = true
                    if d.isIndefinite { self.isLive = true } else if d.isNumeric, self.duration == .zero { self.duration = MediaTime(d) }
                default: break
                }
            }
        }
        itemObservations = [
            newItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] it, _ in
                let ends = it.loadedTimeRanges.map { $0.timeRangeValue }.filter { $0.end.isNumeric }
                let now = it.currentTime()
                // The range the playhead is in, else the furthest one.
                let end = (ends.first { $0.containsTime(now) } ?? ends.max { $0.end < $1.end })?.end
                Task { @MainActor in if let e = end, self?.item === it { self?.bufferedUntil = MediaTime(e) } }
            },
            newItem.observe(\.presentationSize, options: [.new]) { [weak self] it, _ in
                let size = it.presentationSize
                Task { @MainActor in if self?.item === it, size.width > 0 { self?.presentationSize = size } }
            },
        ]
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }
        installBoundary()
    }

    private func loadSelectionGroups(_ asset: AVAsset) async {
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        // Another file may have been opened meanwhile (a link answers late): its choices are not this one's.
        guard item?.asset === asset else { return }
        if let g = audible {
            audioOptions = g.options
            audioSelectionIndex = item?.currentMediaSelection.selectedMediaOption(in: g).flatMap { chosen in g.options.firstIndex(of: chosen) } ?? 0
        } else { audioOptions = []; audioSelectionIndex = 0 }
        legibleOptions = legible?.options ?? []
    }

    func selectAudio(_ option: AVMediaSelectionOption) async {
        guard let item, let g = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        item.select(option, in: g)
        audioSelectionIndex = audioOptions.firstIndex(of: option) ?? audioSelectionIndex
    }

    func selectLegible(_ option: AVMediaSelectionOption?) async {
        guard let item, let g = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if let o = option { item.select(o, in: g) } else { item.select(nil, in: g) }
    }

    /// An error from the network or the player, in words a person can act on.
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let url = (ns.domain == NSURLErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError)
        if let u = url, u.domain == NSURLErrorDomain { return LinkErrors.message(code: u.code) }
        if ns.domain == AVFoundationErrorDomain, ns.code == AVError.Code.fileFormatNotRecognized.rawValue || ns.code == AVError.Code.failedToLoadMediaData.rawValue {
            return L("This link does not give a video this Mac can play (it may be a web page, or a format such as MKV or WebM).")
        }
        return ns.localizedDescription
    }

    // MARK: Transport

    func play() {
        guard item != nil else { return }
        if duration > .zero, currentTime >= duration - MediaTime(value: 1, timescale: 30) { Task { await seek(to: .zero); player.rate = speed } }
        else { player.rate = speed }
        isPlaying = true
    }

    func pause() {
        player.pause(); isPlaying = false; sequence = []
    }

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

    /// Draws the frame on screen again after a live change (a filter, a colour, a transition, a layer or a text being dragged). While playing,
    /// the next frame already does.
    ///
    /// It used to seek to the time the player already stood at; the player skips such a seek, so a filter chosen while paused did not show
    /// until something else moved the playhead (0.12; measured: nothing drawn within 5 s). Handing the item its video composition again
    /// makes it draw the current frame once more, from frames it already has, without seeking or decoding.
    func refreshFrame() {
        guard !isPlaying, let item else { return }
        refreshes += 1
        if let vc = item.videoComposition, let copy = vc.mutableCopy() as? AVMutableVideoComposition {
            item.videoComposition = copy
        } else {
            scrub(to: currentTime)
        }
    }
    /// How many times the frame on screen was drawn again (for the self-test).
    private(set) var refreshes = 0

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
