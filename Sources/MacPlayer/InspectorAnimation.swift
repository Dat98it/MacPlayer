import SwiftUI
import MacPlayerCore

/// A small menu for how the values move on from a keyframe: straight, slow start, slow end, overshoot, bounce.
struct EasingMenu: View {
    @Binding var easing: Easing

    static func name(_ e: Easing) -> String {
        switch e {
        case .linear: return L("Linear"); case .easeIn: return L("Ease in"); case .easeOut: return L("Ease out"); case .easeInOut: return L("Ease in and out")
        case .overshoot: return L("Overshoot"); case .bounce: return L("Bounce")
        }
    }

    var body: some View {
        Picker("", selection: $easing) {
            ForEach(Easing.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.mini).fixedSize()
        .help(L("How the values move on from this keyframe to the next"))
        .accessibilityLabel(L("Easing"))
    }
}

/// How a layer arrives and leaves: a move, a zoom, a pop... and how long it takes.
struct ArrivalControls: View {
    var title: String
    var animation: ElementAnimation?
    var set: (ElementAnimation?) -> Void

    static let kinds: [ElementAnimationKind] = ElementAnimationKind.allCases.filter { $0 != .typewriter }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Picker("", selection: Binding(get: { animation?.kind ?? .none },
                                              set: { k in set(k == .none ? nil : ElementAnimation(kind: k, duration: animation?.duration ?? 0.5)) })) {
                    ForEach(Self.kinds, id: \.self) { Text(TextPane.animationName($0)).tag($0) }
                }.pickerStyle(.menu).labelsHidden().fixedSize().accessibilityLabel(title)
            }
            if let a = animation {
                SliderRow(title: L("Time (s)"), value: Binding(get: { a.duration }, set: { v in set(ElementAnimation(kind: a.kind, duration: v)) }), range: 0.1...2, format: "%.1f")
            }
        }
    }
}

/// "Motion" (0.16.5): a movement that keeps going while a text, shape, sticker or picture is on screen — it beats, bounces, floats,
/// swings, spins, shakes, blinks. One click on a tile turns it on (again: off); speed and strength below; "Play it" shows it on the picture.
struct LoopMotionControls: View {
    var loop: ElementLoop?
    var set: (ElementLoop?, _ coalesce: Bool) -> Void
    /// Plays the thing from its start, to see the motion.
    var preview: () -> Void

    static func name(_ k: ElementLoopKind) -> String {
        switch k {
        case .pulse: return L("Pulse"); case .heartbeat: return L("Heartbeat"); case .breathe: return L("Breathe"); case .bounce: return L("Bounce")
        case .float: return L("Float"); case .sway: return L("Sway"); case .swing: return L("Swing"); case .wobble: return L("Wobble")
        case .spin: return L("Spin"); case .shake: return L("Shake"); case .blink: return L("Blink"); case .flash: return L("Flash"); case .tada: return L("Tada")
        }
    }
    static func icon(_ k: ElementLoopKind) -> String {
        switch k {
        case .pulse: return "circle.circle"; case .heartbeat: return "heart.fill"; case .breathe: return "wind"; case .bounce: return "arrow.up.and.down"
        case .float: return "cloud"; case .sway: return "arrow.left.and.right"; case .swing: return "metronome"; case .wobble: return "waveform.path"
        case .spin: return "arrow.clockwise"; case .shake: return "iphone.radiowaves.left.and.right"; case .blink: return "eye"; case .flash: return "bolt"; case .tada: return "party.popper"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                tile(nil)
                ForEach(ElementLoopKind.allCases, id: \.self) { tile($0) }
            }
            if let l = loop {
                SliderRow(title: L("Speed (s per round)"), value: Binding(get: { l.period }, set: { v in var n = l; n.period = v; set(n.clamped, true) }), range: 0.2...5, format: "%.1f")
                SliderRow(title: L("Strength"), value: Binding(get: { l.strength }, set: { v in var n = l; n.strength = v; set(n.clamped, true) }), range: 0.2...2.5, format: "%.1f")
                HStack {
                    Button { preview() } label: { Label(L("Play It"), systemImage: "play.fill") }.controlSize(.small)
                    Spacer()
                    Button(L("Reset")) { set(ElementLoop(kind: l.kind), false) }.controlSize(.small)
                }
            }
            Text(L("Keeps moving while it is on screen; it adds to how it arrives and leaves. While the video is paused it stands still."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ k: ElementLoopKind?) -> some View {
        let selected = loop?.kind == k
        return Button { set(k.map { ElementLoop(kind: $0, period: loop?.kind == $0 ? loop?.period : nil, strength: loop?.strength ?? 1) }, false) } label: {
            VStack(spacing: 3) {
                Image(systemName: k.map(Self.icon) ?? "nosign").font(.system(size: 15))
                Text(k.map(Self.name) ?? L("None")).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(k.map(Self.name) ?? L("No motion")).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
