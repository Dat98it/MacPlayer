import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// The Cut-out tool: take the background away from a person or subject, make a key colour see-through, or keep only a shape, and say what
/// fills the parts that are gone. For video and photos.
struct MaskPane: View {
    @ObservedObject var session: EditorSession

    private var look: VideoLook { session.project.activeLook }

    private func editLook(_ label: String, coalesce: String? = nil, _ change: @escaping (inout VideoLook) -> Void) {
        session.edit(label, coalesce: coalesce) { change(&$0.activeLook) }
    }

    var body: some View {
        let l = look
        let sections = [PaneSection(id: "subject", title: L("Person"), icon: "person.crop.rectangle", changed: l.isolateSubject),
                        PaneSection(id: "green", title: L("Green screen"), icon: "rectangle.on.rectangle.angled", changed: l.chromaKey != nil),
                        PaneSection(id: "shape", title: L("Mask shape"), icon: "circle.dashed", changed: l.mask != nil),
                        PaneSection(id: "backdrop", title: L("Backdrop"), icon: "paintbrush", changed: l.backdropHex != nil)]
        let tab = session.paneTab("mask", sections).wrappedValue
        VStack(alignment: .leading, spacing: 10) {
            SectionTabBar(sections: sections, selection: session.paneTab("mask", sections))
            if tab == "subject" {
            ToolCard(title: L("Remove background"), icon: "person.crop.rectangle", onReset: l.isolateSubject ? { editLook("Keep background") { $0.isolateSubject = false } } : nil) {
                Toggle(L("Keep only the person or subject"), isOn: Binding(get: { look.isolateSubject }, set: { on in editLook("Remove background") { $0.isolateSubject = on } }))
                Text(session.isPhoto ? L("Finds the main subject of the photo on this Mac and removes everything behind it.")
                                     : L("Finds the people in the video on this Mac and removes everything behind them. The preview is a little rougher than the exported video, and playback may be slower while it is on."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if l.isolateSubject { Text(L("If nothing is found in a picture, it is left as it is.")).font(.caption).foregroundColor(.secondary) }
            }
            }
            if tab == "green" {
            ToolCard(title: L("Green screen"), icon: "rectangle.on.rectangle.angled", onReset: l.chromaKey != nil ? { editLook("Remove chroma key") { $0.chromaKey = nil } } : nil) {
                ChromaControls(key: l.chromaKey,
                               change: { label, coalesce, f in editLook(label, coalesce: coalesce) { var k = $0.chromaKey; f(&k); $0.chromaKey = k } },
                               done: { session.endCoalescing() })
            }
            }
            if tab == "shape" {
            ToolCard(title: L("Shape"), icon: "circle.dashed", onReset: l.mask != nil ? { editLook("Remove mask") { $0.mask = nil } } : nil) {
                MaskControls(spec: l.mask,
                             change: { label, coalesce, f in editLook(label, coalesce: coalesce) { var m = $0.mask; f(&m); $0.mask = m } },
                             done: { session.endCoalescing() })
            }
            }
            if tab == "backdrop" && !l.cutsOut {
                Text(L("Turn on one of the cut-outs (Person, Green screen, Shape) first: this is what shows where the picture is taken away.")).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if tab == "backdrop" && l.cutsOut {
                ToolCard(title: L("What shows instead"), icon: "paintbrush", onReset: l.backdropHex != nil ? { editLook("Black backdrop") { $0.backdropHex = nil } } : nil) {
                    Text(L("The parts that are taken away show this:")).font(.caption).foregroundColor(.secondary)
                    HStack {
                        ColorPicker(L("Colour"), selection: Binding(get: { Color(hex: look.backdropHex ?? "#000000") }, set: { c in editLook("Backdrop colour", coalesce: "backdrop") { $0.backdropHex = OverlayRendererBridge.hex(c) } }))
                        Button(L("Black")) { editLook("Black backdrop") { $0.backdropHex = nil } }.font(.caption)
                        Button(L("White")) { editLook("White backdrop") { $0.backdropHex = "#FFFFFF" } }.font(.caption)
                    }
                    Toggle(L("Blurred copy of the picture"), isOn: Binding(get: { look.effects.blurBackground }, set: { on in session.editEffects("Blurred background") { $0.blurBackground = on } }))
                    Text(L("A colour set above wins over the blurred copy.")).font(.caption).foregroundColor(.secondary)
                }
            }
            Text(L("Layers (Picture in Picture) have their own cut-out, shape and blend controls in the Layers tool.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { devSample() }
    }

    /// Development aid: MACPLAYER_DEV_MASK=1 puts a heart-shaped mask on a blue backdrop (to look at the tool with something in it).
    private func devSample() {
        guard ProcessInfo.processInfo.environment["MACPLAYER_DEV_MASK"] != nil, look.mask == nil else { return }
        editLook("sample") { l in
            var m = MaskSpec(shape: .heart); m.width = 0.7; m.height = 0.8; m.feather = 0.15
            l.mask = m; l.backdropHex = "#2B6CB0"
        }
    }
}

/// Make a colour see-through: used for the main picture and for a layer.
struct ChromaControls: View {
    var key: ChromaKey?
    var change: (String, String?, @escaping (inout ChromaKey?) -> Void) -> Void
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Make a colour see-through (chroma key)"), isOn: Binding(get: { key != nil }, set: { on in change("Chroma key", nil) { $0 = on ? ChromaKey() : nil } }))
            if let k = key {
                HStack {
                    ColorPicker(L("Colour to remove"), selection: Binding(get: { Color(hex: k.colorHex) }, set: { col in change("Chroma colour", "ck-colour") { $0?.colorHex = OverlayRendererBridge.hex(col) } }))
                    Button(L("Green")) { change("Chroma colour", nil) { $0?.colorHex = "#00FF00" } }.font(.caption)
                    Button(L("Blue")) { change("Chroma colour", nil) { $0?.colorHex = "#0000FF" } }.font(.caption)
                }
                SliderRow(title: L("Tolerance"), value: Binding(get: { k.tolerance }, set: { v in change("Chroma tolerance", "ck-tol") { $0?.tolerance = v } }), range: 0...1, format: "%.2f", onDone: done)
                SliderRow(title: L("Edge softness"), value: Binding(get: { k.softness }, set: { v in change("Chroma softness", "ck-soft") { $0?.softness = v } }), range: 0...1, format: "%.2f", onDone: done)
                Text(L("Raise the tolerance until the backdrop disappears; keep the softness low for a clean edge.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Choosing and shaping a mask: used for the main picture and for a layer.
struct MaskControls: View {
    var spec: MaskSpec?
    var change: (String, String?, @escaping (inout MaskSpec?) -> Void) -> Void
    var done: () -> Void

    static func name(_ s: MaskShape) -> String {
        switch s { case .ellipse: return L("Circle"); case .rectangle: return L("Rectangle"); case .roundedRectangle: return L("Rounded"); case .heart: return L("Heart"); case .star: return L("Star"); case .split: return L("Half") }
    }
    static func icon(_ s: MaskShape) -> String {
        switch s { case .ellipse: return "circle"; case .rectangle: return "rectangle"; case .roundedRectangle: return "app"; case .heart: return "heart"; case .star: return "star"; case .split: return "rectangle.lefthalf.filled" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                tile(title: L("None"), icon: "nosign", selected: spec == nil) { change("Remove mask", nil) { $0 = nil } }
                ForEach(MaskShape.allCases, id: \.self) { shape in
                    tile(title: Self.name(shape), icon: Self.icon(shape), selected: spec?.shape == shape) {
                        change("Mask \(Self.name(shape))", nil) { if var m = $0 { m.shape = shape; $0 = m } else { $0 = MaskSpec(shape: shape) } }
                    }
                }
            }
            if let m = spec {
                slider(L("Width"), "mk-w", m.width, 0.05...2) { $0.width = $1 }
                slider(L("Height"), "mk-h", m.height, 0.05...2) { $0.height = $1 }
                slider(L("Horizontal position"), "mk-x", m.centerX, 0...1) { $0.centerX = $1 }
                slider(L("Vertical position"), "mk-y", m.centerY, 0...1) { $0.centerY = $1 }
                slider(L("Turn (degrees)"), "mk-r", m.rotation, -180...180, format: "%.0f") { $0.rotation = $1 }
                slider(L("Soft edge"), "mk-f", m.feather, 0...1) { $0.feather = $1 }
                Toggle(L("Hide the inside instead"), isOn: Binding(get: { m.invert }, set: { v in change("Invert mask", nil) { $0?.invert = v } }))
            } else {
                Text(L("Pick a shape to keep only that part of the picture.")).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func slider(_ title: String, _ key: String, _ value: Double, _ range: ClosedRange<Double>, format: String = "%.2f", set: @escaping (inout MaskSpec, Double) -> Void) -> some View {
        SliderRow(title: title, value: Binding(get: { value }, set: { v in change(title, key) { if var m = $0 { set(&m, v); $0 = m } } }), range: range, format: format, onDone: done)
    }

    private func tile(title: String, icon: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16)).frame(height: 20)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
