import SwiftUI
import AppKit

/// A command that is always on show: its picture above its name, like a toolbar button. Used for the playlist commands and the
/// editing tools, so nothing has to be looked for inside a menu.
struct PanelButtonLabel: View {
    let title: String
    let icon: String
    var tint: Color?
    var selected = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 14)).frame(height: 16)
            Text(title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .foregroundColor(selected ? .white : (tint ?? .primary))
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.secondary.opacity(0.14)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    var help: String?
    var tint: Color?
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) { PanelButtonLabel(title: title, icon: icon, tint: tint, selected: selected) }
            .buttonStyle(.plain)
            .help(help ?? title)
            .accessibilityLabel(help ?? title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The columns for a row of panel buttons: as many as fit, never narrower than `minimum`.
func panelColumns(_ minimum: CGFloat = 62) -> [GridItem] { [GridItem(.adaptive(minimum: minimum), spacing: 4)] }

extension InspectorTab {
    var icon: String {
        switch self {
        case .clips: return "scissors"
        case .layers: return "square.3.layers.3d"
        case .picture: return "crop.rotate"
        case .color: return "slider.horizontal.below.sun.max"
        case .mask: return "person.crop.rectangle"
        case .effects: return "wand.and.stars"
        case .timing: return "speedometer"
        case .transitions: return "rectangle.2.swap"
        case .audio: return "speaker.wave.2"
        case .text: return "textformat"
        case .subtitles: return "captions.bubble"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// A titled card for one group of controls in the editing panel: a small picture and a name, then the controls, with an optional reset.
struct ToolCard<Content: View>: View {
    let title: String
    let icon: String
    var onReset: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(.accentColor).frame(width: 18)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let onReset { Button(L("Reset"), action: onReset).buttonStyle(.borderless).font(.caption).foregroundColor(.secondary) }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Gives every group of controls in the editing panel the same look as `ToolCard`: a bold title above the controls on a soft rounded card.
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.subheadline.weight(.semibold))
            configuration.content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
    }
}
