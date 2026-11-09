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
