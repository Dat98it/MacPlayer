import SwiftUI
import AppKit
import MacPlayerCore

/// The right panel of the video editor: the settings of what is selected on the timeline (a clip, a layer, a text, a sound), or of the
/// whole project when nothing is. Only the settings that fit the selection are offered, so nothing asks to "select a clip first".
struct PropertiesPanel: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        let sel = session.selection
        // A photo project has no timeline to select from: all its tools, always.
        let tabs = session.isPhoto ? InspectorTab.tabs(for: .photo).filter { $0 != .export } : InspectorTab.propertyTabs(for: sel)
        let current = tabs.contains(session.activeTool) ? session.activeTool : tabs[0]
        VStack(spacing: 0) {
            header(sel)
            if tabs.count > 1 {
                // Every setting in sight: the chips wrap onto a second line rather than scrolling out of view.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 5)], spacing: 5) {
                    ForEach(tabs, id: \.self) { t in
                        Button { session.activeTool = t } label: {
                            Text(Self.title(t, for: sel)).font(.system(size: 12, weight: current == t ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .foregroundColor(current == t ? .white : .primary)
                                .background(Capsule().fill(current == t ? Color.accentColor : Color.secondary.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(current == t ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .accessibilityElement(children: .contain).accessibilityLabel(L("Settings"))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch current {
                    case .clips: ProjectOverviewPane(session: session)
                    case .layers: LayersPane(session: session)
                    case .picture: PicturePane(session: session)
                    case .color: ColorPane(session: session)
                    case .mask: MaskPane(session: session)
                    case .effects: EffectsPane(session: session)
                    case .timing: TimingPane(session: session)
                    case .transitions: TransitionsPane(session: session)
                    case .audio: AudioPane(session: session)
                    case .text: TextPane(session: session)
                    case .subtitles: SubtitlesPane(session: session)
                    case .export: if session.isPhoto { PhotoExportPane(session: session) } else { ExportPane(session: session) }
                    }
                }
                .padding(12)
            }
            .groupBoxStyle(CardGroupBoxStyle())
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func header(_ sel: EditSelection) -> some View {
        let (icon, title, subtitle) = describe(sel)
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            if !session.canvasSelection.isEmpty {
                // Things on the picture: group them, lock them.
                if session.canvasSelection.count > 1 {
                    Button { session.groupCanvas() } label: { Image(systemName: "rectangle.3.group") }.buttonStyle(.borderless).help(L("Group (⌘G)")).accessibilityLabel(L("Group"))
                }
                if session.canvasHasGroup {
                    Button { session.ungroupCanvas() } label: { Image(systemName: "rectangle.3.group.fill") }.buttonStyle(.borderless).help(L("Ungroup (⇧⌘G)")).accessibilityLabel(L("Ungroup"))
                }
                Button { session.toggleLockCanvas() } label: { Image(systemName: session.canvasAllLocked ? "lock.fill" : "lock.open") }.buttonStyle(.borderless)
                    .help(session.canvasAllLocked ? L("Unlock (⌘L)") : L("Lock: it can no longer be moved or deleted on the picture (⌘L)")).accessibilityLabel(session.canvasAllLocked ? L("Unlock") : L("Lock"))
            }
            if sel != .none && (!session.isPhoto || !session.canvasSelection.isEmpty) {
                Button { session.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(.borderless).help(L("Duplicate")).accessibilityLabel(L("Duplicate"))
                Button { session.deleteSelection() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("Delete (⌫)")).accessibilityLabel(L("Delete"))
                Button { session.select(.none) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.borderless).help(L("Deselect (Esc)")).accessibilityLabel(L("Deselect"))
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
    }

    private func describe(_ sel: EditSelection) -> (String, String, String?) {
        let p = session.project
        if session.canvasSelection.count > 1 {
            return ("square.on.square.dashed", LF("%d selected", session.canvasSelection.count), session.canvasHasGroup ? L("A group: moved and selected together") : L("Drag one of them to move them all"))
        }
        if session.isPhoto { return ("photo", L("Photo"), p.sources.first.map { PathUtil.fileName(of: $0.path) } ?? L("No photo yet")) }
        switch sel {
        case .clip(let id):
            let i = p.timeline.firstIndex { $0.id == id } ?? 0
            let c = p.timeline[i]
            let name = c.name.isEmpty ? PathUtil.fileName(of: p.source(c.sourceID)?.mediaPath ?? "") : c.name
            return ("film", LF("Clip %d", i + 1), "\(name) · \(Format.duration(c.duration))")
        case .layer(let id):
            let c = p.overlayClips.first { $0.id == id }
            return (c?.isVideo == true ? "rectangle.inset.filled.on.rectangle" : "photo", L("Layer"), c?.name)
        case .text(let id):
            let o = p.overlays.first { $0.id == id }
            return (o?.shape != nil ? "star.square" : "textformat", o?.shape != nil ? L("Shape") : L("Text"), o.map { $0.text.isEmpty ? nil : $0.text } ?? nil)
        case .sound(let id):
            let c = p.soundClips.first { $0.id == id }
            return ("music.note", L("Sound"), c?.name)
        case .none:
            return ("square.stack.3d.up", L("Project"), LF("%d clips · %@", p.timeline.count, Format.duration(p.timelineDuration)))
        }
    }

    static func title(_ t: InspectorTab, for sel: EditSelection) -> String {
        switch t {
        case .clips: return L("Overview")
        case .picture: return L("Basic")
        case .timing: return L("Speed")
        case .mask: return L("Cut-out")
        default: return t.title
        }
    }
}

/// What the project holds, when nothing is selected: its clips (click one to edit it), missing files, and the markers.
struct ProjectOverviewPane: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.project.timeline.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("How to start"), systemImage: "lightbulb").font(.headline)
                    Text(L("1. Import videos and photos in the Media panel on the left.")).font(.callout)
                    Text(L("2. Drag them onto the timeline at the bottom.")).font(.callout)
                    Text(L("3. Click a clip to change its look, speed or sound here.")).font(.callout)
                    Text(L("4. Press Export at the top right when you are done.")).font(.callout)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
            } else {
                Text(L("Click a clip, text or sound on the timeline to change it here.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TimelinePane(session: session)
        }
    }
}
