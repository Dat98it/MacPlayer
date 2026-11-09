import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// The Colour tool: sliders for the basics and, one click further, curves, colour wheels, colours by range (HSL), a look file and a
/// histogram. Every part has its own reset, and the whole grade can be compared with the original, copied to another clip, or cleared.
struct ColorPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var open = Box<Set<String>>(["basic"])
    @StateObject private var channel = Box<ColorCurves.Channel>(.master)
    @StateObject private var band = Box<HSLBand>(.red)
    @StateObject private var scope = Box<Histogram?>(nil)

    private var colour: ColorAdjust { session.project.activeLook.color }

    private func slider(_ title: String, _ key: String, _ kp: WritableKeyPath<ColorAdjust, Double>, hint: String? = nil) -> some View {
        SliderRow(title: title, value: Binding(get: { colour[keyPath: kp] }, set: { v in session.editColor(title, coalesce: key) { $0[keyPath: kp] = v } }),
                  range: -1...1, format: "%+.2f", onDone: { session.endCoalescing() })
            .help(hint ?? title)
    }

    private func section<Content: View>(_ id: String, _ title: String, icon: String, changed: Bool, reset: @escaping () -> Void, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        let isOpen = open.value.contains(id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { if isOpen { open.value.remove(id) } else { open.value.insert(id) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
                        Image(systemName: icon).foregroundColor(.accentColor).frame(width: 18)
                        Text(title).font(.subheadline.weight(.semibold))
                        if changed { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel(L("changed")) }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(.isButton)
                if changed { Button(L("Reset"), action: reset).buttonStyle(.borderless).font(.caption).foregroundColor(.secondary) }
            }
            if isOpen { content() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// Development aid: MACPLAYER_DEV_COLOR=1 puts a sample grade on the picture (to look at the tool with something in it).
    private func devGrade() {
        guard ProcessInfo.processInfo.environment["MACPLAYER_DEV_COLOR"] != nil, colour.isNeutral else { return }
        session.editColor("sample") { c in
            c.exposure = 0.15; c.shadows = 0.3; c.vibrance = 0.4
            c.curves.setPoints([CurvePoint(x: 0.3, y: 0.22), CurvePoint(x: 0.75, y: 0.85)], for: .master)
            c.curves.setPoints([CurvePoint(x: 0.5, y: 0.58)], for: .red)
            c.wheels.shadows = ColorWheel(x: 0.5, y: 0.3)
            c.wheels.highlights = ColorWheel(x: -0.3, y: -0.4, luma: 0.1)
            c.hsl[.blue] = HSLAdjust(hue: 0.2, saturation: 0.4, luminance: 0)
        }
        // The value lists the cards to open (basic, curves, wheels, hsl, lut), e.g. MACPLAYER_DEV_COLOR=curves,wheels
        let tokens = Set(ProcessInfo.processInfo.environment["MACPLAYER_DEV_COLOR"]?.split(separator: ",").map(String.init) ?? [])
        open.value = tokens.intersection(["basic", "curves", "wheels", "hsl", "lut"])
        if tokens.contains("blue") { band.value = .blue }
    }

    var body: some View {
        let c = colour
        VStack(alignment: .leading, spacing: 10) {
            header(c)
            scopeCard
            section("basic", L("Light and colour"), icon: "sun.max", changed: c.brightness != 0 || c.contrast != 0 || c.saturation != 0 || c.temperature != 0 || c.exposure != 0 || c.highlights != 0 || c.shadows != 0 || c.vibrance != 0 || c.tint != 0,
                    reset: { session.editColor("Reset light and colour") { v in v.brightness = 0; v.contrast = 0; v.saturation = 0; v.temperature = 0; v.exposure = 0; v.highlights = 0; v.shadows = 0; v.vibrance = 0; v.tint = 0 } }) {
                slider(L("Exposure"), "c-exposure", \.exposure, hint: L("Makes the whole picture lighter or darker."))
                slider(L("Brightness"), "c-b", \.brightness)
                slider(L("Contrast"), "c-c", \.contrast)
                slider(L("Highlights"), "c-hi", \.highlights, hint: L("Brings down (−) or pushes up (+) the lightest parts."))
                slider(L("Shadows"), "c-sh", \.shadows, hint: L("Lifts (+) or deepens (−) the darkest parts."))
                slider(L("Saturation"), "c-s", \.saturation)
                slider(L("Vibrance"), "c-v", \.vibrance, hint: L("Like saturation, but it helps dull colours more than strong ones."))
                slider(L("Temperature"), "c-t", \.temperature, hint: L("Cooler (−) or warmer (+)."))
                slider(L("Tint"), "c-tint", \.tint, hint: L("Greener (−) or more magenta (+)."))
            }
            section("curves", L("Curves"), icon: "chart.xyaxis.line", changed: !c.curves.isNeutral, reset: { session.editColor("Reset curves") { $0.curves = ColorCurves() } }) { curvesBody(c) }
            section("wheels", L("Colour wheels"), icon: "circle.hexagongrid", changed: !c.wheels.isNeutral, reset: { session.editColor("Reset colour wheels") { $0.wheels = ColorWheels() } }) { wheelsBody(c) }
            section("hsl", L("Colours"), icon: "paintpalette", changed: !c.hsl.isNeutral, reset: { session.editColor("Reset colours") { $0.hsl = ColorHSL() } }) { hslBody(c) }
            section("lut", L("Look file"), icon: "cube", changed: c.lut != nil, reset: { session.edit("Remove colour look") { $0.activeLook.color.lut = nil }; ColorLive.clear() }) { lutBody(c) }
            if session.info?.primaryVideo?.isHDR == true {
                Label(L("This video is HDR. Colour changes are applied to the HDR picture as stored, without tone mapping, so check the result."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { devGrade() }
    }

    // MARK: Top bar

    private func header(_ c: ColorAdjust) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: panelColumns(70), spacing: 4) {
                // Held down, the picture shows without any of the changes.
                PanelButton(title: L("Compare"), icon: "rectangle.lefthalf.inset.filled", help: L("Hold to see the picture as it was before the colour changes"), selected: session.colorCompare) {}
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in session.setColorCompare(true) }.onEnded { _ in session.setColorCompare(false) })
                    .disabled(c.isNeutral)
                PanelButton(title: L("Copy"), icon: "doc.on.doc", help: L("Copy the colour of this picture")) { session.copyColor() }.disabled(c.isNeutral)
                PanelButton(title: L("Paste"), icon: "doc.on.clipboard", help: L("Put the copied colour on this picture")) { session.pasteColor() }
                    .disabled(ColorClipboard.shared.value == nil)
                if session.isProject && session.project.timeline.count > 1 {
                    PanelButton(title: L("All clips"), icon: "square.stack.3d.up", help: L("Give every clip of the project this colour")) { session.applyColorToAllClips(c) }.disabled(c.isNeutral)
                }
                PanelButton(title: L("Reset all"), icon: "arrow.counterclockwise", help: L("Take every colour change off this picture"), tint: .red) {
                    session.editColor("Reset colour") { $0 = ColorAdjust() }; ColorLive.clear()
                }.disabled(c.isNeutral)
            }
            Text(L("Tip: hold Compare to see how the picture looked before the changes.")).font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Histogram

    private var scopeKey: String { "\(colour.hashValue)|\(Int(session.player.currentTime.seconds * 4))|\(session.project.activeClipID?.uuidString ?? "")" }

    private var scopeCard: some View {
        let h = scope.value
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg.rectangle").foregroundColor(.accentColor).frame(width: 18)
                Text(L("Histogram")).font(.subheadline.weight(.semibold))
                Spacer()
            }
            HistogramView(histogram: h).frame(height: 64)
            if let h, h.clippedDark > 0.02 || h.clippedLight > 0.02 {
                Label(h.clippedLight > h.clippedDark ? L("Part of the picture is pure white: detail is lost there.") : L("Part of the picture is pure black: detail is lost there."),
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Shows how light and dark the picture is. Bars piled at the left edge mean it is too dark, at the right edge too bright.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
        .task(id: scopeKey) { await refreshScope() }
    }

    private func refreshScope() async {
        try? await Task.sleep(nanoseconds: 200_000_000)          // a slider being dragged only draws the last one
        if Task.isCancelled { return }
        var frame: CGImage?
        let size = CGSize(width: 240, height: 135)
        if session.isPhoto || session.sourceURL != nil {
            let t = min(max(session.player.currentTime, .zero), session.duration)
            frame = await session.stillImage(at: session.isPhoto ? .zero : t, maxSize: size)
        } else if let clip = session.project.timeline.first(where: { $0.id == session.project.activeClipID }) ?? session.project.timeline.first,
                  let src = session.project.sources.first(where: { $0.id == clip.sourceID }) {
            let mid = clip.sourceStart + MediaTime(seconds: min(1, clip.sourceSpan.duration.seconds / 2), timescale: 600)
            frame = try? await FrameGrabber.image(url: URL(fileURLWithPath: src.path), at: mid, accuracy: .nearest, maxSize: size)
        }
        guard let frame, !Task.isCancelled else { return }
        let graded = EffectPreview.image(from: frame, colour: colour) ?? frame
        scope.value = Self.histogram(of: graded)
    }

    /// Counts the pixels of a picture (drawn into 8-bit RGBA first, whatever it was).
    static func histogram(of image: CGImage) -> Histogram? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Histogram.compute(bytes: bytes, width: w, height: h, bytesPerRow: w * 4) : nil
    }

    // MARK: Curves

    private func curvesBody(_ c: ColorAdjust) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $channel.value) {
                Text(L("Brightness")).tag(ColorCurves.Channel.master)
                Text(L("Red")).tag(ColorCurves.Channel.red)
                Text(L("Green")).tag(ColorCurves.Channel.green)
                Text(L("Blue")).tag(ColorCurves.Channel.blue)
            }.pickerStyle(.segmented).labelsHidden()
            let ch = channel.value
            CurveEditor(points: Binding(get: { colour.curves.points(ch) },
                                        set: { p in session.editColor("Curve", coalesce: "curve-\(ch.rawValue)") { $0.curves.setPoints(p, for: ch) } }),
                        tint: Self.curveColor(ch), onDone: { session.endCoalescing() })
                .aspectRatio(1, contentMode: .fit).frame(maxWidth: 240).frame(maxWidth: .infinity)
            HStack {
                Text(L("Click the line to add a point, drag a point to bend the curve, double-click a point to remove it.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if !colour.curves.points(ch).isEmpty {
                    Button(L("Straighten")) { session.editColor("Straighten curve") { $0.curves.setPoints([], for: ch) } }.font(.caption)
                }
            }
        }
    }

    static func curveColor(_ ch: ColorCurves.Channel) -> Color {
        switch ch { case .master: return .white; case .red: return Color(red: 1, green: 0.35, blue: 0.33); case .green: return Color(red: 0.35, green: 0.85, blue: 0.4); case .blue: return Color(red: 0.4, green: 0.6, blue: 1) }
    }

    // MARK: Wheels

    private func wheelsBody(_ c: ColorAdjust) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                wheel(L("Shadows"), c.wheels.shadows, \.shadows)
                wheel(L("Midtones"), c.wheels.midtones, \.midtones)
                wheel(L("Highlights"), c.wheels.highlights, \.highlights)
            }
            Text(L("Drag the dot towards a colour to tint that part of the picture. Double-click a wheel to reset it. The slider under it makes that part lighter or darker.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wheel(_ title: String, _ value: ColorWheel, _ kp: WritableKeyPath<ColorWheels, ColorWheel>) -> some View {
        VStack(spacing: 4) {
            ColorWheelView(wheel: Binding(get: { colour.wheels[keyPath: kp] }, set: { w in session.editColor(title, coalesce: "wheel-\(title)") { $0.wheels[keyPath: kp] = w } }),
                           onDone: { session.endCoalescing() })
                .aspectRatio(1, contentMode: .fit)
            Slider(value: Binding(get: { colour.wheels[keyPath: kp].luma }, set: { v in session.editColor(title, coalesce: "wheel-luma-\(title)") { $0.wheels[keyPath: kp].luma = v } }), in: -1...1) { e in if !e { session.endCoalescing() } }
                .controlSize(.mini).accessibilityLabel(LF("%@, lighter or darker", title))
            Text(title).font(.caption2).foregroundColor(value.isNeutral ? .secondary : .primary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: HSL

    private func hslBody(_ c: ColorAdjust) -> some View {
        let b = band.value
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(HSLBand.allCases, id: \.self) { k in
                    Button { band.value = k } label: {
                        Circle().fill(Color(hex: k.swatchHex)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary, lineWidth: k == b ? 2.5 : 0).padding(-3))
                            .overlay(Group { if !c.hsl[k].isNeutral { Circle().fill(Color.white).frame(width: 6, height: 6) } })
                    }.buttonStyle(.plain).help(Self.bandName(k)).accessibilityLabel(Self.bandName(k)).accessibilityAddTraits(k == b ? [.isButton, .isSelected] : .isButton)
                }
            }.padding(.vertical, 3)
            Text(Self.bandName(b)).font(.caption.weight(.semibold))
            hslSlider(L("Hue"), b, \.hue)
            hslSlider(L("Saturation"), b, \.saturation)
            hslSlider(L("Brightness"), b, \.luminance)
            Text(L("Pick a colour, then change only that colour: for example make the sky bluer or the skin tones softer. The white dot marks colours you changed.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hslSlider(_ title: String, _ b: HSLBand, _ kp: WritableKeyPath<HSLAdjust, Double>) -> some View {
        SliderRow(title: title, value: Binding(get: { colour.hsl[b][keyPath: kp] }, set: { v in session.editColor(title, coalesce: "hsl-\(b.rawValue)-\(title)") { $0.hsl[b][keyPath: kp] = v } }),
                  range: -1...1, format: "%+.2f", onDone: { session.endCoalescing() })
    }

    static func bandName(_ b: HSLBand) -> String {
        switch b { case .red: return L("Red"); case .orange: return L("Orange"); case .yellow: return L("Yellow"); case .green: return L("Green")
        case .aqua: return L("Aqua"); case .blue: return L("Blue"); case .purple: return L("Purple"); case .magenta: return L("Magenta") }
    }

    // MARK: Look file

    private func lutBody(_ c: ColorAdjust) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lut = c.lut {
                HStack(spacing: 6) {
                    Image(systemName: LutStore.isUsable(path: lut.path) ? "cube.fill" : "exclamationmark.triangle.fill").foregroundColor(LutStore.isUsable(path: lut.path) ? .accentColor : .orange)
                    Text(lut.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                if !LutStore.isUsable(path: lut.path) {
                    Text(L("This look file cannot be found or read, so it is not used. Choose it again or take it off.")).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                SliderRow(title: L("Strength"), value: Binding(get: { colour.lut?.strength ?? 1 }, set: { v in session.editColor("Look strength", coalesce: "lut-strength") { $0.lut?.strength = v } }),
                          range: 0...1, format: "%.2f", onDone: { session.endCoalescing() })
            }
            HStack {
                Button { session.chooseLookFile() } label: { Label(c.lut == nil ? L("Choose look file…") : L("Choose another…"), systemImage: "folder") }.controlSize(.small)
                if c.lut != nil { Button(L("Take off")) { session.edit("Remove colour look") { $0.activeLook.color.lut = nil }; ColorLive.clear() }.controlSize(.small) }
            }
            Text(L("A look file (.cube) gives the picture the colours of a film or camera style. Many are free to download. The file is only read, never changed; keep it where it is.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Drawing

/// The histogram: red, green and blue added together, with the overall brightness as a white line.
struct HistogramView: View {
    var histogram: Histogram?
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
            guard let h = histogram else { return }
            func path(_ counts: [Int], closed: Bool) -> Path {
                let heights = h.heights(of: counts)
                var p = Path()
                if closed { p.move(to: CGPoint(x: 0, y: size.height)) }
                for i in 0..<256 {
                    let pt = CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(heights[i]) * 0.95))
                    if i == 0 && !closed { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                if closed { p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath() }
                return p
            }
            ctx.blendMode = .plusLighter
            ctx.fill(path(h.red, closed: true), with: .color(Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.55)))
            ctx.fill(path(h.green, closed: true), with: .color(Color(red: 0.2, green: 0.85, blue: 0.3).opacity(0.55)))
            ctx.fill(path(h.blue, closed: true), with: .color(Color(red: 0.25, green: 0.4, blue: 1).opacity(0.65)))
            ctx.blendMode = .normal
            ctx.stroke(path(h.luma, closed: false), with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement().accessibilityLabel(L("Histogram of the picture"))
    }
}

/// A tone curve to shape with the mouse: click the line to add a point, drag to bend, double-click a point to remove it.
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    var tint: Color
    var onDone: () -> Void
    @StateObject private var dragState = Box<Int?>(nil)
    @StateObject private var lastTapState = Box<(index: Int, time: Date)?>(nil)
    private var dragging: Int? { get { dragState.value } nonmutating set { dragState.value = newValue } }
    private var lastTap: (index: Int, time: Date)? { get { lastTapState.value } nonmutating set { lastTapState.value = newValue } }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            ZStack {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
                    var grid = Path()
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        grid.move(to: CGPoint(x: size.width * f, y: 0)); grid.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: size.height * f)); grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                    ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                    var diag = Path(); diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
                    ctx.stroke(diag, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    var curve = Path()
                    for i in 0...64 {
                        let x = Double(i) / 64, y = CurveMath.value(points, at: x)
                        let p = CGPoint(x: size.width * x, y: size.height * (1 - y))
                        if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                    }
                    ctx.stroke(curve, with: .color(tint), lineWidth: 1.8)
                    for p in points {
                        let c = CGPoint(x: size.width * p.x, y: size.height * (1 - p.y))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.white))
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(tint), lineWidth: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let nx = min(max(v.location.x / s.width, 0), 1), ny = min(max(1 - v.location.y / s.height, 0), 1)
                    if dragging == nil {
                        // The point under the pointer, or a new one on the line.
                        if let i = nearest(v.startLocation, in: s) { dragging = i }
                        else {
                            let sx = min(max(v.startLocation.x / s.width, 0), 1), sy = min(max(1 - v.startLocation.y / s.height, 0), 1)
                            var next = points; next.append(CurvePoint(x: sx, y: sy)); points = next
                            dragging = points.firstIndex { abs($0.x - sx) < 1e-6 && abs($0.y - sy) < 1e-6 }
                        }
                    }
                    guard let i = dragging, i < points.count else { return }
                    var next = points
                    // A point stays between its neighbours so the curve never folds back.
                    let lo = i > 0 ? next[i - 1].x + 0.02 : 0, hi = i < next.count - 1 ? next[i + 1].x - 0.02 : 1
                    next[i] = CurvePoint(x: min(max(nx, lo), max(lo, hi)), y: ny)
                    points = next
                }
                .onEnded { v in
                    defer { dragging = nil; onDone() }
                    guard let i = dragging, i < points.count else { return }
                    let moved = hypot(v.translation.width, v.translation.height)
                    if moved < 3 {
                        if let last = lastTap, last.index == i, Date().timeIntervalSince(last.time) < 0.4 {
                            var next = points; next.remove(at: i); points = next; lastTap = nil
                        } else { lastTap = (i, Date()) }
                    } else { lastTap = nil }
                })
        }
        .accessibilityElement().accessibilityLabel(L("Curve")).accessibilityHint(L("Click to add a point, drag to bend the curve."))
    }

    private func nearest(_ p: CGPoint, in s: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, pt) in points.enumerated() {
            let d = hypot(s.width * pt.x - p.x, s.height * (1 - pt.y) - p.y)
            if d < 12, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}

/// One colour wheel: a ring of colours with a dot to drag towards the colour wanted.
struct ColorWheelView: View {
    @Binding var wheel: ColorWheel
    var onDone: () -> Void

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height), r = d / 2
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: (0...12).map { Color(hue: 1 - Double($0) / 12, saturation: 0.85, brightness: 0.95) }), center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1)
                Path { p in p.move(to: CGPoint(x: r, y: r - 4)); p.addLine(to: CGPoint(x: r, y: r + 4)); p.move(to: CGPoint(x: r - 4, y: r)); p.addLine(to: CGPoint(x: r + 4, y: r)) }
                    .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                Circle().fill(Color.white).frame(width: 12, height: 12).overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
                    .position(x: r + CGFloat(wheel.x) * r, y: r + CGFloat(wheel.y) * r)
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                var w = wheel
                w.x = Double((v.location.x - r) / r); w.y = Double((v.location.y - r) / r)
                wheel = w.clamped()
            }.onEnded { _ in onDone() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { var w = wheel; w.x = 0; w.y = 0; wheel = w; onDone() })
        }
        .accessibilityElement().accessibilityLabel(L("Colour wheel")).accessibilityHint(L("Drag the dot towards a colour. Double-click to reset."))
    }
}

extension Color {
    /// "#RRGGBB" as a colour (grey when it cannot be read).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count != 6 { s = "808080" }
        let v = UInt32(s, radix: 16) ?? 0x808080
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
