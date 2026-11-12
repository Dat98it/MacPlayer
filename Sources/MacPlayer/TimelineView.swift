import AppKit
import Combine
import MacPlayerCore

/// The timeline under the picture. In a video project it has one line ("track") per kind of thing, from top to bottom: the ruler, the main
/// video (with small pictures of each clip), text and stickers, three layer lines (videos and pictures over the main video), and sounds.
/// Everything can be clicked to select it (its settings show on the right), dragged to move it, and dragged by its edges to trim it.
/// Files from the library or Finder, filters, transitions and text styles can be dropped on it. When only watching, it is the waveform and
/// the playhead.
@MainActor
final class TimelineView: NSView {
    private weak var session: EditorSession?
    private var bag = Set<AnyCancellable>()

    private var viewport = TimelineViewport()
    private var visibleStart: Double { viewport.start }
    private var visibleLength: Double { viewport.length }
    private var followPlayhead = true
    /// Told when the zoom changes (the toolbar's slider follows it).
    var onZoomChange: ((Double) -> Void)?

    private enum Drag {
        case none, playhead, edge(UUID, left: Bool), moveClip(UUID, startX: CGFloat)
        case overlayMove(UUID, grab: Double), overlayEdge(UUID, left: Bool)
        case textMove(UUID, grab: Double), textEdge(UUID, left: Bool), soundMove(UUID, grab: Double), soundEdge(UUID, left: Bool)
    }
    private var moveTarget: Int?
    private var movedFar = false
    private var drag = Drag.none

    /// Where something being dragged in from outside would land, drawn while it hovers.
    enum DropTarget: Equatable {
        case insert(Int), lane(Int, Double), audio(Double), text(Double), clip(UUID), cut(UUID)
    }
    private(set) var dropTarget: DropTarget?

    // Geometry (the view is flipped: y grows downwards).
    private let rulerHeight: CGFloat = 22
    private let mainHeight: CGFloat = 64
    private let textHeight: CGFloat = 26
    private let laneHeight: CGFloat = 26
    private let audioHeight: CGFloat = 30
    private var laneCount: Int { OverlayClip.laneCount }
    private var isProject: Bool { session?.isProject ?? false }
    /// The height a video project's timeline needs to show every track.
    static let projectHeight: CGFloat = 22 + 2 + 64 + 2 + 26 + 3 * 26 + 30 + 4
    private var mainRect: CGRect { CGRect(x: 0, y: rulerHeight + 2, width: bounds.width, height: isProject ? mainHeight : max(10, bounds.height - rulerHeight - 4)) }
    private var textTop: CGFloat { mainRect.maxY + 2 }
    private var lanesTop: CGFloat { textTop + textHeight }
    private var audioTop: CGFloat { lanesTop + CGFloat(laneCount) * laneHeight }

    private enum Track: Equatable { case ruler, main, text, lane(Int), audio, none }
    private func track(at y: CGFloat) -> Track {
        if y < rulerHeight { return .ruler }
        guard isProject else { return .main }
        if y < mainRect.maxY + 1 { return .main }
        if y < lanesTop { return .text }
        if y < audioTop { return .lane(max(0, min(laneCount - 1, Int((y - lanesTop) / laneHeight)))) }
        if y < audioTop + audioHeight { return .audio }
        return .none
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.slider)
        setAccessibilityLabel(L("Timeline"))
        session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            // The project's length changes when videos are added or clips trimmed: the strip follows (it used to keep the
            // width an empty project had, and then scrolled on every frame).
            self.viewport.totalChanged(to: self.total)
            self.needsDisplay = true; self.followIfNeeded()
        }.store(in: &bag)
        // The playhead moves at every frame; the session tells the panels only a few times a second while playing.
        session.player.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            // Only the playhead moves; the strip is drawn again only when the view jumps to follow it (0.12: redrawing the whole strip
            // — pictures, waveforms — at every frame was most of the main thread's work while playing).
            let before = self.viewport
            self.followIfNeeded()
            if self.viewport != before { self.needsDisplay = true }
            self.movePlayhead()
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .filmstripReady).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        if session.isProject { registerForDraggedTypes([.fileURL, .string]) }
        addSubview(playheadView)
        fitAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var total: Double { max(0, session?.duration.seconds ?? 0) }

    /// The red playhead: a line and a head, a small view of its own (it moves; the strip under it is not drawn again).
    private let playheadView = PlayheadView()

    private func movePlayhead() {
        guard let s = session else { return }
        let px = x(s.player.currentTime.seconds)
        let f = CGRect(x: (px - 6).rounded(), y: 0, width: 12, height: bounds.height)
        if playheadView.frame != f { playheadView.frame = f }
        playheadView.isHidden = px < -6 || px > bounds.width + 6
    }

    /// Where the playhead is drawn (for the self-test).
    var playheadX: CGFloat { playheadView.frame.midX }
    /// How many times the strip was drawn (for the self-test).
    private(set) var draws = 0

    func fitAll() { viewport.fitAll(total: total); needsDisplay = true; onZoomChange?(zoomFraction) }

    /// What the strip shows now, in seconds (for the self-test).
    var visibleSpan: (start: Double, length: Double) { (viewport.start, viewport.length) }

    private func x(_ t: Double) -> CGFloat { CGFloat((t - visibleStart) / visibleLength) * bounds.width }
    private func time(_ x: CGFloat) -> Double { visibleStart + Double(x / max(1, bounds.width)) * visibleLength }
    private func clampTime(_ t: Double) -> Double { min(max(0, t), total) }

    private func followIfNeeded() {
        guard followPlayhead, let s = session, s.player.isPlaying else { return }
        viewport.follow(playhead: s.player.currentTime.seconds)
    }

    // MARK: Zoom

    /// 0 = the whole timeline in view, 1 = zoomed in as far as it goes.
    var zoomFraction: Double {
        let t = max(TimelineViewport.minimumLength, total)
        guard t > TimelineViewport.minimumLength * 1.01 else { return 0 }
        return min(1, max(0, log(t / visibleLength) / log(t / TimelineViewport.minimumLength)))
    }

    func setZoom(_ f: Double) {
        let t = max(TimelineViewport.minimumLength, total)
        let target = t * pow(TimelineViewport.minimumLength / t, min(1, max(0, f)))
        let px = x(session?.player.currentTime.seconds ?? 0)
        zoom(by: target / visibleLength, around: (px >= 0 && px <= bounds.width) ? px : bounds.width / 2, notify: false)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        draws += 1
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
        bounds.fill()
        drawRuler()

        if s.isProject {
            drawTrackBackgrounds(ctx, dark: dark)
            drawProjectClips(s, ctx)
            drawTexts(s, ctx)
            drawLanes(s, ctx)
            drawSounds(s, ctx)
            drawDropTarget(s, ctx)
        } else if !s.peaks.isEmpty {
            drawWaveform(s.peaks, in: mainRect, ctx: ctx, color: NSColor.systemTeal.withAlphaComponent(0.55))
        }

        // Markers
        for m in s.project.markers {
            let mx = x(m.time.seconds)
            guard mx >= 0, mx <= bounds.width else { continue }
            let color = Self.markerColor(m.color)
            ctx.setFillColor(color.cgColor)
            ctx.move(to: CGPoint(x: mx, y: rulerHeight)); ctx.addLine(to: CGPoint(x: mx + 7, y: rulerHeight - 6)); ctx.addLine(to: CGPoint(x: mx - 7, y: rulerHeight - 6)); ctx.closePath()
            ctx.fillPath()
            ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: mx, y: rulerHeight, width: 0, height: mainRect.maxY - rulerHeight))
        }

        // The playhead is a view of its own (`playheadView`), moved at every frame without drawing all this again.
        movePlayhead()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.6).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); p.lineWidth = 1.5; p.stroke()
        }
    }

    private func drawWaveform(_ peaks: [Float], in r: CGRect, ctx: CGContext, color: NSColor) {
        let mid = r.midY, half = r.height / 2 - 4
        ctx.setFillColor(color.cgColor)
        let n = peaks.count
        var px = CGFloat(0)
        while px < bounds.width {
            let t0 = time(px), t1 = time(px + 1)
            let span = max(0.001, total)
            let i0 = max(0, min(n - 1, Int(t0 / span * Double(n)))), i1 = max(i0, min(n - 1, Int(t1 / span * Double(n))))
            var peak: Float = 0
            for i in i0...i1 { peak = max(peak, peaks[i]) }
            let h = max(1, CGFloat(peak) * half)
            ctx.fill(CGRect(x: px, y: mid - h, width: 1, height: h * 2))
            px += 1
        }
    }

    private func drawTrackBackgrounds(_ ctx: CGContext, dark: Bool) {
        let shade = NSColor.labelColor
        let rows: [(CGRect, String, Double)] = [
            (CGRect(x: 0, y: textTop, width: bounds.width, height: textHeight), L("Text"), 0.05),
        ] + (0..<laneCount).map { (CGRect(x: 0, y: lanesTop + CGFloat($0) * laneHeight, width: bounds.width, height: laneHeight), LF("Layer %d", $0 + 1), $0 % 2 == 0 ? 0.035 : 0.06) }
          + [(CGRect(x: 0, y: audioTop, width: bounds.width, height: audioHeight), L("Sound"), 0.05)]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]
        for (r, name, a) in rows {
            ctx.setFillColor(shade.withAlphaComponent(a).cgColor); ctx.fill(r)
            (name as NSString).draw(at: CGPoint(x: 6, y: r.minY + (r.height - 12) / 2), withAttributes: attrs)
        }
        ctx.setFillColor(shade.withAlphaComponent(0.04).cgColor); ctx.fill(mainRect)
        if session?.project.timeline.isEmpty == true {
            let msg = L("Drag videos here from the library on the left, or from Finder") as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            let size = msg.size(withAttributes: a)
            let box = CGRect(x: 8, y: mainRect.minY + 4, width: bounds.width - 16, height: mainRect.height - 8)
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
            msg.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: a)
        }
    }

    private func clipRect(start: Double, length: Double) -> CGRect {
        CGRect(x: x(start), y: mainRect.minY, width: x(start + length) - x(start), height: mainRect.height)
    }

    private func drawProjectClips(_ s: EditorSession, _ ctx: CGContext) {
        let missing = s.missingSourceIDs
        var start = 0.0
        for (i, c) in s.project.timeline.enumerated() {
            let len = c.duration.seconds
            defer { start += len }
            let r = clipRect(start: start, length: len).insetBy(dx: 0.5, dy: 0)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let isMissing = missing.contains(c.sourceID)
            let selected = s.selectedClipIDs.contains(c.id)
            let path = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.setFillColor((isMissing ? NSColor.systemRed : NSColor.systemTeal).withAlphaComponent(0.35).cgColor); ctx.fill(r)
            // Small pictures of the clip, side by side.
            if !isMissing, let url = s.sourceURLs[c.sourceID], let dur = s.infos[c.sourceID]?.duration.seconds,
               let strip = FilmstripCache.shared.strip(for: url.path, duration: dur), let first = strip.first?.1 {
                let tileW = max(20, r.height * first.size.width / max(1, first.size.height))
                var tx = r.minX
                let span = (c.sourceEnd - c.sourceStart).seconds
                while tx < r.maxX {
                    if tx + tileW >= 0, tx <= bounds.width {
                        let f = Double((tx + tileW / 2 - r.minX) / max(1, r.width))
                        if let img = FilmstripCache.nearest(strip, c.sourceStart.seconds + f * span) {
                            img.draw(in: CGRect(x: tx, y: r.minY, width: tileW, height: r.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        }
                    }
                    tx += tileW
                }
            }
            // The clip's sound, low along its bottom.
            if let peaks = s.peaksBySource[c.sourceID], !peaks.isEmpty, let dur = s.infos[c.sourceID]?.duration.seconds, dur > 0, !c.audio.muted {
                let band = CGRect(x: r.minX, y: r.maxY - 16, width: r.width, height: 16)
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.fill(band)
                ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.85).cgColor)
                var px = max(r.minX, 0).rounded(.down)
                let span = (c.sourceEnd - c.sourceStart).seconds
                while px < min(r.maxX, bounds.width) {
                    let f0 = (px - r.minX) / max(1, r.width), f1 = (px + 1 - r.minX) / max(1, r.width)
                    let a = max(0, min(peaks.count - 1, Int((c.sourceStart.seconds + f0 * span) / dur * Double(peaks.count))))
                    let b = max(a, min(peaks.count - 1, Int((c.sourceStart.seconds + f1 * span) / dur * Double(peaks.count))))
                    var peak: Float = 0
                    for k in a...b { peak = max(peak, peaks[k]) }
                    let h = max(1, CGFloat(peak) * 7)
                    ctx.fill(CGRect(x: px, y: band.midY - h, width: 1, height: h * 2))
                    px += 1
                }
            }
            // Name and badges on a dark band at the top.
            var label = c.name.isEmpty ? PathUtil.fileName(of: s.project.source(c.sourceID)?.mediaPath ?? "") : c.name
            if c.look.speed != 1 { label = String(format: "%g× ", c.look.speed) + label }
            if c.look.effects.filter != .none { label = "✦ " + label }
            if s.project.source(c.sourceID)?.stillOf != nil { label = "🖼 " + label } else if s.project.source(c.sourceID)?.soundOf != nil { label = "♪ " + label }
            if c.audio.muted { label = "🔇 " + label }
            if isMissing { label = "⚠︎ " + L("Missing") + " · " + label }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
            let tag = "\(i + 1)  \(label)  \(Format.duration(c.duration))" as NSString
            let tagSize = tag.size(withAttributes: attrs)
            let tagRect = CGRect(x: max(r.minX, 0) + 3, y: r.minY + 3, width: min(tagSize.width + 8, max(0, r.width - 6)), height: 15)
            if tagRect.width > 12 {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.addPath(CGPath(roundedRect: tagRect, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
                ctx.saveGState(); ctx.clip(to: tagRect)
                tag.draw(at: CGPoint(x: tagRect.minX + 4, y: tagRect.minY + 1), withAttributes: attrs)
                ctx.restoreGState()
            }
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(selected ? NSColor.white.cgColor : NSColor.black.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(selected ? 2.5 : 1); ctx.strokePath()
            if selected {   // trim handles
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY + 6, width: 5, height: r.height - 12)); ctx.fill(CGRect(x: r.maxX - 5, y: r.minY + 6, width: 5, height: r.height - 12))
            }
            // A transition into this clip: a badge on the cut.
            if i > 0, c.look.transitionIn != nil {
                let b = CGRect(x: r.minX - 9, y: r.midY - 9, width: 18, height: 18)
                ctx.setFillColor(NSColor.systemOrange.cgColor); ctx.fillEllipse(in: b)
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: b.insetBy(dx: 1, dy: 1))
                ("⇄" as NSString).draw(at: CGPoint(x: b.minX + 3.5, y: b.minY + 1.5), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
            }
        }
        if let t = moveTarget {
            let pos = cutTime(t)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.fill(CGRect(x: x(pos) - 1.5, y: mainRect.minY - 2, width: 3, height: mainRect.height + 4))
        }
    }

    /// The text line holds everything on the picture that has a time. Things that overlap in time share it in rows (up to three), so none
    /// hides another; each gets its rectangle here.
    private func textRects(_ s: EditorSession) -> [(o: TextOverlay, r: CGRect)] {
        var rowsEnd: [Double] = []
        var placed: [(TextOverlay, Int)] = []
        for o in s.project.overlays.sorted(by: { $0.start < $1.start }) {
            let row = rowsEnd.firstIndex { $0 <= o.start.seconds + 1e-6 } ?? (rowsEnd.count < 3 ? rowsEnd.count : rowsEnd.indices.min { rowsEnd[$0] < rowsEnd[$1] }!)
            if row == rowsEnd.count { rowsEnd.append(o.end.seconds) } else { rowsEnd[row] = max(rowsEnd[row], o.end.seconds) }
            placed.append((o, row))
        }
        let rows = max(1, rowsEnd.count)
        let h = (textHeight - 4) / CGFloat(rows)
        // Kept in the project's order (the later drawn on top, as on the picture).
        let order = Dictionary(uniqueKeysWithValues: s.project.overlays.enumerated().map { ($1.id, $0) })
        return placed.sorted { order[$0.0.id]! < order[$1.0.id]! }.map { o, row in
            (o, CGRect(x: x(o.start.seconds), y: textTop + 2 + CGFloat(row) * h, width: max(4, x(o.end.seconds) - x(o.start.seconds)), height: h - (rows > 1 ? 1 : 0)))
        }
    }

    private func drawTexts(_ s: EditorSession, _ ctx: CGContext) {
        for (o, r) in textRects(s) {
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let selected = s.selectedTextID == o.id || s.canvasSelection.contains(o.id)
            let base: NSColor = o.shape != nil ? .systemPink : .systemYellow
            let name = o.shape.map { TextPane.shapeName($0.kind) } ?? (o.text.isEmpty ? L("Text") : o.text.replacingOccurrences(of: "\n", with: " "))
            bar(ctx, r, base: base, selected: selected, title: (o.shape != nil ? "◆ " : "T  ") + name + ((o.locked ?? false) ? "  🔒" : ""))
        }
    }

    private func drawLanes(_ s: EditorSession, _ ctx: CGContext) {
        for c in s.project.overlayClips {
            let r = CGRect(x: x(c.start.seconds), y: lanesTop + CGFloat(c.lane) * laneHeight + 2, width: max(4, x(c.end.seconds) - x(c.start.seconds)), height: laneHeight - 4)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let missing = c.sourceID.map { s.missingSourceIDs.contains($0) } ?? false
            let base: NSColor = missing ? .systemRed : (c.isVideo ? .systemPurple : .systemOrange)
            bar(ctx, r, base: base, selected: s.selectedOverlayID == c.id || s.canvasSelection.contains(c.id), title: (c.isVideo ? "▶ " : "▣ ") + c.name + ((c.locked ?? false) ? "  🔒" : ""))
            for k in c.keyframes {   // keyframes as small diamonds
                let kx = x((c.start + k.time).seconds), ky = r.maxY - 4
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.move(to: CGPoint(x: kx, y: ky - 4)); ctx.addLine(to: CGPoint(x: kx + 4, y: ky)); ctx.addLine(to: CGPoint(x: kx, y: ky + 4)); ctx.addLine(to: CGPoint(x: kx - 4, y: ky)); ctx.closePath(); ctx.fillPath()
            }
        }
    }

    private func drawSounds(_ s: EditorSession, _ ctx: CGContext) {
        for c in s.project.soundClips {
            let r = CGRect(x: x(c.start.seconds), y: audioTop + 2, width: max(4, x(c.end.seconds) - x(c.start.seconds)), height: audioHeight - 4)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let base: NSColor = s.isMissing(c) ? .systemRed : (c.kind == .voice ? .systemCyan : .systemGreen)
            let icon = c.kind == .voice ? "🎙 " : (c.kind == .music ? "♪ " : "🔊 ")
            bar(ctx, r, base: base, selected: s.selectedSoundID == c.id, title: icon + c.name + (c.muted ? "  🔇" : ""))
        }
    }

    /// One item on a track: a rounded bar with its name, outlined in white and with trim handles when selected.
    private func bar(_ ctx: CGContext, _ r: CGRect, base: NSColor, selected: Bool, title: String) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(base.withAlphaComponent(selected ? 0.75 : 0.5).cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(selected ? NSColor.white.cgColor : base.cgColor); ctx.setLineWidth(selected ? 2 : 1)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.strokePath()
        if selected {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY + 3, width: 4, height: r.height - 6)); ctx.fill(CGRect(x: r.maxX - 4, y: r.minY + 3, width: 4, height: r.height - 6))
        }
        ctx.saveGState(); ctx.clip(to: r.insetBy(dx: 5, dy: 0))
        (title as NSString).draw(at: CGPoint(x: max(r.minX, 0) + 7, y: r.minY + (r.height - 13) / 2),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor])
        ctx.restoreGState()
    }

    private func drawDropTarget(_ s: EditorSession, _ ctx: CGContext) {
        guard let d = dropTarget else { return }
        let accent = NSColor.controlAccentColor
        func box(_ r: CGRect) {
            ctx.setFillColor(accent.withAlphaComponent(0.25).cgColor); ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(2); ctx.stroke(r.insetBy(dx: 1, dy: 1))
        }
        switch d {
        case .insert(let i):
            let px = x(cutTime(i))
            ctx.setFillColor(accent.cgColor); ctx.fill(CGRect(x: px - 2, y: mainRect.minY - 2, width: 4, height: mainRect.height + 4))
        case .lane(let lane, let t): box(CGRect(x: x(t), y: lanesTop + CGFloat(lane) * laneHeight + 1, width: max(30, x(t + 5) - x(t)), height: laneHeight - 2))
        case .audio(let t): box(CGRect(x: x(t), y: audioTop + 1, width: max(30, x(t + 10) - x(t)), height: audioHeight - 2))
        case .text(let t): box(CGRect(x: x(t), y: textTop + 1, width: max(30, x(t + 3) - x(t)), height: textHeight - 2))
        case .clip(let id):
            if let r = rect(ofClip: id) { box(r) }
        case .cut(let id):
            if let r = rect(ofClip: id) {
                let b = CGRect(x: r.minX - 12, y: r.midY - 12, width: 24, height: 24)
                ctx.setFillColor(accent.cgColor); ctx.fillEllipse(in: b)
            }
        }
    }

    private func rect(ofClip id: UUID) -> CGRect? {
        guard let s = session else { return nil }
        var start = 0.0
        for c in s.project.timeline { if c.id == id { return clipRect(start: start, length: c.duration.seconds) }; start += c.duration.seconds }
        return nil
    }

    /// Where the cut before clip `index` is, in seconds (the end of the timeline for `count`).
    private func cutTime(_ index: Int) -> Double {
        guard let s = session else { return 0 }
        var pos = 0.0
        for (i, c) in s.project.timeline.enumerated() { if i == index { break }; pos += c.duration.seconds }
        return pos
    }

    private func drawRuler() {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let target = visibleLength / Double(max(1, bounds.width / 90))
        let step = steps.first { $0 >= target } ?? 3600
        var t = (visibleStart / step).rounded(.down) * step
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.separatorColor.setFill()
        while t <= visibleStart + visibleLength {
            let px = x(t)
            if px >= 0 { CGRect(x: px, y: rulerHeight - 7, width: 1, height: 7).fill(); (Timecode.format(MediaTime(seconds: t)) as NSString).draw(at: CGPoint(x: px + 3, y: 3), withAttributes: attrs) }
            let half = x(t + step / 2)
            if half >= 0 { CGRect(x: half, y: rulerHeight - 4, width: 1, height: 4).fill() }
            t += step
        }
        CGRect(x: 0, y: rulerHeight - 1, width: bounds.width, height: 1).fill()
    }

    static let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemIndigo]
    static func markerColor(_ c: MarkerColor) -> NSColor {
        switch c { case .red: return .systemRed; case .orange: return .systemOrange; case .yellow: return .systemYellow; case .green: return .systemGreen
        case .blue: return .systemBlue; case .purple: return .systemPurple; case .gray: return .systemGray }
    }

    // MARK: Finding things

    private func projectEdge(at p: CGPoint) -> (UUID, Bool)? {
        guard let s = session, track(at: p.y) == .main else { return nil }
        var start = 0.0
        for c in s.project.timeline {
            let end = start + c.duration.seconds
            // Only the selected clip's edges trim (as its handles show); any edge does when nothing is selected.
            if s.selectedClipIDs.isEmpty || s.selectedClipIDs.contains(c.id) {
                if abs(p.x - x(start)) <= 6 { return (c.id, true) }
                if abs(p.x - x(end)) <= 6 { return (c.id, false) }
            }
            start = end
        }
        return nil
    }

    private func projectClip(at t: Double) -> TimelineClip? {
        guard let s = session else { return nil }
        var start = 0.0
        for c in s.project.timeline { let end = start + c.duration.seconds; if t >= start && t < end { return c }; start = end }
        return nil
    }

    private func dropIndex(at t: Double) -> Int {
        guard let s = session else { return 0 }
        var start = 0.0
        for (i, c) in s.project.timeline.enumerated() { let mid = start + c.duration.seconds / 2; if t < mid { return i }; start += c.duration.seconds }
        return s.project.timeline.count
    }

    /// The clip after the cut nearest to `t` (never the first clip, which has no cut before it).
    private func cutClip(near t: Double) -> UUID? {
        guard let s = session, s.project.timeline.count > 1 else { return nil }
        var best: (UUID, Double)?
        var pos = 0.0
        for (i, c) in s.project.timeline.enumerated() {
            if i > 0, best == nil || abs(pos - t) < best!.1 { best = (c.id, abs(pos - t)) }
            pos += c.duration.seconds
        }
        return best?.0
    }

    private func overlay(at p: CGPoint) -> OverlayClip? {
        guard let s = session, case .lane(let lane) = track(at: p.y) else { return nil }
        let t = time(p.x)
        return s.project.overlayClips.first { $0.lane == lane && x($0.start.seconds) - 3 <= p.x && p.x <= x($0.end.seconds) + 3 && ($0.start.seconds <= t || abs(x($0.start.seconds) - p.x) <= 3) }
    }

    private func overlayEdge(at p: CGPoint) -> (UUID, Bool)? {
        guard let s = session, case .lane(let lane) = track(at: p.y) else { return nil }
        for c in s.project.overlayClips where c.lane == lane {
            if abs(p.x - x(c.start.seconds)) <= 5 { return (c.id, true) }
            if abs(p.x - x(c.end.seconds)) <= 5 { return (c.id, false) }
        }
        return nil
    }

    private func text(at p: CGPoint) -> TextOverlay? {
        guard let s = session, track(at: p.y) == .text else { return nil }
        return textRects(s).last { $0.r.insetBy(dx: -3, dy: 0).contains(p) }?.o
    }

    private func textEdge(at p: CGPoint) -> (UUID, Bool)? {
        guard let s = session, track(at: p.y) == .text else { return nil }
        for (o, r) in textRects(s).reversed() where p.y >= r.minY && p.y <= r.maxY {
            if abs(p.x - r.minX) <= 5 { return (o.id, true) }
            if abs(p.x - r.maxX) <= 5 { return (o.id, false) }
        }
        return nil
    }

    private func soundEdge(at p: CGPoint) -> (UUID, Bool)? {
        guard let s = session, track(at: p.y) == .audio else { return nil }
        for c in s.project.soundClips.reversed() {
            if abs(p.x - x(c.start.seconds)) <= 5 { return (c.id, true) }
            if abs(p.x - x(c.end.seconds)) <= 5 { return (c.id, false) }
        }
        return nil
    }

    private func sound(at p: CGPoint) -> SoundClip? {
        guard let s = session, track(at: p.y) == .audio else { return nil }
        return s.project.soundClips.last { x($0.start.seconds) - 3 <= p.x && p.x <= max(x($0.end.seconds), x($0.start.seconds) + 4) + 3 }
    }

    /// Moving something in time: its start (or end) clings to the playhead, the cuts and the ends of the timeline when close to them.
    private func snapped(start: Double, length: Double) -> Double {
        guard let s = session else { return start }
        var points = [0.0, total, s.player.currentTime.seconds]
        var pos = 0.0
        for c in s.project.timeline { pos += c.duration.seconds; points.append(pos) }
        let reach = Double(8 / max(1, bounds.width)) * visibleLength
        var best: (Double, Double)?
        for p in points {
            for (edge, shift) in [(start, 0.0), (start + length, -length)] {
                let d = abs(edge - p)
                if d < reach, best == nil || d < best!.1 { best = (p + shift, d) }
            }
        }
        return max(0, best?.0 ?? start)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard let s = session else { return }
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        followPlayhead = false
        let tr = track(at: p.y)
        func scrubHere() { drag = .playhead; s.player.scrub(to: MediaTime(seconds: clampTime(time(p.x)), timescale: 600)) }
        guard s.isProject, tr != .ruler else { scrubHere(); return }
        switch tr {
        case .main:
            if let (id, left) = projectEdge(at: p) { drag = .edge(id, left: left); s.select(.clip(id)); return }
            if let c = projectClip(at: time(p.x)) {
                if e.modifierFlags.contains(.command) { s.selectedClipIDs = s.selectedClipIDs.symmetricDifference([c.id]) } else if !s.selectedClipIDs.contains(c.id) || s.selectedClipIDs.count > 1 { s.select(.clip(c.id)) }
                drag = .moveClip(c.id, startX: p.x); movedFar = false
                s.player.scrub(to: MediaTime(seconds: clampTime(time(p.x)), timescale: 600))
                return
            }
        case .text:
            if let (id, left) = textEdge(at: p) { drag = .textEdge(id, left: left); s.select(.text(id)); return }
            if let o = text(at: p) { s.select(.text(o.id)); drag = .textMove(o.id, grab: time(p.x) - o.start.seconds); return }
        case .lane:
            if let (id, left) = overlayEdge(at: p) { drag = .overlayEdge(id, left: left); s.select(.layer(id)); return }
            if let c = overlay(at: p) { s.select(.layer(c.id)); drag = .overlayMove(c.id, grab: time(p.x) - c.start.seconds); return }
        case .audio:
            if let (id, left) = soundEdge(at: p) { drag = .soundEdge(id, left: left); s.select(.sound(id)); return }
            if let c = sound(at: p) { s.select(.sound(c.id)); drag = .soundMove(c.id, grab: time(p.x) - c.start.seconds); return }
        default: break
        }
        // Empty space: nothing selected, the playhead goes there.
        s.select(.none)
        scrubHere()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = session else { return }
        let p = convert(e.locationInWindow, from: nil)
        let t = clampTime(time(p.x))
        func mt(_ v: Double) -> MediaTime { MediaTime(seconds: v, timescale: 600) }
        switch drag {
        case .playhead: s.player.scrub(to: mt(t))
        case .edge(let id, let left): s.trimClip(id, leftEdge: left, toTimelineTime: mt(t))
        case .overlayMove(let id, let grab):
            let lane: Int? = { if case .lane(let l) = track(at: p.y) { return l }; return nil }()
            let len = s.project.overlayClips.first { $0.id == id }?.duration.seconds ?? 0
            s.moveOverlay(id, toStart: mt(snapped(start: max(0, t - grab), length: len)), lane: lane)
        case .overlayEdge(let id, let left): s.trimOverlay(id, leftEdge: left, toTimelineTime: mt(t))
        case .textMove(let id, let grab):
            let len = s.project.overlays.first { $0.id == id }.map { ($0.end - $0.start).seconds } ?? 0
            s.moveText(id, toStart: mt(snapped(start: max(0, t - grab), length: len)))
        case .textEdge(let id, let left): s.trimText(id, leftEdge: left, to: mt(t))
        case .soundMove(let id, let grab):
            let len = s.project.soundClips.first { $0.id == id }?.duration.seconds ?? 0
            s.moveSound(id, toStart: mt(snapped(start: max(0, t - grab), length: len)))
        case .soundEdge(let id, let left): s.trimSound(id, leftEdge: left, to: mt(t))
        case .moveClip(_, let startX):
            if abs(p.x - startX) > 6 { movedFar = true }
            if movedFar { moveTarget = dropIndex(at: t); needsDisplay = true }
        case .none: break
        }
        autoscroll(with: e)
    }

    override func mouseUp(with e: NSEvent) {
        guard let s = session else { return }
        switch drag { case .edge, .overlayMove, .overlayEdge, .textMove, .textEdge, .soundMove, .soundEdge: s.endCoalescing(); default: break }
        if case .moveClip(let id, _) = drag, movedFar, let target = moveTarget { s.moveClip(id, toIndex: target) }
        moveTarget = nil; movedFar = false
        drag = .none; needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { updateCursor(convert(e.locationInWindow, from: nil)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    /// The pointer says what a press would do: ↔ on an edge (trim), a hand on something that can be moved, the arrow elsewhere.
    private func updateCursor(_ p: CGPoint) {
        guard session?.isProject == true else { NSCursor.arrow.set(); return }
        if projectEdge(at: p) != nil || overlayEdge(at: p) != nil || textEdge(at: p) != nil || soundEdge(at: p) != nil { NSCursor.resizeLeftRight.set(); return }
        if (track(at: p.y) == .main && projectClip(at: time(p.x)) != nil) || overlay(at: p) != nil || text(at: p) != nil || sound(at: p) != nil { NSCursor.openHand.set(); return }
        NSCursor.arrow.set()
    }

    override func keyDown(with e: NSEvent) {
        guard let s = session, s.isProject else { super.keyDown(with: e); return }
        switch e.keyCode {
        case 51, 117: s.deleteSelection()           // ⌫, ⌦
        case 53: s.select(.none)                     // Esc
        default: super.keyDown(with: e)
        }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) { zoom(by: 1 - e.scrollingDeltaY * 0.01, around: convert(e.locationInWindow, from: nil).x) }
        else {
            let dx = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            viewport.scroll(by: -Double(dx) / Double(max(1, bounds.width)) * visibleLength)
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) { zoom(by: 1 - e.magnification, around: convert(e.locationInWindow, from: nil).x) }

    func zoom(by factor: Double, around px: CGFloat, notify: Bool = true) {
        viewport.zoom(by: factor, anchor: time(px), fraction: Double(px / max(1, bounds.width)))
        needsDisplay = true
        if notify { onZoomChange?(zoomFraction) }
    }

    func zoomIn() { zoom(by: 0.5, around: x(session?.player.currentTime.seconds ?? 0)) }
    func zoomOut() { zoom(by: 2, around: x(session?.player.currentTime.seconds ?? 0)) }

    // MARK: Dropping from the library and Finder

    private func payload(_ info: NSDraggingInfo) -> (urls: [URL], item: DragPayload?) {
        let pb = info.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let item = urls.isEmpty ? pb.string(forType: .string).flatMap(DragPayload.parse) : nil
        return (urls, item)
    }

    private func target(for info: NSDraggingInfo) -> DropTarget? {
        guard let s = session, s.isProject, s.canEdit else { return nil }
        let p = convert(info.draggingLocation, from: nil)
        let t = clampTime(time(p.x))
        let tr = track(at: p.y)
        let (urls, item) = payload(info)
        if let item {
            switch item {
            case .filter: return projectClip(at: t).map { .clip($0.id) }
            case .transition: return cutClip(near: t).map { .cut($0) }
            case .text, .sticker, .shape, .preset: return s.project.timeline.isEmpty ? nil : .text(t)
            }
        }
        guard let first = urls.first, let kind = MediaBin.kind(of: first.path) else { return nil }
        switch kind {
        case .audio: return .audio(t)
        case .video:
            if case .lane(let l) = tr, !s.project.timeline.isEmpty { return .lane(l, t) }
            return .insert(s.project.timeline.isEmpty ? 0 : dropIndex(at: time(p.x)))
        case .photo:
            // On a layer line: a layer over the video. Elsewhere: a clip of its own on the main track.
            if case .lane(let l) = tr, !s.project.timeline.isEmpty { return .lane(l, t) }
            return .insert(s.project.timeline.isEmpty ? 0 : dropIndex(at: time(p.x)))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let d = target(for: sender)
        if d != dropTarget { dropTarget = d; needsDisplay = true }
        return d == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = nil; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = session, let d = target(for: sender) else { dropTarget = nil; needsDisplay = true; return false }
        let (urls, item) = payload(sender)
        dropTarget = nil; needsDisplay = true
        window?.makeFirstResponder(self)
        switch (d, item) {
        case (.clip(let id), .filter(let f)?): s.applyFilter(f, toClip: id)
        case (.cut(let id), .transition(let k)?): s.applyTransition(k, intoClip: id)
        case (.text(let t), .text(let tpl)?): s.addText(tpl, at: MediaTime(seconds: t, timescale: 600))
        case (.text(let t), .sticker(let e)?): s.addSticker(e, at: MediaTime(seconds: t, timescale: 600))
        case (.text(let t), .shape(let k)?): s.addShape(k, at: MediaTime(seconds: t, timescale: 600))
        case (.text(let t), .preset(let p)?): s.addPreset(p, at: MediaTime(seconds: t, timescale: 600))
        case (.insert(let i), _): Task { await s.place(urls, videoIndex: i) }
        case (.lane(let l, let t), _): Task { await s.place(urls, at: MediaTime(seconds: t, timescale: 600), lane: l) }
        case (.audio(let t), _): Task { await s.place(urls, at: MediaTime(seconds: t, timescale: 600)) }
        default: return false
        }
        return true
    }

    /// Drops for the self-test: what a drop at `point` (in this view) of these files or this item would do, and doing it.
    func testDrop(urls: [URL], item: DragPayload?, at point: CGPoint) -> DropTarget? {
        let pb = NSPasteboard(name: NSPasteboard.Name("MacPlayer.testDrop.\(UUID().uuidString)"))
        pb.clearContents()
        if let item { pb.setString(item.string, forType: .string) } else { pb.writeObjects(urls as [NSURL]) }
        defer { pb.releaseGlobally() }
        return testDrop(pasteboard: pb, at: point)
    }

    /// A drop of whatever is on this pasteboard (filled the way a real drag fills it).
    func testDrop(pasteboard pb: NSPasteboard, at point: CGPoint) -> DropTarget? {
        let info = TestDraggingInfo(pb: pb, loc: convert(point, to: nil), dest: window)
        let d = target(for: info)
        _ = performDragOperation(info)
        return d
    }

    /// The middle of each track, and the x of a time, for the self-test's drops.
    func testPoint(track name: String, time t: Double) -> CGPoint {
        let y: CGFloat
        switch name {
        case "main": y = mainRect.midY
        case "text": y = textTop + textHeight / 2
        case "audio": y = audioTop + audioHeight / 2
        default: y = lanesTop + laneHeight / 2 + CGFloat(Int(name.dropFirst(4)) ?? 0) * laneHeight   // "lane0"…
        }
        return CGPoint(x: x(t), y: y)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let s = session, s.isProject else { return nil }      // watching only: nothing to edit here
        let p = convert(event.locationInWindow, from: nil)
        clickTime = time(p.x)
        let m = NSMenu()
        if let o = overlay(at: p) { s.select(.layer(o.id)) }
        else if let o = text(at: p) { s.select(.text(o.id)) }
        else if let c = sound(at: p) { s.select(.sound(c.id)) }
        else if track(at: p.y) == .main, let c = projectClip(at: clickTime) { if !s.selectedClipIDs.contains(c.id) { s.select(.clip(c.id)) } }
        if case .clip = s.selection { m.addItem(withTitle: L("Split at Playhead"), action: #selector(splitHere), keyEquivalent: "").target = self }
        if s.selection != .none {
            m.addItem(withTitle: L("Duplicate"), action: #selector(duplicateSelected), keyEquivalent: "").target = self
            m.addItem(withTitle: L("Delete"), action: #selector(deleteSelected), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        m.addItem(withTitle: L("Add Marker Here"), action: #selector(addMarkerHere), keyEquivalent: "").target = self
        return m
    }
    private var clickTime = 0.0
    @objc private func splitHere() { session?.splitAtPlayhead() }
    @objc private func duplicateSelected() { session?.duplicateSelection() }
    @objc private func deleteSelected() { session?.deleteSelection() }
    @objc private func addMarkerHere() {
        session?.edit("Add marker", refreshPreview: false) { $0.markers.append(Marker(time: MediaTime(seconds: self.clickTime, timescale: 600), name: LF("Marker %d", $0.markers.count + 1))) }
    }

    // MARK: Accessibility (VoiceOver)

    override func accessibilityValue() -> Any? {
        guard let s = session else { return nil }
        return LF("%@ of %@", Timecode.format(s.player.currentTime), Timecode.format(s.duration))
    }
    override func accessibilityPerformIncrement() -> Bool { session?.player.skip(seconds: 5); return true }
    override func accessibilityPerformDecrement() -> Bool { session?.player.skip(seconds: -5); return true }
}

/// A drop as the system would hand it over (for the self-test): a pasteboard and a place in the window.
final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let pb: NSPasteboard; let loc: NSPoint; weak var dest: NSWindow?
    init(pb: NSPasteboard, loc: NSPoint, dest: NSWindow?) { self.pb = pb; self.loc = loc; self.dest = dest }
    var draggingDestinationWindow: NSWindow? { dest }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { loc }
    var draggedImageLocation: NSPoint { loc }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// The playhead line with its head. It takes no clicks: they go to the strip under it.
final class PlayheadView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height))
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: 12, y: 0)); ctx.addLine(to: CGPoint(x: 12, y: 6)); ctx.addLine(to: CGPoint(x: 6, y: 12)); ctx.addLine(to: CGPoint(x: 0, y: 6)); ctx.closePath()
        ctx.fillPath()
    }
}

