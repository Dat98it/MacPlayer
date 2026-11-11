import AppKit
import Combine
import MacPlayerCore

/// The strip under the video: ruler, waveform, clips, markers, playhead. Click or drag to move the playhead; in a video project,
/// drag a clip to move it and its edges to trim it; scroll to move, pinch or ⌘-scroll to zoom. When only watching, it is the
/// waveform and the playhead.
@MainActor
final class TimelineView: NSView {
    private weak var session: EditorSession?
    private var bag = Set<AnyCancellable>()

    private var viewport = TimelineViewport()
    private var visibleStart: Double { viewport.start }
    private var visibleLength: Double { viewport.length }
    private var followPlayhead = true

    private enum Drag { case none, playhead, edge(UUID, left: Bool), pan, moveClip(UUID, startX: CGFloat), overlayMove(UUID, grab: Double), overlayEdge(UUID, left: Bool) }
    private var moveTarget: Int?
    private var movedFar = false
    private var drag = Drag.none

    private let rulerHeight: CGFloat = 20
    private let laneHeight: CGFloat = 24
    private var laneCount: Int { OverlayClip.laneCount }
    /// Where the layer lines begin (project mode only): they sit under the main track.
    private var lanesTop: CGFloat { (session?.isProject ?? false) ? bounds.height - CGFloat(laneCount) * laneHeight : bounds.height }
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
        fitAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var total: Double { max(0, session?.duration.seconds ?? 0) }

    func fitAll() { viewport.fitAll(total: total); needsDisplay = true }

    /// What the strip shows now, in seconds (for the self-test).
    var visibleSpan: (start: Double, length: Double) { (viewport.start, viewport.length) }

    private func x(_ t: Double) -> CGFloat { CGFloat((t - visibleStart) / visibleLength) * bounds.width }
    private func time(_ x: CGFloat) -> Double { visibleStart + Double(x / max(1, bounds.width)) * visibleLength }
    private func clampTime(_ t: Double) -> Double { min(max(0, t), total) }

    private func followIfNeeded() {
        guard followPlayhead, let s = session, s.player.isPlaying else { return }
        viewport.follow(playhead: s.player.currentTime.seconds)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        bounds.fill()

        drawRuler()
        let track = CGRect(x: 0, y: rulerHeight, width: bounds.width, height: lanesTop - rulerHeight)

        // Waveform
        if !s.isProject, !s.peaks.isEmpty {
            let mid = track.midY, half = track.height / 2 - 4
            ctx.setFillColor(NSColor.systemTeal.withAlphaComponent(0.55).cgColor)
            let n = s.peaks.count
            var px = CGFloat(0)
            while px < bounds.width {
                let t0 = time(px), t1 = time(px + 1)
                let span = max(0.001, total)
                let i0 = max(0, min(n - 1, Int(t0 / span * Double(n)))), i1 = max(i0, min(n - 1, Int(t1 / span * Double(n))))
                var peak: Float = 0
                for i in i0...i1 { peak = max(peak, s.peaks[i]) }
                let h = max(1, CGFloat(peak) * half)
                ctx.fill(CGRect(x: px, y: mid - h, width: 1, height: h * 2))
                px += 1
            }
        }

        if s.isProject { drawProjectClips(s, ctx, track); drawLanes(s, ctx) }

        // Markers
        for m in s.project.markers {
            let mx = x(m.time.seconds)
            guard mx >= 0, mx <= bounds.width else { continue }
            let color = Self.markerColor(m.color)
            ctx.setFillColor(color.cgColor)
            ctx.move(to: CGPoint(x: mx, y: rulerHeight)); ctx.addLine(to: CGPoint(x: mx + 7, y: rulerHeight - 6)); ctx.addLine(to: CGPoint(x: mx - 7, y: rulerHeight - 6)); ctx.closePath()
            ctx.fillPath()
            ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: mx, y: rulerHeight, width: 0, height: track.height))
        }

        // Playhead
        let px = x(s.player.currentTime.seconds)
        NSColor.systemRed.setFill()
        CGRect(x: px - 1, y: 0, width: 2, height: bounds.height).fill()
        ctx.move(to: CGPoint(x: px - 5, y: 0)); ctx.addLine(to: CGPoint(x: px + 5, y: 0)); ctx.addLine(to: CGPoint(x: px, y: 8)); ctx.closePath()
        ctx.setFillColor(NSColor.systemRed.cgColor); ctx.fillPath()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
        }
    }

    private func drawProjectClips(_ s: EditorSession, _ ctx: CGContext, _ track: CGRect) {
        let missing = s.missingSourceIDs
        var start = 0.0
        for (i, c) in s.project.timeline.enumerated() {
            let len = c.duration.seconds
            defer { start += len }
            let r = CGRect(x: x(start), y: track.minY + 2, width: x(start + len) - x(start), height: track.height - 4)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let srcIndex = s.project.sources.firstIndex { $0.id == c.sourceID } ?? 0
            let isMissing = missing.contains(c.sourceID)
            let base = isMissing ? NSColor.systemRed : Self.palette[srcIndex % Self.palette.count]
            let selected = s.selectedClipIDs.contains(c.id)
            ctx.setFillColor(base.withAlphaComponent(selected ? 0.38 : 0.22).cgColor); ctx.fill(r)
            if let peaks = s.peaksBySource[c.sourceID], !peaks.isEmpty, let dur = s.infos[c.sourceID]?.duration.seconds, dur > 0 {
                let mid = r.midY, half = r.height / 2 - 12
                ctx.setFillColor(base.withAlphaComponent(0.7).cgColor)
                var px = max(r.minX, 0).rounded(.down)
                while px < min(r.maxX, bounds.width) {
                    let f0 = (px - r.minX) / max(1, r.width), f1 = (px + 1 - r.minX) / max(1, r.width)
                    let span = (c.sourceEnd - c.sourceStart).seconds
                    let a = max(0, min(peaks.count - 1, Int((c.sourceStart.seconds + f0 * span) / dur * Double(peaks.count))))
                    let b = max(a, min(peaks.count - 1, Int((c.sourceStart.seconds + f1 * span) / dur * Double(peaks.count))))
                    var peak: Float = 0
                    for k in a...b { peak = max(peak, peaks[k]) }
                    let h = max(1, CGFloat(peak) * half)
                    ctx.fill(CGRect(x: px, y: mid - h + 6, width: 1, height: h * 2))
                    px += 1
                }
            }
            ctx.setStrokeColor(base.cgColor); ctx.setLineWidth(selected ? 2.5 : 1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            ctx.setFillColor(base.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: 3, height: r.height)); ctx.fill(CGRect(x: r.maxX - 3, y: r.minY, width: 3, height: r.height))
            var label = "\(i + 1). " + (c.name.isEmpty ? PathUtil.fileName(of: s.project.source(c.sourceID)?.path ?? "") : c.name)
            if c.look.speed != 1 { label += String(format: "  %g×", c.look.speed) }
            if isMissing { label += "  ⚠︎ " + L("Missing") }
            (label as NSString).draw(at: CGPoint(x: max(r.minX, 0) + 6, y: r.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor])
            // A transition into this clip: a small orange bow tie on the cut.
            if i > 0, c.look.transitionIn != nil {
                let cx = r.minX, cy = r.midY + 4, k: CGFloat = 6
                ctx.setFillColor(NSColor.systemOrange.cgColor)
                ctx.move(to: CGPoint(x: cx - k, y: cy - k)); ctx.addLine(to: CGPoint(x: cx + k, y: cy + k)); ctx.addLine(to: CGPoint(x: cx + k, y: cy - k)); ctx.addLine(to: CGPoint(x: cx - k, y: cy + k)); ctx.closePath()
                ctx.fillPath()
            }
        }
        if let t = moveTarget {
            var pos = 0.0
            for (i, c) in s.project.timeline.enumerated() { if i == t { break }; pos += c.duration.seconds }
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.fill(CGRect(x: x(pos) - 1.5, y: rulerHeight, width: 3, height: bounds.height - rulerHeight))
        }
    }

    private func drawLanes(_ s: EditorSession, _ ctx: CGContext) {
        for lane in 0..<laneCount {
            let y = lanesTop + CGFloat(lane) * laneHeight
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(lane % 2 == 0 ? 0.05 : 0.09).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: laneHeight))
            ("L\(lane + 1)" as NSString).draw(at: CGPoint(x: 4, y: y + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        for c in s.project.overlayClips {
            let r = CGRect(x: x(c.start.seconds), y: lanesTop + CGFloat(c.lane) * laneHeight + 2, width: max(3, x(c.end.seconds) - x(c.start.seconds)), height: laneHeight - 4)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let missing = c.sourceID.map { s.missingSourceIDs.contains($0) } ?? false
            let base: NSColor = missing ? .systemRed : (c.isVideo ? .systemPurple : .systemOrange)
            let selected = s.selectedOverlayID == c.id
            ctx.setFillColor(base.withAlphaComponent(selected ? 0.55 : 0.35).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
            ctx.setStrokeColor(base.cgColor); ctx.setLineWidth(selected ? 2 : 1)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.strokePath()
            ctx.setFillColor(base.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY + 3, width: 3, height: r.height - 6)); ctx.fill(CGRect(x: r.maxX - 3, y: r.minY + 3, width: 3, height: r.height - 6))
            ((c.isVideo ? "▶ " : "▣ ") + c.name as NSString).draw(at: CGPoint(x: max(r.minX, 0) + 6, y: r.minY + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor])
            for k in c.keyframes {   // keyframes as small diamonds
                let kx = x((c.start + k.time).seconds), ky = r.maxY - 4
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.move(to: CGPoint(x: kx, y: ky - 4)); ctx.addLine(to: CGPoint(x: kx + 4, y: ky)); ctx.addLine(to: CGPoint(x: kx, y: ky + 4)); ctx.addLine(to: CGPoint(x: kx - 4, y: ky)); ctx.closePath(); ctx.fillPath()
            }
        }
    }

    private func overlayEdge(at p: CGPoint) -> (UUID, Bool)? {
        guard let s = session, p.y >= lanesTop else { return nil }
        let lane = Int((p.y - lanesTop) / laneHeight)
        for c in s.project.overlayClips where c.lane == lane {
            if abs(p.x - x(c.start.seconds)) <= 5 { return (c.id, true) }
            if abs(p.x - x(c.end.seconds)) <= 5 { return (c.id, false) }
        }
        return nil
    }

    private func overlay(at p: CGPoint) -> OverlayClip? {
        guard let s = session, p.y >= lanesTop else { return nil }
        let lane = Int((p.y - lanesTop) / laneHeight), t = time(p.x)
        return s.project.overlayClips.first { $0.lane == lane && $0.start.seconds <= t && t < $0.end.seconds }
    }

    private func projectEdge(at p: CGPoint) -> (UUID, Bool)? {
        guard let s = session, p.y > rulerHeight, p.y < lanesTop else { return nil }
        var start = 0.0
        for c in s.project.timeline {
            let end = start + c.duration.seconds
            if abs(p.x - x(start)) <= 5 { return (c.id, true) }
            if abs(p.x - x(end)) <= 5 { return (c.id, false) }
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

    private func drawRuler() {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let target = visibleLength / Double(max(1, bounds.width / 90))
        let step = steps.first { $0 >= target } ?? 3600
        var t = (visibleStart / step).rounded(.down) * step
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.separatorColor.setFill()
        while t <= visibleStart + visibleLength {
            let px = x(t)
            if px >= 0 { CGRect(x: px, y: rulerHeight - 6, width: 1, height: 6).fill(); (Timecode.format(MediaTime(seconds: t)) as NSString).draw(at: CGPoint(x: px + 3, y: 3), withAttributes: attrs) }
            t += step
        }
        CGRect(x: 0, y: rulerHeight - 1, width: bounds.width, height: 1).fill()
    }

    static let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemIndigo]
    static func markerColor(_ c: MarkerColor) -> NSColor {
        switch c { case .red: return .systemRed; case .orange: return .systemOrange; case .yellow: return .systemYellow; case .green: return .systemGreen
        case .blue: return .systemBlue; case .purple: return .systemPurple; case .gray: return .systemGray }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard let s = session else { return }
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        followPlayhead = false
        if s.isProject, p.y >= lanesTop {
            if let (id, left) = overlayEdge(at: p) { drag = .overlayEdge(id, left: left); s.selectedOverlayID = id; s.selectedClipIDs = []; s.activeTool = .layers; return }
            if let c = overlay(at: p) {
                s.selectedOverlayID = c.id; s.selectedClipIDs = []; s.activeTool = .layers
                drag = .overlayMove(c.id, grab: time(p.x) - c.start.seconds)
                return
            }
            s.selectedOverlayID = nil
            drag = .playhead
            s.player.scrub(to: MediaTime(seconds: clampTime(time(p.x)), timescale: 600))
            return
        }
        if s.isProject {
            s.selectedOverlayID = nil
            if let (id, left) = projectEdge(at: p) { drag = .edge(id, left: left); s.selectedClipIDs = [id]; return }
            if p.y > rulerHeight, let c = projectClip(at: time(p.x)) {
                s.selectedClipIDs = e.modifierFlags.contains(.command) ? s.selectedClipIDs.symmetricDifference([c.id]) : [c.id]
                drag = .moveClip(c.id, startX: p.x); movedFar = false
                s.player.scrub(to: MediaTime(seconds: clampTime(time(p.x)), timescale: 600))
                return
            }
            if p.y > rulerHeight { s.selectedClipIDs = [] }
            drag = .playhead
            s.player.scrub(to: MediaTime(seconds: clampTime(time(p.x)), timescale: 600))
            return
        }
        drag = .playhead
        s.player.scrub(to: MediaTime(seconds: clampTime(time(p.x)), timescale: 600))
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = session else { return }
        let p = convert(e.locationInWindow, from: nil)
        let t = clampTime(time(p.x))
        switch drag {
        case .playhead: s.player.scrub(to: MediaTime(seconds: t, timescale: 600))
        case .edge(let id, let left):
            s.trimClip(id, leftEdge: left, toTimelineTime: MediaTime(seconds: t, timescale: 600))
        case .overlayMove(let id, let grab):
            let lane = max(0, min(laneCount - 1, Int((p.y - lanesTop) / laneHeight)))
            s.moveOverlay(id, toStart: MediaTime(seconds: max(0, t - grab), timescale: 600), lane: lane)
        case .overlayEdge(let id, let left):
            s.trimOverlay(id, leftEdge: left, toTimelineTime: MediaTime(seconds: t, timescale: 600))
        case .moveClip(_, let startX):
            if abs(p.x - startX) > 6 { movedFar = true }
            if movedFar { moveTarget = dropIndex(at: t); needsDisplay = true }
        default: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard let s = session else { return }
        switch drag { case .edge, .overlayMove, .overlayEdge: s.endCoalescing(); default: break }
        if case .moveClip(let id, _) = drag, movedFar, let target = moveTarget { s.moveClip(id, toIndex: target) }
        moveTarget = nil; movedFar = false
        drag = .none; needsDisplay = true
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

    func zoom(by factor: Double, around px: CGFloat) {
        viewport.zoom(by: factor, anchor: time(px), fraction: Double(px / max(1, bounds.width)))
        needsDisplay = true
    }

    func zoomIn() { zoom(by: 0.5, around: x(session?.player.currentTime.seconds ?? 0)) }
    func zoomOut() { zoom(by: 2, around: x(session?.player.currentTime.seconds ?? 0)) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let s = session else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let m = NSMenu()
        if s.isProject, let o = overlay(at: p) {
            s.selectedOverlayID = o.id; s.selectedClipIDs = []
            m.addItem(withTitle: L("Duplicate"), action: #selector(duplicateOverlayHere), keyEquivalent: "").target = self
            m.addItem(withTitle: L("Delete Layer"), action: #selector(deleteOverlayHere), keyEquivalent: "").target = self
            return m
        }
        if s.isProject {
            if let c = projectClip(at: time(p.x)) { s.selectedClipIDs = [c.id] }
            m.addItem(withTitle: L("Split at Playhead"), action: #selector(splitHere), keyEquivalent: "").target = self
            m.addItem(withTitle: L("Duplicate"), action: #selector(duplicateSelected), keyEquivalent: "").target = self
            m.addItem(withTitle: L("Delete Clip"), action: #selector(deleteClickedClip), keyEquivalent: "").target = self
            m.addItem(withTitle: L("Add Marker Here"), action: #selector(addMarkerHere), keyEquivalent: "").target = self
            clickTime = time(p.x)
            return m
        }
        return nil      // watching only: nothing to edit here
    }
    private var clickTime = 0.0
    @objc private func duplicateOverlayHere() { if let s = session, let id = s.selectedOverlayID { s.duplicateOverlay(id) } }
    @objc private func deleteOverlayHere() { if let s = session, let id = s.selectedOverlayID { s.deleteOverlay(id) } }
    @objc private func splitHere() { session?.splitAtPlayhead() }
    @objc private func duplicateSelected() { if let s = session { s.duplicateTimelineClips(s.selectedClipIDs) } }
    @objc private func deleteClickedClip() { if let s = session { s.deleteTimelineClips(s.selectedClipIDs) } }
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
