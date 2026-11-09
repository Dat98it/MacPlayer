import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// The look of the picture beyond plain colour: ready-made filters (each shown on the frame at the playhead), sharpening, blur,
/// vignette, and a blurred backdrop for video that does not fill the frame.
struct EffectsPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var sample = Box<CGImage?>(nil)
    @StateObject private var tiles = Box<[FilterPreset: NSImage]>([:])
    @StateObject private var sampleKey = Box<String>("")

    private var effects: LookEffects { session.project.activeLook.effects }

    private func set(_ label: String, key: String? = nil, _ change: @escaping (inout LookEffects) -> Void) -> Void {
        session.editEffects(label, coalesce: key, change)
    }

    private func slider(_ title: String, _ key: String, _ kp: WritableKeyPath<LookEffects, Double>) -> some View {
        SliderRow(title: title, value: Binding(get: { session.project.activeLook.effects[keyPath: kp] }, set: { v in session.editEffects(title, coalesce: key) { $0[keyPath: kp] = v } }),
                  range: 0...1, onDone: { session.endCoalescing() })
    }

    static func name(_ p: FilterPreset) -> String {
        switch p {
        case .none: return L("Original")
        case .vivid: return L("Vivid")
        case .warm: return L("Warm")
        case .cool: return L("Cool")
        case .cinematic: return L("Cinematic")
        case .vintage: return L("Vintage")
        case .fade: return L("Faded")
        case .film: return L("Film")
        case .mono: return L("Mono")
        case .noir: return L("Noir")
        case .dramatic: return L("Dramatic")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.info?.primaryVideo == nil { Text(L("This file has no picture.")).foregroundColor(.secondary) } else {
                ToolCard(title: L("Filters"), icon: "camera.filters") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(FilterPreset.allCases, id: \.self) { p in tile(p) }
                    }
                    if effects.filter != .none {
                        SliderRow(title: L("Amount"), value: Binding(get: { session.project.activeLook.effects.filterAmount }, set: { v in session.editEffects(L("Amount"), coalesce: "fx-amount") { $0.filterAmount = v } }),
                                  range: 0...1, format: "%.2f", onDone: { session.endCoalescing() })
                    }
                }
                ToolCard(title: L("Adjust"), icon: "slider.horizontal.3") {
                    slider(L("Sharpen"), "fx-sharpen", \.sharpen)
                    slider(L("Blur"), "fx-blur", \.blur)
                    slider(L("Vignette"), "fx-vignette", \.vignette)
                }
                ToolCard(title: L("Blurred background"), icon: "rectangle.center.inset.filled") {
                    Toggle(L("Fill the empty bars with the blurred video"), isOn: Binding(get: { session.project.activeLook.effects.blurBackground }, set: { on in session.editEffects(L("Blurred background")) { $0.blurBackground = on } }))
                    if effects.blurBackground { slider(L("Blur amount"), "fx-bgblur", \.blurBackgroundAmount) }
                    Text(L("Shows where the picture does not fill the frame: for example a landscape video on a 9:16 canvas. Choose the canvas in Picture ▸ Canvas, with “Fit”."))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button(L("Reset all effects")) { session.edit("Reset effects") { $0.activeLook.effects = LookEffects() } }.font(.caption).disabled(effects == LookEffects())
            }
        }
        .task(id: session.project.activeClipID) { await loadSample() }
    }

    private func tile(_ p: FilterPreset) -> some View {
        let selected = effects.filter == p
        return Button { set(LF("Filter %@", Self.name(p))) { $0.filter = p; if p != .none && $0.filterAmount == 0 { $0.filterAmount = 1 } } } label: {
            VStack(spacing: 3) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(Group { if let img = tiles.value[p] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(Color.secondary.opacity(0.25)) } })
                    .clipped().cornerRadius(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0))
                Text(Self.name(p)).font(.system(size: 10, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
        }
        .buttonStyle(.plain).help(Self.name(p)).accessibilityLabel(Self.name(p)).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// One real frame of the video, with each filter drawn on it, so the choice is made by looking.
    private func loadSample() async {
        var frame: CGImage?
        if session.sourceURL != nil {
            let t = min(max(session.player.currentTime, .zero), session.duration)
            frame = await session.stillImage(at: t, maxSize: CGSize(width: 180, height: 120))
        } else if let clip = session.project.timeline.first(where: { $0.id == session.project.activeClipID }) ?? session.project.timeline.first,
                  let src = session.project.sources.first(where: { $0.id == clip.sourceID }) {
            let mid = clip.sourceStart + MediaTime(seconds: min(1, clip.sourceSpan.duration.seconds / 2), timescale: 600)
            frame = try? await FrameGrabber.image(url: URL(fileURLWithPath: src.path), at: mid, accuracy: .nearest, maxSize: CGSize(width: 180, height: 120))
        }
        guard let frame else { return }
        var out: [FilterPreset: NSImage] = [:]
        for p in FilterPreset.allCases {
            var e = LookEffects(); e.filter = p
            if let cg = EffectPreview.image(from: frame, effects: e) { out[p] = NSImage(cgImage: cg, size: .zero) }
        }
        tiles.value = out
    }
}
