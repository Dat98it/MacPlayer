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

// MARK: Tabs inside a settings pane (0.17.1)

/// One group of settings in a pane, shown as a tab: a long pane of stacked cards became one card at a time.
struct PaneSection: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    /// Something in it differs from the defaults (a dot on the tab).
    var changed = false
}

/// The tabs of a pane: an icon over a short name, the chosen one in the accent colour, wrapping onto a second line when narrow.
struct SectionTabBar: View {
    let sections: [PaneSection]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4)], spacing: 4) {
            ForEach(sections) { s in
                let on = s.id == selection
                Button { selection = s.id } label: {
                    VStack(spacing: 2) {
                        Image(systemName: s.icon).font(.system(size: 13, weight: on ? .semibold : .regular))
                        Text(s.title).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundColor(on ? .white : .primary)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor : Color.secondary.opacity(0.12)))
                    .overlay(alignment: .topTrailing) {
                        if s.changed { Circle().fill(on ? Color.white : Color.accentColor).frame(width: 6, height: 6).padding(4).accessibilityHidden(true) }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(s.title)
                .accessibilityLabel(s.changed ? s.title + ", " + L("changed") : s.title)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(L("Settings groups"))
    }
}
