import SwiftUI
import UniformTypeIdentifiers
import AppKit
import MacPlayerCore

struct InspectorView: View {
    @ObservedObject var session: EditorSession
    /// In a video project the Picture and Audio tools edit the selected clip, so one has to be selected.
    private var needsClip: Bool { session.isProject && session.project.activeClipID == nil }

    var body: some View {
        VStack(spacing: 0) {
            // Every tool is one click away: no menu to open first.
            LazyVGrid(columns: panelColumns(64), spacing: 4) {
                ForEach(InspectorTab.tabs(for: session.project.kind), id: \.self) { tab in
                    PanelButton(title: tab.title, icon: tab.icon, selected: session.activeTool == tab) { session.activeTool = tab }
                }
            }
            .padding(8).accessibilityElement(children: .contain).accessibilityLabel(L("Tool"))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch session.activeTool {
                    case .clips: TimelinePane(session: session)
                    case .layers: LayersPane(session: session)
                    case .picture: if needsClip { Text(L("Select a clip on the timeline to edit its picture.")).foregroundColor(.secondary) } else { PicturePane(session: session) }
                    case .color: if needsClip { Text(L("Select a clip on the timeline to edit its colour.")).foregroundColor(.secondary) } else { ColorPane(session: session) }
                    case .mask: if needsClip { Text(L("Select a clip on the timeline to edit its cut-out.")).foregroundColor(.secondary) } else { MaskPane(session: session) }
                    case .effects: if needsClip { Text(L("Select a clip on the timeline to edit its effects.")).foregroundColor(.secondary) } else { EffectsPane(session: session) }
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
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String = "%.2f"
    var onDone: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption); Spacer(); Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundColor(.secondary) }
            Slider(value: $value, in: range) { editing in if !editing { onDone() } }.accessibilityLabel(title)
        }
    }
}

struct TimelinePane: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        let clips = session.project.timeline
        let missing = session.missingSourceIDs
        let starts = TimelineEditor.starts(clips)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LF("%d clips · %@", clips.count, Format.duration(session.project.timelineDuration))).font(.headline)
                Spacer()
                Button(L("Add Video…")) { (NSApp.delegate as? AppDelegate)?.addVideoToProject(nil) }
            }
            HStack {
                Button(L("Split")) { session.splitAtPlayhead() }.help(L("Split the clip at the playhead (S)"))
                Button(L("Duplicate")) { session.duplicateTimelineClips(session.selectedClipIDs) }.disabled(session.selectedClipIDs.isEmpty)
                Button(L("Delete")) { session.deleteTimelineClips(session.selectedClipIDs) }.disabled(session.selectedClipIDs.isEmpty)
            }.font(.caption)
            Text(L("Drag a clip to reorder it. Drag its edges to trim. Picture and Audio tools change the selected clip. The videos themselves are never changed.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            let missingSources = session.project.sources.filter { missing.contains($0.id) }
            if !missingSources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("Some videos are missing. The preview and export wait until you relink them."), systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundColor(.red)
                    ForEach(missingSources) { src in
                        HStack {
                            Text(PathUtil.fileName(of: src.mediaPath)).font(.caption).lineLimit(1)
                            Spacer()
                            Button(L("Relink…")) { relink(src.id) }.font(.caption)
                        }
                    }
                }.padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
            }

            ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                let selected = session.selectedClipIDs.contains(c.id)
                let srcName = PathUtil.fileName(of: session.project.source(c.sourceID)?.mediaPath ?? "")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 18)
                        TextField(L("Name"), text: Binding(get: { c.name }, set: { n in session.edit("Rename clip", coalesce: "tn-\(c.id)", refreshPreview: false) { p in if let k = p.timeline.firstIndex(where: { $0.id == c.id }) { p.timeline[k].name = n } } })).textFieldStyle(.roundedBorder)
                        Button { session.moveClip(c.id, toIndex: max(0, i - 1)) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(i == 0).accessibilityLabel(L("Move earlier"))
                        Button { session.moveClip(c.id, toIndex: min(clips.count, i + 2)) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(i == clips.count - 1).accessibilityLabel(L("Move later"))
                    }
                    HStack(spacing: 6) {
                        Text(srcName).font(.caption).lineLimit(1).foregroundColor(missing.contains(c.sourceID) ? .red : .secondary)
                        Spacer()
                        Text("\(Timecode.format(c.sourceStart)) – \(Timecode.format(c.sourceEnd))").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                        Text(Format.duration(c.duration)).font(.caption)
                    }
                    if selected {
                        SliderRow(title: L("Speed"), value: session.binding("Clip speed", coalesce: "spd-\(c.id)", get: { $0.activeLook.speed }, set: { $0.activeLook.speed = $1 }), range: 0.25...4, format: "%.2f×", onDone: { session.endCoalescing() })
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                .onTapGesture { session.selectedClipIDs = [c.id]; if let t = starts[c.id] { Task { await session.player.seek(to: t) } } }.clickable()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(LF("Clip %d, %@, %@", i + 1, c.name.isEmpty ? srcName : c.name, Format.duration(c.duration)))
            }
            if clips.isEmpty { Text(L("The timeline is empty. Add a video.")).foregroundColor(.secondary) }
            Divider()
            HStack {
                Text(L("Markers")).font(.headline); Spacer()
                Button(L("Add")) { session.addMarker() }
            }
            ForEach(session.project.markers) { m in
                HStack {
                    Menu {
                        ForEach(MarkerColor.allCases, id: \.self) { col in Button(col.rawValue.capitalized) { session.edit("Marker colour", refreshPreview: false) { p in if let i = p.markers.firstIndex(where: { $0.id == m.id }) { p.markers[i].color = col } } } }
                    } label: { Circle().fill(Color(TimelineView.markerColor(m.color))).frame(width: 10, height: 10) }.frame(width: 28)
                    TextField(L("Name"), text: Binding(get: { m.name }, set: { n in session.edit("Rename marker", coalesce: "mk-\(m.id)", refreshPreview: false) { p in if let i = p.markers.firstIndex(where: { $0.id == m.id }) { p.markers[i].name = n } } })).textFieldStyle(.roundedBorder)
                    Text(Timecode.format(m.time)).font(.caption.monospacedDigit())
                    Button { Task { await session.player.seek(to: m.time) } } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).accessibilityLabel(L("Go to marker"))
                    Button { session.edit("Delete marker", refreshPreview: false) { p in p.markers.removeAll { $0.id == m.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete marker"))
                }
            }
            if !session.project.markers.isEmpty { Button(L("Export Markers CSV…")) { exportMarkers() }.font(.caption) }
        }
    }

    private func exportMarkers() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.project.name + "-markers.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let why = OriginalGuard.problem(writing: url.path) { session.flash(why, error: true); return }
        try? Data(ListExport.csv(markers: session.project.markers, frameRate: session.frameRate).utf8).write(to: url)
    }

    private func relink(_ id: UUID) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        p.allowedContentTypes = session.project.source(id)?.stillOf != nil ? [.image] : session.project.source(id)?.soundOf != nil ? [.audio] : [.movie, .video]
        if p.runModal() == .OK, let u = p.url { Task { await session.relinkSource(id, to: u) } }
    }
}
