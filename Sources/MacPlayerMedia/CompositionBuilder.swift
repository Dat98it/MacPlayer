import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import MacPlayerCore

/// One stretch of a source to place on the timeline.
public struct RenderPiece: Sendable {
    public var sourceURL: URL
    public var span: TimeSpan
    public var look: VideoLook
    public var audio: AudioSettings
    /// A preview only: lets the effects of this piece change while it plays (`EffectsLive`).
    public var liveKey: UUID?
    public init(sourceURL: URL, span: TimeSpan, look: VideoLook = VideoLook(), audio: AudioSettings = AudioSettings(), liveKey: UUID? = nil) {
        self.sourceURL = sourceURL; self.span = span; self.look = look; self.audio = audio; self.liveKey = liveKey
    }
}

public struct BuiltRender {
    public var composition: AVMutableComposition
    /// nil when no picture processing is needed (plain decode path, fastest and exact).
    public var videoComposition: AVVideoComposition?
    public var audioMix: AVAudioMix?
    public var duration: CMTime
    public var renderSize: CGSize
    /// Set (for an export on the fixed grid) when every piece is HDR with the same transfer: the output is then HDR too. Nil means SDR.
    public var hdr: HDRFormat?
}

/// Turns pieces + a recipe into the objects AVFoundation plays and exports. The preview and the export both call
/// this, which is what keeps them showing the same thing.
public enum CompositionBuilder {
    public enum BuildError: Error, CustomStringConvertible {
        case noPieces
        case noVideoTrack(String)
        public var description: String {
            switch self {
            case .noPieces: return "Nothing to render."
            case .noVideoTrack(let n): return "\(n) has no video track."
            }
        }
    }

    /// - Parameters:
    ///   - frameAccurate: shift each piece's boundaries by half a frame so exactly the named frames are kept (export).
    ///     The preview of a whole source passes false.
    public static func build(pieces: [RenderPiece], overlays: [TextOverlay] = [], cues: [SubtitleCue] = [], subtitleStyle: SubtitleStyle = SubtitleStyle(),
                             maxHeight: Int? = nil, includeAudio: Bool = true, replacementAudio: URL? = nil, layers: [LayerSpec] = [], soundClips: [SoundClip] = [], frameAccurate: Bool = true, fixedGrid: Bool = false) async throws -> BuiltRender {
        guard !pieces.isEmpty else { throw BuildError.noPieces }
        let comp = AVMutableComposition()
        var assets: [URL: AVURLAsset] = [:]
        func asset(_ u: URL) -> AVURLAsset {
            if let a = assets[u] { return a }
            let a = AVURLAsset(url: u, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]); assets[u] = a; return a
        }

        guard let vComp = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BuildError.noPieces }
        var aComp = includeAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        // More audio tracks of a source that has several, played together (see below). Created on demand.
        var extraAudio: [AVMutableCompositionTrack] = []

        // Picture processing runs through the compositor, which samples on a fixed frame grid (see `CutPlanning.centerSampled`).
        // Several pieces joined in an exact export always go through the compositor too (`fixedGrid`): on the fixed grid every piece is a whole number
        // of output frames, so the file is as long as the preview. A straight copy of each piece (`guarded`) keeps its first and last frame for only
        // half a frame, so each piece comes out one frame short and a join drifts from the timeline by a frame per piece.
        let joinOnGrid = frameAccurate && fixedGrid && pieces.count > 1
        let usesCompositor = !(overlays.isEmpty && cues.isEmpty) || !layers.isEmpty || pieces.contains { $0.look.changesPicture } || joinOnGrid
        var insertedAudio = false
        var pieceHDR: [HDRFormat?] = []
        var plans: [(range: CMTimeRange, plan: PiecePlan, audio: AudioSettings, track: CMPersistentTrackID)] = []
        var cursor = CMTime.zero
        var firstDisplay: PixelSize?
        var firstFPS = 30.0
        /// A photo clip (one picture a second) is among the pieces: the picture then always goes through the compositor, at a steady pace.
        var hasStill = false
        var firstTransform: CGAffineTransform = .identity

        // First pass: what each piece needs (the part of the source to use, its size and speed).
        struct Prep {
            var piece: RenderPiece; var asset: AVURLAsset; var vSrc: AVAssetTrack; var transform: CGAffineTransform; var natural: CGSize
            var sourceDuration: MediaTime; var span: TimeSpan; var gridLength: CMTime?; var range: CMTimeRange
            var speed: Double { piece.look.speed > 0 ? piece.look.speed : 1 }
        }
        var preps: [Prep] = []
        for (n, piece) in pieces.enumerated() {
            let a = asset(piece.sourceURL)
            guard let vSrc = try await a.loadTracks(withMediaType: .video).first else { throw BuildError.noVideoTrack(piece.sourceURL.lastPathComponent) }
            let transform = try await vSrc.load(.preferredTransform)
            let natural = try await vSrc.load(.naturalSize)
            let fps = Double(try await vSrc.load(.nominalFrameRate))
            let duration = MediaTime(try await a.load(.duration))
            var span = piece.span
            var gridLength: CMTime?
            if frameAccurate {
                let rate = FrameRate(approximately: fps >= 10 ? fps : 30)
                if usesCompositor {
                    let c = CutPlanning.centerSampled(span, frameRate: rate, duration: duration)
                    span = c.source; gridLength = c.length.cmTime
                } else {
                    span = CutPlanning.guarded(span, frameRate: rate, duration: duration)
                }
            }
            span = TimeSpan(start: max(.zero, span.start), end: min(duration, span.end))
            guard !span.isEmpty else { continue }
            if n == 0 || firstDisplay == nil {
                let r = natural.applying(transform)
                firstDisplay = PixelSize(width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()))
                firstFPS = fps >= 10 ? fps : 30      // a photo clip (one picture a second) must not set the pace of the whole video
                firstTransform = transform
            }
            if fps > 0, fps < 10 { hasStill = true }
            pieceHDR.append(await HDRFormat.of(vSrc))
            preps.append(Prep(piece: piece, asset: a, vSrc: vSrc, transform: transform, natural: natural, sourceDuration: duration, span: span, gridLength: gridLength,
                              range: CMTimeRange(start: span.start.cmTime, duration: span.duration.cmTime)))
        }

        // Transitions overlap two pictures around a cut, so each needs a little footage from both sides of it: the outgoing clip goes on
        // a little past its end, the incoming one starts a little before its beginning. `halves[i]` is half of the transition into piece i
        // (in timeline seconds), cut down to the footage the two clips have to spare and to what fits in them.
        var halves = [Double](repeating: 0, count: preps.count)
        for i in 1..<max(1, preps.count) {
            guard let t = preps[i].piece.look.transitionIn else { continue }
            let prev = preps[i - 1], cur = preps[i]
            func length(_ p: Prep) -> Double { (p.gridLength ?? p.range.duration).seconds / p.speed }
            let spareAfter = (prev.sourceDuration - prev.span.end).seconds / prev.speed, spareBefore = cur.span.start.seconds / cur.speed
            let h = min(t.clampedDuration / 2, spareAfter, spareBefore, 0.45 * length(prev), 0.45 * length(cur))
            halves[i] = h >= 0.08 ? h : 0
        }
        let twoTracks = halves.contains { $0 > 0 }
        let vComp2: AVMutableCompositionTrack? = twoTracks ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var windows: [(start: CMTime, end: CMTime, from: Int, to: Int, kind: TransitionKind)] = []

        // Second pass: put every piece on the timeline.
        for (k, prep) in preps.enumerated() {
            let piece = prep.piece, a = prep.asset, range = prep.range, vSrc = prep.vSrc, transform = prep.transform, natural = prep.natural
            let pre = halves[k], post = k + 1 < preps.count ? halves[k + 1] : 0
            let track = (twoTracks && k % 2 == 1) ? (vComp2 ?? vComp) : vComp
            let speed = prep.speed
            // The picture, with the footage a transition needs at either end.
            let extStart = CMTimeSubtract(range.start, CMTime(seconds: pre * speed, preferredTimescale: 600))
            let extEnd = CMTimeAdd(CMTimeRangeGetEnd(range), CMTime(seconds: post * speed, preferredTimescale: 600))
            let extended = CMTimeRange(start: extStart, end: extEnd)
            let placeAt = CMTimeSubtract(cursor, CMTime(seconds: pre, preferredTimescale: 600))
            try track.insertTimeRange(extended, of: vSrc, at: placeAt)

            var touched: [AVMutableCompositionTrack] = []
            if let aComp {
                // Alternative tracks (languages) play the default one; tracks that are not alternatives (system sound plus
                // microphone) play together, as the player does. The export does the same.
                // The tracks the player would play are the enabled ones: the default of an alternative group, or every ordinary track.
                // With noise reduction on, the sound comes from the cleaned copy (an export makes it first when there is none yet; a preview waits for it).
                var audioAsset = a
                var audioURL = piece.sourceURL, audioChanged = false
                if let strength = piece.audio.denoise, strength > 0, let u = await Self.cleanedSound(audioURL, strength: strength, make: frameAccurate) { audioURL = u; audioChanged = true }
                if let fx = piece.audio.fx, !fx.isNeutral, let u = await Self.changedSound(audioURL, fx: fx, make: frameAccurate) { audioURL = u; audioChanged = true }
                if audioChanged { audioAsset = asset(audioURL) }
                let allAudio = try await audioAsset.loadTracks(withMediaType: .audio)
                var audioSources: [AVAssetTrack] = []
                for t in allAudio where (try? await t.load(.isEnabled)) ?? true { audioSources.append(t) }
                if audioSources.isEmpty { audioSources = Array(allAudio.prefix(1)) }
                let sourceDuration = try await audioAsset.load(.duration)
                for (j, aSrc) in audioSources.enumerated() {
                    var target = aComp
                    if j > 0 {
                        if extraAudio.count < j, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { extraAudio.append(t) }
                        guard extraAudio.count >= j else { continue }
                        target = extraAudio[j - 1]
                    }
                    insertedAudio = true
                    touched.append(target)
                    // Audio offset (sync), counted in the seconds of the finished picture: positive delays the sound against the picture,
                    // negative brings it forward. A delay is made after the clip's speed has been applied (below); bringing the sound
                    // forward takes it from further into the source, `speed` source seconds for every second of the picture.
                    let off = piece.audio.offsetSeconds
                    if off >= 0 {
                        try target.insertTimeRange(range, of: aSrc, at: cursor)
                    } else {
                        let sourceShift = -off * (piece.look.speed > 0 ? piece.look.speed : 1)
                        let shifted = CMTimeRange(start: CMTimeAdd(range.start, CMTime(seconds: sourceShift, preferredTimescale: 600)), duration: range.duration)
                        let avail = CMTimeRange(start: .zero, duration: sourceDuration)
                        try target.insertTimeRange(CMTimeRangeGetIntersection(shifted, otherRange: avail), of: aSrc, at: cursor)
                    }
                }
            }
            var length = prep.gridLength ?? range.duration
            if piece.look.speed != 1, piece.look.speed > 0 {
                // Each track is scaled on its own: the other picture track holds the neighbouring clip's overlap in the same stretch of time.
                track.scaleTimeRange(CMTimeRange(start: placeAt, duration: extended.duration), toDuration: CMTimeMultiplyByFloat64(extended.duration, multiplier: 1 / piece.look.speed))
                for t in touched { t.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / piece.look.speed)) }
                length = CMTimeMultiplyByFloat64(length, multiplier: 1 / piece.look.speed)
            }
            if piece.audio.offsetSeconds > 0, !touched.isEmpty {
                // Delay the sound: make room at the front of this clip's sound and cut the same amount off its end, so it still ends with
                // the clip and never runs on into the next one (which would push that one's sound later).
                let soundLength = piece.look.speed != 1 && piece.look.speed > 0 ? CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / piece.look.speed) : range.duration
                let delay = CMTimeMinimum(CMTime(seconds: piece.audio.offsetSeconds, preferredTimescale: 600), soundLength)
                for t in touched {
                    t.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: delay))
                    t.removeTimeRange(CMTimeRange(start: CMTimeAdd(cursor, soundLength), duration: delay))
                }
            }
            let timeRange = CMTimeRange(start: cursor, duration: length)
            var plan = PiecePlan(look: piece.look, trackOrientation: RecipeCompositor.orientation(of: transform),
                                 storedSize: PixelSize(width: Int(natural.width), height: Int(natural.height)), rangeStart: cursor.seconds)
            plan.sourceStart = prep.span.start.seconds; plan.speed = prep.speed
            if !frameAccurate { plan.liveKey = piece.liveKey; plan.subjectMode = .previewVideo }
            if piece.look.stabilize > 0 {
                // The analysis is kept after the first time. A preview uses it if there is one; an export makes it first if it has to.
                var path = Stabilizer.cachedPath(for: piece.sourceURL)
                if path == nil, frameAccurate { path = try? await Stabilizer.analyze(piece.sourceURL) }
                plan.stabilizer = path.map { Stabilizer.plan(for: $0, strength: piece.look.stabilize) }
            }
            plans.append((timeRange, plan, piece.audio, track.trackID))
            if pre > 0, let t = piece.look.transitionIn {
                let half = CMTime(seconds: pre, preferredTimescale: 600)
                windows.append((CMTimeSubtract(cursor, half), CMTimeAdd(cursor, half), k - 1, k, t.kind))
            }
            cursor = CMTimeAdd(cursor, length)
        }
        guard !plans.isEmpty else { throw BuildError.noPieces }

        // A source without sound leaves an empty audio track, which a stream-copy export cannot write: drop it.
        if let t = aComp, !insertedAudio, replacementAudio == nil { comp.removeTrack(t); aComp = nil }

        // Replace the soundtrack with an external file for the whole output.
        if let rep = replacementAudio, let aComp {
            aComp.removeTimeRange(CMTimeRange(start: .zero, duration: comp.duration))
            for t in extraAudio { comp.removeTrack(t) }   // the replacement is the whole soundtrack
            extraAudio = []
            let ra = AVURLAsset(url: rep)
            if let src = try await ra.loadTracks(withMediaType: .audio).first {
                let len = CMTimeMinimum(try await ra.load(.duration), cursor)
                try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: src, at: .zero)
            }
        }

        // Layers: each video layer gets its own composition tracks (picture and, unless muted, sound) at its place on the timeline.
        var layerDraws: [(draw: LayerDraw, range: CMTimeRange)] = []
        var layerAudio: [AVMutableAudioMixInputParameters] = []
        let total = MediaTime(cursor)
        for spec in layers.sorted(by: { ($0.lane, $0.start) < ($1.lane, $1.start) }) {
            let start = max(MediaTime.zero, spec.start)
            let duration = min(spec.duration, total - start)
            guard duration.seconds > 0.02 else { continue }
            let range = CMTimeRange(start: start.cmTime, duration: duration.cmTime)
            let border = Self.ciColor(hex: spec.transform.borderHex)
            switch spec.kind {
            case .image(let path):
                guard let ci = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { continue }
                layerDraws.append((LayerDraw(spec: spec, live: !frameAccurate, trackID: nil, orientation: .up, image: ci, border: border), range))
            case .video(let path, let ss, let se):
                let a = asset(URL(fileURLWithPath: path))
                guard let vSrc = try await a.loadTracks(withMediaType: .video).first,
                      let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let sourceDuration = MediaTime(try await a.load(.duration))
                let fps = Double(try await vSrc.load(.nominalFrameRate))
                // Like the main picture: aim at the middle of each source frame when exporting.
                var srcStart = ss
                if frameAccurate { let r = FrameRate(approximately: fps > 0 ? fps : 30); srcStart = srcStart + MediaTime(value: Int64(r.denominator), timescale: r.numerator * 2) }
                let avail = min(se, sourceDuration) - srcStart
                let insert = min(duration, avail)
                guard insert.seconds > 0.01 else { comp.removeTrack(vTrack); continue }
                let srcRange = CMTimeRange(start: srcStart.cmTime, duration: insert.cmTime)
                try vTrack.insertTimeRange(srcRange, of: vSrc, at: start.cmTime)
                if includeAudio, !spec.audio.muted, let aSrc = try await a.loadTracks(withMediaType: .audio).first,
                   let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try aTrack.insertTimeRange(srcRange, of: aSrc, at: start.cmTime)
                    let g = Float(pow(10, spec.audio.gainDB / 20))
                    if g != 1 || spec.fadeIn > 0 || spec.fadeOut > 0 {
                        let p = AVMutableAudioMixInputParameters(track: aTrack)
                        p.setVolume(g, at: range.start)
                        if spec.fadeIn > 0 { p.setVolumeRamp(fromStartVolume: 0, toEndVolume: g, timeRange: CMTimeRange(start: range.start, duration: CMTime(seconds: min(spec.fadeIn, duration.seconds / 2), preferredTimescale: 600))) }
                        if spec.fadeOut > 0 {
                            let d = CMTime(seconds: min(spec.fadeOut, duration.seconds / 2), preferredTimescale: 600)
                            p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(CMTimeRangeGetEnd(range), d), duration: d))
                        }
                        layerAudio.append(p)
                    }
                }
                let t = try await vSrc.load(.preferredTransform)
                layerDraws.append((LayerDraw(spec: spec, live: !frameAccurate, trackID: vTrack.trackID, orientation: RecipeCompositor.orientation(of: t), image: nil, border: border), range))
            }
        }

        // Sound clips: music, voice-overs and effects, each on its own track at its place on the timeline.
        var soundParams: [AVMutableAudioMixInputParameters] = []
        if includeAudio, !soundClips.isEmpty {
            var speech: [(start: Double, end: Double)]?
            for clip in soundClips.enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }).map(\.element) where !clip.muted {
                let start = max(MediaTime.zero, clip.start)
                guard start < total, FileManager.default.fileExists(atPath: clip.path) else { continue }     // a sound whose file is gone is left out (the app asks for it to be found again)
                var url = URL(fileURLWithPath: clip.path)
                if let strength = clip.denoise, strength > 0, let u = await Self.cleanedSound(url, strength: strength, make: frameAccurate) { url = u }
                if let fx = clip.fx, !fx.isNeutral, let u = await Self.changedSound(url, fx: fx, make: frameAccurate) { url = u }
                let a = asset(url)
                guard let src = try await a.loadTracks(withMediaType: .audio).first,
                      let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let fileDuration = MediaTime(try await a.load(.duration))
                let length = min(clip.duration, fileDuration - clip.sourceStart, total - start)
                guard length.seconds > 0.02 else { comp.removeTrack(track); continue }
                try track.insertTimeRange(CMTimeRange(start: clip.sourceStart.cmTime, duration: length.cmTime), of: src, at: start.cmTime)
                var duckSpeech: [(start: Double, end: Double)] = []
                var depth = 1.0
                if clip.ducking, clip.kind != .voice {
                    if speech == nil { speech = try await Self.speechOnTimeline(comp: comp, mainTracks: ([aComp] + extraAudio).compactMap { $0 }, plans: plans.map { ($0.range, $0.audio) },
                                                                              voices: soundClips.filter { $0.kind == .voice && !$0.muted }, total: total) }
                    duckSpeech = speech ?? []
                    depth = pow(10, min(0, clip.duckDepthDB) / 20)
                }
                let points = VolumeEnvelope.points(start: start.seconds, end: (start + length).seconds, gain: pow(10, clip.gainDB / 20),
                                                   fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, speech: duckSpeech, duckGain: depth,
                                                   curve: (clip.volumeCurve ?? []).map { (time: start.seconds + $0.time, gain: pow(10, $0.gainDB / 20)) })
                let params = AVMutableAudioMixInputParameters(track: track)
                Self.apply(points, to: params)
                soundParams.append(params)
            }
        }

        // Picture processing only when something asks for it.
        let layer = OverlayLayer(overlays: overlays, cues: cues, style: subtitleStyle, live: !frameAccurate)
        let needsCompositor = !layer.isEmpty || !layerDraws.isEmpty || plans.contains { $0.plan.look.changesPicture } || joinOnGrid || hasStill
        let display = firstDisplay ?? PixelSize(width: 1920, height: 1080)
        let lookForSize = plans[0].plan.look
        // An export limits the shorter side (a tall video at 1080p is 1080 × 1920); the preview limits the height, to stay light.
        let outSize = RenderGeometry.outputSize(source: display, look: lookForSize, maxHeight: maxHeight, limitsShortSide: frameAccurate)
        var renderSize = CGSize(width: outSize.width, height: outSize.height)

        // An all-HDR export stays HDR through the compositor: it works on 10-bit pictures. Any SDR piece among them makes the whole output SDR
        // (the system tone-maps the HDR ones when it hands them over as ordinary 8-bit pictures).
        let outputHDR: HDRFormat? = (pieceHDR.first ?? nil).flatMap { first in pieceHDR.allSatisfy { $0?.transfer == first.transfer } ? first : nil }
        var videoComposition: AVVideoComposition?
        if needsCompositor {
            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = FrameRate(approximately: firstFPS).frameDuration.cmTime      // exact for 29.97 and 59.94: 1/firstFPS in 6000ths would land on 30 and 60
            vc.customVideoCompositorClass = outputHDR != nil && frameAccurate ? RecipeCompositor10.self : RecipeCompositor.self
            if let h = outputHDR, frameAccurate {
                // Without this the system hands the compositor its pictures as BT.709 SDR whatever the source is.
                vc.colorPrimaries = h.primaries; vc.colorTransferFunction = h.transfer; vc.colorYCbCrMatrix = h.matrix
            }
            // One instruction per stretch in which the same main clip and the same layers are on screen.
            var cuts: [CMTime] = [.zero, cursor]
            for p in plans { cuts += [p.range.start, CMTimeRangeGetEnd(p.range)] }
            for l in layerDraws { cuts += [l.range.start, CMTimeRangeGetEnd(l.range)] }
            for w in windows { cuts += [w.start, w.end] }
            cuts = cuts.filter { CMTimeCompare($0, .zero) >= 0 && CMTimeCompare($0, cursor) <= 0 }.sorted { CMTimeCompare($0, $1) < 0 }
            var unique: [CMTime] = []
            for c in cuts where unique.last.map({ CMTimeCompare($0, c) != 0 }) ?? true { unique.append(c) }
            var instructions: [RecipeInstruction] = []
            for (a, b) in zip(unique, unique.dropFirst()) {
                let active = layerDraws.filter { CMTimeCompare($0.range.start, b) < 0 && CMTimeCompare(CMTimeRangeGetEnd($0.range), a) > 0 }.map(\.draw)
                if let w = windows.first(where: { CMTimeCompare($0.start, a) <= 0 && CMTimeCompare(b, $0.end) <= 0 }) {
                    // Two pictures at once: the outgoing clip and the incoming one, blended by how far through the transition this stretch is.
                    instructions.append(RecipeInstruction(timeRange: CMTimeRange(start: a, end: b), trackID: plans[w.from].track, plan: plans[w.from].plan, layer: layer, layers: active,
                                                          second: TransitionDraw(trackID: plans[w.to].track, plan: plans[w.to].plan, kind: w.kind, start: w.start.seconds, end: w.end.seconds)))
                    continue
                }
                guard let plan = plans.first(where: { CMTimeCompare($0.range.start, a) <= 0 && CMTimeCompare(a, CMTimeRangeGetEnd($0.range)) < 0 }) ?? plans.last else { continue }
                instructions.append(RecipeInstruction(timeRange: CMTimeRange(start: a, end: b), trackID: plan.track, plan: plan.plan, layer: layer, layers: active))
            }
            vc.instructions = instructions
            videoComposition = vc
        } else {
            // Plain decode: keep the stored size and let the track's rotation metadata ride along.
            let natural = (try? await vComp.load(.naturalSize)) ?? .zero
            renderSize = natural == .zero ? renderSize : natural
            vComp.preferredTransform = firstTransform
        }

        // Audio gain, mute and fades.
        var mix: AVAudioMix?
        var mixParams: [AVMutableAudioMixInputParameters] = layerAudio + soundParams
        if let aComp, plans.contains(where: { !$0.audio.isNeutral && $0.audio.replacementPath == nil || $0.audio.muted }) {
            for track in [aComp] + extraAudio {   // every audio track of the main picture gets the same gain, mute and fades
                let params = AVMutableAudioMixInputParameters(track: track)
                for p in plans {
                    let g = p.audio
                    let v = g.muted ? 0 : Float(pow(10, g.gainDB / 20))
                    params.setVolume(v, at: p.range.start)
                    if !g.muted {
                        if g.fadeIn > 0 {
                            let d = CMTime(seconds: min(g.fadeIn, p.range.duration.seconds / 2), preferredTimescale: 600)
                            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: p.range.start, duration: d))
                        }
                        if g.fadeOut > 0 {
                            let d = CMTime(seconds: min(g.fadeOut, p.range.duration.seconds / 2), preferredTimescale: 600)
                            params.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(CMTimeRangeGetEnd(p.range), d), duration: d))
                        }
                    }
                }
                mixParams.append(params)
            }
        }
        if !mixParams.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = mixParams
            mix = m
        }
        _ = total
        return BuiltRender(composition: comp, videoComposition: videoComposition, audioMix: mix, duration: cursor, renderSize: renderSize, hdr: outputHDR)
    }

    /// The noise-reduced copy of a file's sound: the one made before, or (when `make`) one made now. Nil when there is none and none is to be made.
    static func cleanedSound(_ url: URL, strength: Double, make: Bool) async -> URL? {
        if let hit = NoiseReducer.cached(for: url, strength: strength) { return hit }
        return make ? try? await NoiseReducer.clean(url, strength: strength) : nil
    }

    /// The copy of a file's sound with bass, treble, pitch, room and echo: the one made before, or (when `make`) one made now.
    static func changedSound(_ url: URL, fx: SoundFX, make: Bool) async -> URL? {
        if let hit = SoundFXRenderer.cached(for: url, fx: fx.clamped()) { return hit }
        return make ? try? await SoundFXRenderer.process(url, fx: fx) : nil
    }

    /// When someone speaks in the output, on the timeline: in the video's own sound (where it is not muted) and in the voice-overs.
    static func speechOnTimeline(comp: AVMutableComposition, mainTracks: [AVMutableCompositionTrack], plans: [(range: CMTimeRange, audio: AudioSettings)],
                                 voices: [SoundClip], total: MediaTime) async throws -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        if !mainTracks.isEmpty, !plans.allSatisfy({ $0.audio.muted }) {
            let found = (try? await AudioAnalysis.speech(asset: comp, tracks: mainTracks)) ?? []
            for r in found {
                for p in plans where !p.audio.muted {
                    let a = max(r.start, p.range.start.seconds), b = min(r.end, CMTimeRangeGetEnd(p.range).seconds)
                    if b > a { out.append((a, b)) }
                }
            }
        }
        for v in voices {
            let a = AVURLAsset(url: URL(fileURLWithPath: v.path))
            let length = min(v.duration, total - v.start)
            guard length.seconds > 0.1 else { continue }
            let found = (try? await AudioAnalysis.speech(asset: a, range: CMTimeRange(start: v.sourceStart.cmTime, duration: length.cmTime))) ?? []
            out += found.map { (v.start.seconds + $0.start, v.start.seconds + $0.end) }
        }
        return out
    }

    /// Sets a track's volume to follow the breakpoints, moving in straight lines between them.
    static func apply(_ points: [VolumeEnvelope.Point], to params: AVMutableAudioMixInputParameters) {
        guard let first = points.first else { return }
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 6000) }
        params.setVolume(Float(first.gain), at: t(first.time))
        for (a, b) in zip(points, points.dropFirst()) {
            if abs(a.gain - b.gain) < 1e-4 { params.setVolume(Float(b.gain), at: t(b.time)); continue }
            params.setVolumeRamp(fromStartVolume: Float(a.gain), toEndVolume: Float(b.gain), timeRange: CMTimeRange(start: t(a.time), end: t(b.time)))
        }
    }

    static func ciColor(hex: String) -> CIColor {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        guard h.count == 6 else { return CIColor(red: 1, green: 1, blue: 1) }
        return CIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255)
    }
}
