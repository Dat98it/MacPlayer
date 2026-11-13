import SwiftUI
import AppKit
import MacPlayerCore

struct LayersPane: View {
    static func blendName(_ b: LayerBlend) -> String {
        switch b {
        case .normal: return L("Normal"); case .multiply: return L("Multiply"); case .screen: return L("Screen"); case .overlay: return L("Overlay")
        case .softLight: return L("Soft light"); case .hardLight: return L("Hard light"); case .darken: return L("Darken"); case .lighten: return L("Lighten")
        case .difference: return L("Difference"); case .add: return L("Add")
        }
    }

    @ObservedObject var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.isPhoto {
                let clips = session.project.overlayClips
                HStack {
                    Text(LF("%d logos", clips.count)).font(.headline)
                    Spacer()
                    Button(L("Add Logo…")) { (NSApp.delegate as? AppDelegate)?.addOverlayPicture(nil) }.disabled(session.project.sources.isEmpty)
                }.font(.caption)
                Text(L("A logo is a picture laid over the photo (a signature, a watermark). The photo stays the only photo of the project; the logo file is never changed.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if clips.isEmpty { Text(L("No logos yet.")).foregroundColor(.secondary) }
                ForEach(clips.sorted { $0.lane < $1.lane }) { c in row(c) }
                if let c = session.selectedOverlay { Divider(); editor(c) }
            } else if session.isProject {
                let clips = session.project.overlayClips
                HStack {
                    Text(LF("%d layers", clips.count)).font(.headline)
                    Spacer()
                    Button(L("Add Video…")) { (NSApp.delegate as? AppDelegate)?.addOverlayVideo(nil) }
                    Button(L("Add Picture…")) { (NSApp.delegate as? AppDelegate)?.addOverlayPicture(nil) }
                }.font(.caption)
                Text(L("A layer appears at the playhead on the first free layer line (L1 is the lowest, L3 is on top). Drag it on the timeline to move it, drag its edges to trim.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if clips.isEmpty { Text(L("No layers yet.")).foregroundColor(.secondary) }
                ForEach(clips.sorted { ($0.lane, $0.start) < ($1.lane, $1.start) }) { c in row(c) }
                if let c = session.selectedOverlay { Divider(); editor(c) }
            }
        }
    }

    private func row(_ c: OverlayClip) -> some View {
        let selected = session.selectedOverlayID == c.id
        let missing = c.sourceID.map { session.missingSourceIDs.contains($0) } ?? false
        return HStack(spacing: 6) {
            Image(systemName: c.isVideo ? "film" : "photo").foregroundColor(missing ? .red : .secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).lineLimit(1).font(.callout.weight(.medium))
                if !session.isPhoto {
                    Text("L\(c.lane + 1) · \(Timecode.format(c.start)) – \(Timecode.format(c.end))" + (missing ? " · " + L("Missing") : "")).font(.caption2.monospacedDigit()).foregroundColor(missing ? .red : .secondary)
                }
            }
            Spacer()
            if !c.keyframes.isEmpty { Image(systemName: "diamond.fill").font(.caption2).foregroundColor(.accentColor).accessibilityLabel(L("Animated")) }
            Button { session.deleteOverlay(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete layer"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .onTapGesture { session.selectedOverlayID = c.id; session.selectedClipIDs = []; if !session.isPhoto { Task { await session.player.seek(to: c.start) } } }.clickable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LF("Layer %@, line %d, from %@ to %@", c.name, c.lane + 1, Timecode.format(c.start), Timecode.format(c.end)))
        .contextMenu {
            Button(L("Duplicate")) { session.duplicateOverlay(c.id) }
            Button(L("Delete")) { session.deleteOverlay(c.id) }
        }
    }

    @ViewBuilder private func editor(_ c: OverlayClip) -> some View {
        let now = session.player.currentTime
        let st = OverlayEditor.editableState(c, at: now)
        let animated = !c.keyframes.isEmpty
        // One group at a time (0.17.1: eight cards stacked made a long scroll).
        let sections = layerSections(c, animated: animated)
        let tab = session.paneTab(session.isPhoto ? "logo" : "layer", sections)
        SectionTabBar(sections: sections, selection: tab)
        switch tab.wrappedValue {
        case "look": lookCards(c, st: st)
        case "anim": arriveCard(c); soundCard(c)
        case "motion": loopCard(c)
        case "keys": keyframeCard(c, now: now, animated: animated)
        default:
            TextField(L("Name"), text: Binding(get: { c.name }, set: { n in session.updateOverlay(c.id, "Rename layer", coalesce: "ovname") { $0.name = n } })).textFieldStyle(.roundedBorder)
            if !session.isPhoto { timing(c, now: now) }
            positionAndLook(c, st: st, now: now)
        }
    }

    private func layerSections(_ c: OverlayClip, animated: Bool) -> [PaneSection] {
        let t = c.transform
        var s = [PaneSection(id: "place", title: L("Position"), icon: "arrow.up.left.and.arrow.down.right"),
                 PaneSection(id: "look", title: L("Look"), icon: "paintbrush",
                             changed: t.borderWidth > 0 || t.chromaKey != nil || t.mask != nil || t.blend != .normal || t.isolateSubject || t.opacity < 1)]
        if !session.isPhoto {
            s += [PaneSection(id: "anim", title: L("In and out"), icon: "sparkles", changed: c.animationIn != nil || c.animationOut != nil),
                  PaneSection(id: "motion", title: L("Motion"), icon: "wand.and.rays", changed: c.loop != nil),
                  PaneSection(id: "keys", title: L("Keyframes"), icon: "diamond", changed: animated)]
        }
        return s
    }

    @ViewBuilder private func timing(_ c: OverlayClip, now: MediaTime) -> some View {
        HStack {
            Picker(L("Line"), selection: Binding(get: { c.lane }, set: { l in
                if OverlayEditor.firstFreeLane(session.project.overlayClips.filter { $0.id != c.id }, start: c.start, duration: c.duration) == nil || session.project.overlayClips.contains(where: { $0.id != c.id && $0.lane == l && $0.span.overlaps(c.span) }) {
                    session.flash(L("That line is busy at this time."), error: true)
                } else { session.moveOverlay(c.id, toStart: c.start, lane: l, coalesce: false) }
            })) { ForEach(0..<OverlayClip.laneCount, id: \.self) { Text("L\($0 + 1)").tag($0) } }.pickerStyle(.segmented)
            Button(L("Start here")) { session.moveOverlay(c.id, toStart: now, coalesce: false) }.font(.caption)
        }
        if !c.isVideo {
            SliderRow(title: L("Length (s)"), value: Binding(get: { c.duration.seconds }, set: { v in session.trimOverlay(c.id, leftEdge: false, toTimelineTime: c.start + MediaTime(seconds: v, timescale: 600)) }), range: 0.5...60, format: "%.1f", onDone: { session.endCoalescing() })
        } else {
            Text(LF("Length %@. Drag the edges on the timeline to trim.", Format.duration(c.duration))).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private func positionAndLook(_ c: OverlayClip, st: OverlayState, now: MediaTime) -> some View {

        GroupBox(L("Position and size")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.isPhoto ? L("Place the logo with the buttons and sliders below.") : c.state(at: now) == nil ? L("Move the playhead into this layer to drag it on the picture.")
                                             : L("Drag the layer on the picture to move it, drag a corner to resize it. It snaps to the centre and the margins; hold ⌥ to turn that off."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach([("arrow.up.left", OverlayEditor.Preset.topLeft, L("Top left")), ("arrow.up.right", .topRight, L("Top right")), ("arrow.down.left", .bottomLeft, L("Bottom left")),
                             ("arrow.down.right", .bottomRight, L("Bottom right")), ("circle", .center, L("Centre")), ("arrow.up.left.and.arrow.down.right", .full, L("Fill the picture"))], id: \.2) { icon, preset, name in
                        Button { session.applyOverlayPreset(c.id, preset) } label: { Image(systemName: icon).frame(width: 20) }.help(name).accessibilityLabel(name)
                    }
                }
                SliderRow(title: L("Size"), value: Binding(get: { st.width }, set: { v in session.setOverlayValue(c.id, "size") { $0.width = v } }), range: 0.05...1, format: "%.2f", onDone: { session.endCoalescing() })
                // Stretched freely with the side handles (0.16.5): how much, and back to its own shape.
                if !c.isVideo {
                    SliderRow(title: L("Stretch (height)"), value: Binding(get: { c.transform.stretch }, set: { v in session.updateOverlay(c.id, "Stretch", coalesce: "ovstretch") { $0.transform.stretch = min(max(v, 0.1), 10) } }),
                              range: 0.25...4, format: "%.2f", onDone: { session.endCoalescing() })
                    HStack {
                        Text(L("Drag the middle of a side on the picture to stretch it.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if abs(c.transform.stretch - 1) > 0.001 { Button(L("Own Shape")) { session.updateOverlay(c.id, "Stretch") { $0.transform.stretch = 1 } }.controlSize(.small) }
                    }
                }
                SliderRow(title: L("Horizontal position"), value: Binding(get: { st.centerX }, set: { v in session.setOverlayValue(c.id, "x") { $0.centerX = v } }), range: -0.2...1.2, onDone: { session.endCoalescing() })
                SliderRow(title: L("Vertical position"), value: Binding(get: { st.centerY }, set: { v in session.setOverlayValue(c.id, "y") { $0.centerY = v } }), range: -0.2...1.2, onDone: { session.endCoalescing() })
                SliderRow(title: L("Opacity"), value: Binding(get: { st.opacity }, set: { v in session.setOverlayValue(c.id, "opacity") { $0.opacity = v } }), range: 0...1, onDone: { session.endCoalescing() })
                SliderRow(title: L("Turn (degrees)"), value: Binding(get: { st.rotation }, set: { v in session.setOverlayValue(c.id, "turn") { $0.rotation = v } }), range: -180...180, format: "%.0f°", onDone: { session.endCoalescing() })
            }.padding(4)
        }
    }

    @ViewBuilder private func lookCards(_ c: OverlayClip, st: OverlayState) -> some View {
        GroupBox(L("Look")) {
            VStack(alignment: .leading, spacing: 6) {
                SliderRow(title: L("Border"), value: Binding(get: { c.transform.borderWidth }, set: { v in session.updateOverlay(c.id, "Layer border", coalesce: "ovbw") { $0.transform.borderWidth = v; $0.transform = $0.transform.clamped() } }), range: 0...0.05, format: "%.3f", onDone: { session.endCoalescing() })
                ColorPicker(L("Border colour"), selection: Binding(get: { Color(NSColor(cgColor: OverlayRendererBridge.color(c.transform.borderHex)) ?? .white) }, set: { col in session.updateOverlay(c.id, "Border colour", coalesce: "ovbc") { $0.transform.borderHex = OverlayRendererBridge.hex(col) } }))
                if !session.isPhoto {
                SliderRow(title: L("Fade in (s)"), value: Binding(get: { c.fadeIn }, set: { v in session.updateOverlay(c.id, "Layer fade", coalesce: "ovfi") { $0.fadeIn = v } }), range: 0...3, format: "%.1f", onDone: { session.endCoalescing() })
                SliderRow(title: L("Fade out (s)"), value: Binding(get: { c.fadeOut }, set: { v in session.updateOverlay(c.id, "Layer fade", coalesce: "ovfo") { $0.fadeOut = v } }), range: 0...3, format: "%.1f", onDone: { session.endCoalescing() })
                }
            }.padding(4)
        }
        GroupBox(L("Green screen")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Make a colour see-through (chroma key)"), isOn: Binding(get: { c.transform.chromaKey != nil }, set: { on in session.updateOverlay(c.id, "Chroma key") { $0.transform.chromaKey = on ? ChromaKey() : nil } }))
                if let k = c.transform.chromaKey {
                    HStack {
                        ColorPicker(L("Colour to remove"), selection: Binding(get: { Color(NSColor(cgColor: OverlayRendererBridge.color(k.colorHex)) ?? .green) },
                                                                              set: { col in session.updateOverlay(c.id, "Chroma colour", coalesce: "ovck") { $0.transform.chromaKey?.colorHex = OverlayRendererBridge.hex(col) } }))
                        Button(L("Green")) { session.updateOverlay(c.id, "Chroma colour") { $0.transform.chromaKey?.colorHex = "#00FF00" } }.font(.caption)
                        Button(L("Blue")) { session.updateOverlay(c.id, "Chroma colour") { $0.transform.chromaKey?.colorHex = "#0000FF" } }.font(.caption)
                    }
                    SliderRow(title: L("Tolerance"), value: Binding(get: { k.tolerance }, set: { v in session.updateOverlay(c.id, "Chroma tolerance", coalesce: "ovct") { $0.transform.chromaKey?.tolerance = v } }), range: 0...1, format: "%.2f", onDone: { session.endCoalescing() })
                    SliderRow(title: L("Edge softness"), value: Binding(get: { k.softness }, set: { v in session.updateOverlay(c.id, "Chroma softness", coalesce: "ovcs") { $0.transform.chromaKey?.softness = v } }), range: 0...1, format: "%.2f", onDone: { session.endCoalescing() })
                    Text(L("Raise the tolerance until the backdrop disappears; keep the softness low for a clean edge.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(4)
        }
        GroupBox(L("Cut-out and blend")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("Keep only the person or subject"), isOn: Binding(get: { c.transform.isolateSubject }, set: { on in session.updateOverlay(c.id, "Remove layer background") { $0.transform.isolateSubject = on } }))
                Picker(L("Blend with the picture under it"), selection: Binding(get: { c.transform.blend }, set: { b in session.updateOverlay(c.id, "Layer blend") { $0.transform.blend = b } })) {
                    ForEach(LayerBlend.allCases, id: \.self) { Text(Self.blendName($0)).tag($0) }
                }.pickerStyle(.menu)
                Text(L("Multiply darkens, Screen lightens, Overlay adds contrast: good for textures, light leaks and logos.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Text(L("Shape")).font(.caption.weight(.semibold))
                MaskControls(spec: c.transform.mask,
                             change: { label, coalesce, f in session.updateOverlay(c.id, label, coalesce: coalesce) { var m = $0.transform.mask; f(&m); $0.transform.mask = m } },
                             done: { session.endCoalescing() })
            }.padding(4)
        }
    }

    @ViewBuilder private func soundCard(_ c: OverlayClip) -> some View {
        if c.isVideo {
            GroupBox(L("Layer sound")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("Mute the layer's sound"), isOn: Binding(get: { c.audio.muted }, set: { m in session.updateOverlay(c.id, "Layer mute") { $0.audio.muted = m } }))
                    SliderRow(title: L("Gain (dB)"), value: Binding(get: { c.audio.gainDB }, set: { v in session.updateOverlay(c.id, "Layer gain", coalesce: "ovg") { $0.audio.gainDB = v } }), range: -24...24, format: "%.1f", onDone: { session.endCoalescing() })
                }.padding(4)
            }
        }
    }

    @ViewBuilder private func arriveCard(_ c: OverlayClip) -> some View {
        GroupBox(L("Arrive and leave")) {
            VStack(alignment: .leading, spacing: 8) {
                ArrivalControls(title: L("Arrives with"), animation: c.animationIn) { a in session.updateOverlay(c.id, "Layer arrival", coalesce: "ovain") { $0.animationIn = a } }
                ArrivalControls(title: L("Leaves with"), animation: c.animationOut) { a in session.updateOverlay(c.id, "Layer departure", coalesce: "ovaout") { $0.animationOut = a } }
                Text(L("Ready-made moves at the start and end of the layer. They add to the keyframes below.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(4)
        }
    }

    @ViewBuilder private func loopCard(_ c: OverlayClip) -> some View {
        GroupBox(L("Motion")) {
            LoopMotionControls(loop: c.loop, set: { l, coalesce in session.updateOverlay(c.id, "Motion", coalesce: coalesce ? "ovloop" : nil) { $0.loop = l } },
                               preview: { session.previewFrom(c.start) })
                .padding(4)
        }
    }

    @ViewBuilder private func keyframeCard(_ c: OverlayClip, now: MediaTime, animated: Bool) -> some View {
        GroupBox(L("Animation")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(animated ? L("Changing a value at the playhead sets a keyframe there. Pick how the values move between keyframes with the menu on each one.") : L("Add a keyframe, then move the playhead and change position, size, turn or opacity to animate the layer."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Add Keyframe at Playhead")) { session.addKeyframe(c.id) }.disabled(now < c.start || now >= c.end)
                    if animated { Button(L("Clear Animation")) { session.clearKeyframes(c.id) } }
                }.font(.caption)
                ForEach(c.keyframes) { k in
                    HStack {
                        Image(systemName: "diamond.fill").font(.caption2).foregroundColor(.accentColor).accessibilityHidden(true)
                        Text(Timecode.format(c.start + k.time)).font(.caption.monospacedDigit())
                        Text(String(format: "x %.2f  y %.2f  %@ %.2f  %.0f°", k.centerX, k.centerY, L("size"), k.width, k.rotation)).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        EasingMenu(easing: Binding(get: { k.easing }, set: { e in session.setKeyframeEasing(c.id, keyframe: k.id, e) }))
                        Button { Task { await session.player.seek(to: c.start + k.time) } } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).accessibilityLabel(L("Go to keyframe"))
                        Button { session.removeKeyframe(c.id, keyframe: k.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete keyframe"))
                    }
                }
            }.padding(4)
        }
    }
}
