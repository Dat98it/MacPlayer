import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// Text, shapes and stickers on the picture: ready-made text looks, things to add, and every setting of the one selected.
struct TextPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var tiles = Box<[TextTemplate: NSImage]>([:])

    static let fonts: [(String, String)] = [("Helvetica-Bold", "Helvetica"), ("HelveticaNeue-Medium", "Helvetica Neue"), ("Avenir-Light", "Avenir"), ("AvenirNext-Heavy", "Avenir Next"),
                                            ("Futura-Bold", "Futura"), ("Georgia-Bold", "Georgia"), ("Palatino-Bold", "Palatino"), ("Optima-Bold", "Optima"),
                                            ("MarkerFelt-Wide", "Marker Felt"), ("BradleyHandITCTT-Bold", "Bradley Hand"), ("Menlo-Bold", "Menlo"), ("Impact", "Impact")]
    static let stickers = ["😀", "😂", "😍", "😎", "🤩", "😭", "😱", "🤔", "🥳", "😴",
                           "👍", "👏", "🙏", "💪", "👉", "👆", "🤝", "✌️",
                           "❤️", "💔", "🔥", "💯", "⭐️", "✨", "🎉", "🎁",
                           "✅", "❌", "⚠️", "❓", "❗️", "🔔", "📌", "📍", "💬", "💡",
                           "➡️", "⬅️", "⬆️", "⬇️", "🔝", "🆕",
                           "🎬", "🎥", "📷", "🎵", "🎤", "⏰", "📅", "🛒", "💰", "🏆", "🥇", "⚽️", "🏀", "🏃", "☀️", "🌈", "⚡️", "❄️"]

    static func templateName(_ t: TextTemplate) -> String {
        switch t {
        case .classic: return L("Classic"); case .neon: return L("Neon"); case .comic: return L("Comic"); case .cinematic: return L("Cinematic title")
        case .typewriter: return L("Typewriter"); case .lowerThird: return L("Lower third"); case .highlight: return L("Highlight"); case .pill: return L("Pill")
        case .headline: return L("Headline"); case .subtitleBox: return L("Subtitle box"); case .quote: return L("Quote"); case .retro: return L("Retro")
        case .elegant: return L("Elegant"); case .handwritten: return L("Handwritten"); case .hashtag: return L("Hashtag"); case .sale: return L("Sale"); case .minimal: return L("Minimal")
        }
    }
    static func shapeIcon(_ k: ShapeKind) -> String {
        switch k {
        case .rectangle: return "square.fill"; case .roundedRectangle: return "app.fill"; case .ellipse: return "circle.fill"; case .triangle: return "triangle.fill"
        case .star: return "star.fill"; case .heart: return "heart.fill"; case .arrow: return "arrow.right"; case .line: return "minus"
        case .diamond: return "diamond.fill"; case .pentagon: return "pentagon.fill"; case .hexagon: return "hexagon.fill"; case .speechBubble: return "bubble.left.fill"
        case .burst: return "seal.fill"; case .checkmark: return "checkmark"; case .cross: return "plus"; case .ring: return "circle"
        }
    }
    static func shapeName(_ k: ShapeKind) -> String {
        switch k {
        case .rectangle: return L("Square"); case .roundedRectangle: return L("Rounded"); case .ellipse: return L("Circle"); case .triangle: return L("Triangle")
        case .star: return L("Star"); case .heart: return L("Heart"); case .arrow: return L("Arrow"); case .line: return L("Line")
        case .diamond: return L("Diamond"); case .pentagon: return L("Pentagon"); case .hexagon: return L("Hexagon"); case .speechBubble: return L("Speech bubble")
        case .burst: return L("Badge"); case .checkmark: return L("Tick"); case .cross: return L("Plus"); case .ring: return L("Ring")
        }
    }
    static func animationName(_ k: ElementAnimationKind) -> String {
        switch k {
        case .none: return L("None"); case .fade: return L("Fade"); case .slideUp: return L("Slide up"); case .slideDown: return L("Slide down")
        case .slideLeft: return L("Slide left"); case .slideRight: return L("Slide right"); case .pop: return L("Pop"); case .zoom: return L("Zoom"); case .typewriter: return L("Typewriter")
        }
    }

    var body: some View {
        let overlays = session.project.overlays
        VStack(alignment: .leading, spacing: 12) {
            // Adding lives in one place only: the library's Text tab on the left (click, or drag onto the picture). Here: what is on the
            // picture, and the settings of the one selected (0.13).
            if selectedText == nil {
                Label(L("Add text, shapes and stickers from the Text tab of the library on the left: click one, or drag it onto the picture. Double-click a text on the picture to type in it."), systemImage: "arrow.left")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            ToolCard(title: LF("On the picture (%d)", overlays.count), icon: "list.bullet") {
                if overlays.isEmpty { Text(L("Nothing yet.")).foregroundColor(.secondary) }
                ForEach(overlays) { o in row(o) }
            }
            if let o = selectedText { editor(o) }
        }
    }

    /// A photo has no time: what is put on it is always there.
    private static let always = MediaTime(seconds: 100_000)

    private var selectedText: TextOverlay? { session.project.overlays.first { $0.id == session.selectedTextID } }

    // MARK: Adding

    private func newText(_ text: String, y: Double = 0.5, size: Double = 0.06) -> TextOverlay {
        if session.isPhoto { return TextOverlay(text: text, start: .zero, end: Self.always, sizeFraction: size, y: y) }
        let start = session.player.currentTime
        return TextOverlay(text: text, start: start, end: min(session.duration, start + MediaTime(seconds: 3)), sizeFraction: size, y: y)
    }
    private func insert(_ o: TextOverlay) { session.edit("Add to the picture") { $0.overlays.append(o) }; session.selectedTextID = o.id }
    private func addText(_ t: String, y: Double, size: Double) { insert(newText(t, y: y, size: size)) }
    private func addShape(_ k: ShapeKind) {
        let start = session.isPhoto ? MediaTime.zero : session.player.currentTime
        let spec = ShapeSpec(kind: k, width: k == .line ? 0.3 : (k == .arrow ? 0.25 : 0.18), height: k == .line ? 0.012 : (k == .arrow ? 0.12 : 0.18), fillHex: "#FFD60A", strokeHex: nil)
        insert(TextOverlay.shape(spec, start: start, end: session.isPhoto ? Self.always : min(session.duration, start + MediaTime(seconds: 3))))
    }
    private func addSticker(_ e: String) {
        var o = newText(e, y: 0.5, size: 0.22)
        var f = TextFlair(); f.outlineWidth = 0; o.flair = f; o.animationIn = ElementAnimation(kind: .pop, duration: 0.4)
        insert(o)
    }

    private func update(_ id: UUID, _ label: String, key: String? = nil, _ f: @escaping (inout TextOverlay) -> Void) {
        session.edit(label, coalesce: key.map { "\($0)-\(id)" }) { p in if let i = p.overlays.firstIndex(where: { $0.id == id }) { f(&p.overlays[i]) } }
    }

    // MARK: List and templates

    private func row(_ o: TextOverlay) -> some View {
        let isSel = session.selectedTextID == o.id
        return HStack {
            Image(systemName: o.shape.map { Self.shapeIcon($0.kind) } ?? "textformat").foregroundColor(.secondary).frame(width: 18)
            Text(o.shape.map { Self.shapeName($0.kind) } ?? (o.text.isEmpty ? L("(empty)") : o.text)).lineLimit(1).font(.callout.weight(.medium))
            Spacer()
            if !session.isPhoto { Text("\(Timecode.format(o.start)) – \(Timecode.format(o.end))").font(.caption.monospacedDigit()).foregroundColor(.secondary) }
            Button { session.edit("Delete from the picture") { p in p.overlays.removeAll { $0.id == o.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete"))
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(isSel ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTextID = o.id; if !session.isPhoto { Task { await session.player.seek(to: o.start) } } }.clickable()
    }

    private func templateTile(_ t: TextTemplate) -> some View {
        Button {
            guard let o = selectedText else { session.flash(L("Select or add a text first."), error: true); return }
            update(o.id, LF("Text style %@", Self.templateName(t))) { t.apply(to: &$0) }
        } label: {
            VStack(spacing: 3) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(Group { if let img = tiles.value[t] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(Color.secondary.opacity(0.25)) } })
                    .clipped().cornerRadius(5)
                Text(Self.templateName(t)).font(.system(size: 10)).lineLimit(1)
            }
        }.buttonStyle(.plain).help(Self.templateName(t)).accessibilityLabel(Self.templateName(t))
    }

    private func loadTiles() async {
        var out: [TextTemplate: NSImage] = [:]
        for t in TextTemplate.allCases { if let cg = TextPreview.image(for: t) { out[t] = NSImage(cgImage: cg, size: .zero) } }
        tiles.value = out
    }

    // MARK: The selected item

    @ViewBuilder private func editor(_ o: TextOverlay) -> some View {
        ToolCard(title: o.isShape ? L("Shape") : L("Text"), icon: "slider.horizontal.3") {
            if o.isShape { shapeControls(o) } else { textControls(o) }
            if !session.isPhoto { timingControls(o) }
        }
        ToolCard(title: L("Position and size"), icon: "arrow.up.left.and.arrow.down.right") { placementControls(o) }
        if !session.isPhoto {
            ToolCard(title: L("Animation"), icon: "sparkles") { animationControls(o) }
            ToolCard(title: L("Keyframes"), icon: "diamond") { keyframeControls(o) }
        }
    }

    private func slider(_ title: String, _ o: TextOverlay, _ key: String, range: ClosedRange<Double>, format: String = "%.2f", get: @escaping (TextOverlay) -> Double, set: @escaping (inout TextOverlay, Double) -> Void) -> some View {
        SliderRow(title: title, value: Binding(get: { get(o) }, set: { v in update(o.id, title, key: key) { set(&$0, v) } }), range: range, format: format, onDone: { session.endCoalescing() })
    }

    @ViewBuilder private func textControls(_ o: TextOverlay) -> some View {
        // Another ready-made look for this text (the library's styles add a new one; dropping one on a text on the picture restyles it too).
        Menu {
            ForEach(TextTemplate.allCases, id: \.self) { t in
                Button(Self.templateName(t)) { update(o.id, LF("Text style %@", Self.templateName(t))) { t.apply(to: &$0) } }
            }
        } label: { Label(L("Style"), systemImage: "textformat") }
        .fixedSize()
        TextField(L("Text"), text: Binding(get: { o.text }, set: { t in update(o.id, "Edit text", key: "text") { $0.text = t } })).textFieldStyle(.roundedBorder)
        Picker(L("Font"), selection: Binding(get: { o.fontName }, set: { f in update(o.id, "Text font") { $0.fontName = f } })) {
            ForEach(Self.fonts, id: \.0) { Text($0.1).tag($0.0) }
            if !Self.fonts.contains(where: { $0.0 == o.fontName }) { Text(o.fontName).tag(o.fontName) }
        }
        slider(L("Size"), o, "size", range: 0.02...0.3, get: { $0.sizeFraction }, set: { $0.sizeFraction = $1 })
        HStack {
            ColorPicker(L("Colour"), selection: Binding(get: { color(o.colorHex) }, set: { c in update(o.id, "Text colour", key: "col") { $0.colorHex = OverlayRendererBridge.hex(c) } }))
            Toggle(L("Background"), isOn: Binding(get: { o.backgroundHex != nil }, set: { on in update(o.id, "Text background") { $0.backgroundHex = on ? "#000000" : nil } }))
        }
        if o.backgroundHex != nil {
            ColorPicker(L("Background colour"), selection: Binding(get: { color(o.backgroundHex ?? "#000000") }, set: { c in update(o.id, "Background colour", key: "bgc") { $0.backgroundHex = OverlayRendererBridge.hex(c) } }))
        }
        Picker(L("Align"), selection: Binding(get: { o.alignment }, set: { a in update(o.id, "Text alignment") { $0.alignment = a } })) {
            Text(L("Left")).tag(TextAlignmentChoice.left); Text(L("Centre")).tag(TextAlignmentChoice.center); Text(L("Right")).tag(TextAlignmentChoice.right)
        }.pickerStyle(.segmented)
        let f = o.flair ?? TextFlair()
        Toggle(L("Outline"), isOn: Binding(get: { f.outlineWidth != 0 && (f.outlineHex != nil || o.backgroundHex == nil) }, set: { on in
            update(o.id, "Text outline") { var fl = $0.flair ?? TextFlair(); fl.outlineWidth = on ? 0.06 : 0; if on, fl.outlineHex == nil { fl.outlineHex = "#000000" }; $0.flair = fl }
        }))
        if f.outlineWidth != 0 && (f.outlineHex != nil || o.backgroundHex == nil) {
            ColorPicker(L("Outline colour"), selection: Binding(get: { color(f.outlineHex ?? "#000000") }, set: { c in update(o.id, "Outline colour", key: "olc") { var fl = $0.flair ?? TextFlair(); fl.outlineHex = OverlayRendererBridge.hex(c); $0.flair = fl } }))
            slider(L("Outline width"), o, "olw", range: 0.01...0.2, get: { $0.flair?.outlineWidth ?? 0.06 }, set: { var fl = $0.flair ?? TextFlair(); fl.outlineWidth = $1; $0.flair = fl })
        }
        Toggle(L("Shadow or glow"), isOn: Binding(get: { f.shadow }, set: { on in update(o.id, "Text shadow") { var fl = $0.flair ?? TextFlair(); fl.shadow = on; $0.flair = fl } }))
        if f.shadow { ColorPicker(L("Shadow colour"), selection: Binding(get: { color(f.shadowHex) }, set: { c in update(o.id, "Shadow colour", key: "shc") { var fl = $0.flair ?? TextFlair(); fl.shadowHex = OverlayRendererBridge.hex(c); $0.flair = fl } })) }
        slider(L("Letter spacing"), o, "ls", range: 0...0.6, get: { $0.flair?.letterSpacing ?? 0 }, set: { var fl = $0.flair ?? TextFlair(); fl.letterSpacing = $1; $0.flair = fl })
        Toggle(L("All capitals"), isOn: Binding(get: { f.uppercase }, set: { on in update(o.id, "Capitals") { var fl = $0.flair ?? TextFlair(); fl.uppercase = on; $0.flair = fl } }))
    }

    @ViewBuilder private func shapeControls(_ o: TextOverlay) -> some View {
        if let sh = o.shape {
            Picker(L("Shape"), selection: Binding(get: { sh.kind }, set: { k in update(o.id, "Shape kind") { $0.shape?.kind = k } })) {
                ForEach(ShapeKind.allCases, id: \.self) { Text(Self.shapeName($0)).tag($0) }
            }
            HStack {
                Toggle(L("Fill"), isOn: Binding(get: { sh.fillHex != nil }, set: { on in update(o.id, "Shape fill") { $0.shape?.fillHex = on ? "#FFD60A" : nil } }))
                if sh.fillHex != nil { ColorPicker("", selection: Binding(get: { color(sh.fillHex ?? "#FFD60A") }, set: { c in update(o.id, "Shape colour", key: "shf") { $0.shape?.fillHex = OverlayRendererBridge.hex(c) } })).labelsHidden() }
            }
            HStack {
                Toggle(L("Outline"), isOn: Binding(get: { sh.strokeHex != nil }, set: { on in update(o.id, "Shape outline") { $0.shape?.strokeHex = on ? "#FFFFFF" : nil } }))
                if sh.strokeHex != nil { ColorPicker("", selection: Binding(get: { color(sh.strokeHex ?? "#FFFFFF") }, set: { c in update(o.id, "Outline colour", key: "shs") { $0.shape?.strokeHex = OverlayRendererBridge.hex(c) } })).labelsHidden() }
            }
            if sh.strokeHex != nil { slider(L("Outline width"), o, "shw", range: 0.002...0.03, format: "%.3f", get: { $0.shape?.strokeWidth ?? 0.006 }, set: { $0.shape?.strokeWidth = $1 }) }
            slider(L("Width"), o, "shwd", range: 0.02...1, get: { $0.shape?.width ?? 0.2 }, set: { $0.shape?.width = $1 })
            slider(L("Height"), o, "shht", range: 0.005...1, format: "%.3f", get: { $0.shape?.height ?? 0.2 }, set: { $0.shape?.height = $1 })
        }
    }

    @ViewBuilder private func timingControls(_ o: TextOverlay) -> some View {
        HStack {
            Button(L("Start here")) { update(o.id, "Start") { $0.start = session.player.currentTime; if $0.end <= $0.start { $0.end = $0.start + MediaTime(seconds: 1) } } }
            Button(L("End here")) { update(o.id, "End") { if session.player.currentTime > $0.start { $0.end = session.player.currentTime } } }
        }.font(.caption)
        slider(L("Fade (s)"), o, "fade", range: 0...1, get: { $0.fade }, set: { $0.fade = $1 })
    }

    @ViewBuilder private func placementControls(_ o: TextOverlay) -> some View {
        slider(L("Horizontal position"), o, "x", range: 0...1, get: { $0.x }, set: { $0.x = $1 })
        slider(L("Vertical position"), o, "y", range: 0...1, get: { $0.y }, set: { $0.y = $1 })
        slider(L("Scale"), o, "scale", range: 0.2...4, get: { $0.scale ?? 1 }, set: { $0.scale = $1 })
        slider(L("Rotation (°)"), o, "rot", range: -180...180, format: "%.0f", get: { $0.rotation ?? 0 }, set: { $0.rotation = $1 })
        if !session.isPhoto { Text(L("These are the values before any animation or keyframes.")).font(.caption).foregroundColor(.secondary) }
    }

    @ViewBuilder private func animationControls(_ o: TextOverlay) -> some View {
        let kinds = o.isShape ? ElementAnimationKind.allCases.filter { $0 != .typewriter } : ElementAnimationKind.allCases
        Picker(L("Arrives with"), selection: Binding(get: { o.animationIn?.kind ?? .none }, set: { k in update(o.id, "Animation in") { $0.animationIn = k == .none ? nil : ElementAnimation(kind: k, duration: $0.animationIn?.duration ?? 0.5) } })) {
            ForEach(kinds, id: \.self) { Text(Self.animationName($0)).tag($0) }
        }
        if let a = o.animationIn { slider(L("Arrival length (s)"), o, "ain", range: 0.1...3, get: { _ in a.duration }, set: { $0.animationIn?.duration = $1 }) }
        Picker(L("Leaves with"), selection: Binding(get: { o.animationOut?.kind ?? .none }, set: { k in update(o.id, "Animation out") { $0.animationOut = k == .none ? nil : ElementAnimation(kind: k, duration: $0.animationOut?.duration ?? 0.5) } })) {
            ForEach(kinds.filter { $0 != .typewriter }, id: \.self) { Text(Self.animationName($0)).tag($0) }
        }
        if let a = o.animationOut { slider(L("Exit length (s)"), o, "aout", range: 0.1...3, get: { _ in a.duration }, set: { $0.animationOut?.duration = $1 }) }
    }

    @ViewBuilder private func keyframeControls(_ o: TextOverlay) -> some View {
        let local = max(0, (session.player.currentTime - o.start).seconds)
        let ks = (o.keyframes ?? []).sorted { $0.time < $1.time }
        Text(ks.isEmpty ? L("Add a keyframe, then move the playhead and add another: the item moves, grows or turns between them.") : L("Values change in a straight line between keyframes."))
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(L("Add Keyframe at Playhead")) {
                let now = ElementAnimator.state(of: o, at: session.player.currentTime.seconds) ?? ElementState(x: o.x, y: o.y, scale: o.scale ?? 1, rotation: o.rotation ?? 0, alpha: 1, reveal: 1)
                update(o.id, "Add keyframe") { $0.keyframes = ElementAnimator.setting($0.keyframes ?? [], at: local, to: now) }
            }.disabled(session.player.currentTime < o.start || session.player.currentTime >= o.end)
            if !ks.isEmpty { Button(L("Clear Animation")) { update(o.id, "Clear keyframes") { $0.keyframes = nil } } }
        }.font(.caption)
        ForEach(ks) { k in
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill").font(.caption2).foregroundColor(.accentColor).accessibilityHidden(true)
                Text(Timecode.format(o.start + MediaTime(seconds: k.time))).font(.caption.monospacedDigit())
                Text(String(format: "x %.2f y %.2f  %.1f×  %.0f°", k.x, k.y, k.scale, k.rotation)).font(.caption2).foregroundColor(.secondary)
                Spacer()
                EasingMenu(easing: Binding(get: { k.easing }, set: { e in update(o.id, "Keyframe easing") { if let i = $0.keyframes?.firstIndex(where: { $0.id == k.id }) { $0.keyframes?[i].easing = e } } }))
                Button { Task { await session.player.seek(to: o.start + MediaTime(seconds: k.time)) } } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).accessibilityLabel(L("Go to keyframe"))
                Button { update(o.id, "Delete keyframe") { $0.keyframes?.removeAll { $0.id == k.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete keyframe"))
            }
        }
    }
}
