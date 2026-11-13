import SwiftUI
import AppKit
import AVFoundation
import MacPlayerCore
import MacPlayerMedia

struct PicturePane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var analysis = Box<Double?>(nil)
    private func look<T>(_ label: String, key: String? = nil, _ get: @escaping (VideoLook) -> T, _ set: @escaping (inout VideoLook, T) -> Void) -> Binding<T> {
        session.binding(label, coalesce: key, get: { get($0.activeLook) }, set: { p, v in set(&p.activeLook, v) })
    }
    private func dbl(_ title: String, _ key: String, range: ClosedRange<Double>, _ kp: WritableKeyPath<VideoLook, Double>) -> some View {
        SliderRow(title: title, value: look(title, key: key, { $0[keyPath: kp] }, { $0[keyPath: kp] = $1 }), range: range, onDone: { session.endCoalescing() })
    }

    /// The shapes offered for cropping.
    private var cropShapes: [(String, Double)] {
        let video: [(String, Double)] = [("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("1:1", 1.0), ("4:3", 4.0 / 3)]
        let photo: [(String, Double)] = [("3:2", 3.0 / 2), ("2:3", 2.0 / 3), ("4:5", 4.0 / 5), ("1:1", 1.0), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3)]
        return session.isPhoto ? photo : video
    }

    @StateObject private var preciseOpen = Box<Bool>(false)

    private static let photoShapes: [(String, Double?)] = [("Free", nil), ("Original", -1), ("1:1", 1), ("3:2", 3.0 / 2), ("2:3", 2.0 / 3), ("4:5", 4.0 / 5), ("5:4", 5.0 / 4), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4)]

    /// Cropping a photo: a frame to drag on the picture, the shapes to keep it in, and the exact values behind a disclosure.
    private var photoCropCard: some View {
        let locked = session.photoCropRatio
        let l = session.project.activeLook
        return ToolCard(title: L("Crop"), icon: "crop", onReset: l.crop.isFull ? nil : { session.photoCropRatio = nil; session.edit("Reset crop") { $0.activeLook.crop = .full } }) {
            Toggle(L("Adjust on the picture"), isOn: $session.photoCropAdjusting)
            Text(session.photoCropAdjusting ? L("Drag the corners or edges of the frame on the picture, or drag inside it to move it. Go to another tool to see the result.")
                                            : L("Tick it (or choose a shape below) to drag the crop frame on the picture."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                ForEach(Self.photoShapes, id: \.0) { name, ratio in
                    let value: Double? = ratio == -1 ? session.photoShownAspect : ratio
                    let selected = value == nil ? locked == nil : (locked != nil && abs((locked ?? 0) - (value ?? 0)) < 1e-6)
                    Button(name == "Free" ? L("Free") : (name == "Original" ? L("Original") : name)) { session.setPhotoCropShape(value); session.photoCropAdjusting = true }
                        .buttonStyle(.bordered).controlSize(.small).tint(selected ? .accentColor : nil)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            if let r = locked, abs(r - 1) > 1e-6 {
                Button { session.setPhotoCropShape(1 / r) } label: { Label(L("Turn the frame sideways"), systemImage: "rectangle.landscape.rotate") }.font(.caption)
            }
            DisclosureGroup(L("Exact values"), isExpanded: $preciseOpen.value) {
                VStack(alignment: .leading, spacing: 6) {
                    dbl(L("Left"), "crop-x", range: 0...0.95, \.crop.x)
                    dbl(L("Top"), "crop-y", range: 0...0.95, \.crop.y)
                    dbl(L("Width"), "crop-w", range: 0.05...1, \.crop.width)
                    dbl(L("Height"), "crop-h", range: 0.05...1, \.crop.height)
                    Text(L("These values count from the picture as it came, before it is turned.")).font(.caption).foregroundColor(.secondary)
                }.padding(.top, 4)
            }.font(.caption)
        }
    }

    private static func presetName(_ p: Motion.Preset) -> String {
        switch p {
        case .zoomIn: return L("Zoom in")
        case .zoomOut: return L("Zoom out")
        case .panRight: return L("Pan right")
        case .panLeft: return L("Pan left")
        case .zoomInPan: return L("Zoom and drift")
        case .punchIn: return L("Punch in")
        }
    }

    /// Steadying shaky footage: the camera's movement is followed once (kept for next time), then the picture is moved against the shake.
    private var stabilizeCard: some View {
        let strength = session.project.activeLook.stabilize
        let busy = analysis.value != nil
        return ToolCard(title: L("Stabilize"), icon: "scope") {
            Toggle(L("Steady shaky footage"), isOn: Binding(get: { strength > 0 }, set: { on in
                if !on { session.edit("Stabilize off") { $0.activeLook.stabilize = 0 }; return }
                guard let url = session.activeSourceURL else { return }
                if Stabilizer.cachedPath(for: url) != nil { session.edit("Stabilize") { $0.activeLook.stabilize = 0.5 }; return }
                analysis.value = 0
                session.flash(L("Following the camera's movement… this is done once for each video."))
                Task {
                    do {
                        _ = try await Stabilizer.analyze(url) { p in Task { @MainActor in analysis.value = p } }
                        session.edit("Stabilize") { $0.activeLook.stabilize = 0.5 }
                    } catch { session.flash((error as? CustomStringConvertible)?.description ?? error.localizedDescription, error: true) }
                    analysis.value = nil
                }
            })).disabled(busy)
            if let p = analysis.value { ProgressView(value: p) { Text(L("Analysing…")).font(.caption) } }
            if strength > 0 {
                SliderRow(title: L("Strength"), value: session.binding(L("Strength"), coalesce: "stab", get: { $0.activeLook.stabilize }, set: { $0.activeLook.stabilize = max(0.05, $1) }), range: 0.05...1, format: "%.2f", onDone: { session.endCoalescing() })
            }
            Text(L("Takes the shake out of hand-held video. The picture is enlarged a little so its edges stay out of view; the stronger the setting, the more.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Zoom and move over the clip: ready-made animations, or keyframes set by hand at the playhead.
    private var motionCard: some View {
        let k = session.project.activeLook.motion
        let now = session.localPlayhead
        let st = Motion.state(k, at: now) ?? .still
        return ToolCard(title: L("Zoom and move"), icon: "arrow.up.left.and.arrow.down.right", onReset: k.isEmpty ? nil : { session.edit("Clear zoom and move") { $0.activeLook.motion = [] } }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                ForEach(Motion.Preset.allCases, id: \.self) { p in
                    Button(Self.presetName(p)) { session.edit(LF("Zoom and move: %@", Self.presetName(p))) { $0.activeLook.motion = Motion.keyframes(for: p, duration: session.activeClipDuration.seconds) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            SliderRow(title: L("Zoom"), value: session.binding(L("Zoom"), coalesce: "mo-s", get: { pr in Motion.state(pr.activeLook.motion, at: session.localPlayhead)?.scale ?? 1 },
                                                               set: { pr, v in var m = Motion.state(pr.activeLook.motion, at: session.localPlayhead) ?? .still; m.scale = v; pr.activeLook.motion = Motion.setting(pr.activeLook.motion, at: session.localPlayhead, to: m) }),
                      range: 1...4, format: "%.2f×", onDone: { session.endCoalescing() })
            SliderRow(title: L("Horizontal position"), value: session.binding(L("Horizontal position"), coalesce: "mo-x", get: { pr in Motion.state(pr.activeLook.motion, at: session.localPlayhead)?.x ?? 0.5 },
                                                                               set: { pr, v in var m = Motion.state(pr.activeLook.motion, at: session.localPlayhead) ?? .still; m.x = v; pr.activeLook.motion = Motion.setting(pr.activeLook.motion, at: session.localPlayhead, to: m) }),
                      range: 0...1, onDone: { session.endCoalescing() })
            SliderRow(title: L("Vertical position"), value: session.binding(L("Vertical position"), coalesce: "mo-y", get: { pr in Motion.state(pr.activeLook.motion, at: session.localPlayhead)?.y ?? 0.5 },
                                                                             set: { pr, v in var m = Motion.state(pr.activeLook.motion, at: session.localPlayhead) ?? .still; m.y = v; pr.activeLook.motion = Motion.setting(pr.activeLook.motion, at: session.localPlayhead, to: m) }),
                      range: 0...1, onDone: { session.endCoalescing() })
            SliderRow(title: L("Turn (degrees)"), value: session.binding(L("Turn"), coalesce: "mo-r", get: { pr in Motion.state(pr.activeLook.motion, at: session.localPlayhead)?.rotation ?? 0 },
                                                                         set: { pr, v in var m = Motion.state(pr.activeLook.motion, at: session.localPlayhead) ?? .still; m.rotation = v; pr.activeLook.motion = Motion.setting(pr.activeLook.motion, at: session.localPlayhead, to: m) }),
                      range: -180...180, format: "%.0f°", onDone: { session.endCoalescing() })
            Text(k.isEmpty ? L("Moving a slider sets a keyframe at the playhead. Move the playhead and change a value again to animate between them.")
                           : L("Changing a value at the playhead sets a keyframe there. Pick how the picture moves between keyframes with the menu on each one."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if !k.isEmpty {
                Button(L("Add Keyframe at Playhead")) { session.edit("Add keyframe") { $0.activeLook.motion = Motion.setting($0.activeLook.motion, at: now, to: st) } }.font(.caption)
                ForEach(k.sorted { $0.time < $1.time }) { f in
                    HStack(spacing: 6) {
                        Image(systemName: "diamond.fill").font(.caption2).foregroundColor(.accentColor).accessibilityHidden(true)
                        Text(Timecode.format(MediaTime(seconds: f.time))).font(.caption.monospacedDigit())
                        Text(String(format: "%.2f×  x %.2f  y %.2f  %.0f°", f.scale, f.x, f.y, f.rotation)).font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        EasingMenu(easing: Binding(get: { f.easing }, set: { e in session.edit("Keyframe easing") { if let i = $0.activeLook.motion.firstIndex(where: { $0.id == f.id }) { $0.activeLook.motion[i].easing = e } } }))
                        Button { Task { await session.player.seek(to: session.activeClipStart + MediaTime(seconds: f.time)) } } label: { Image(systemName: "arrow.right.to.line") }.buttonStyle(.borderless).accessibilityLabel(L("Go to keyframe"))
                        Button { session.edit("Delete keyframe") { $0.activeLook.motion.removeAll { $0.id == f.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel(L("Delete keyframe"))
                    }
                }
            }
        }
    }

    /// The groups of the Basic tab, one at a time (0.17.1).
    private var pictureSections: [PaneSection] {
        let l = session.project.activeLook
        var s = [PaneSection(id: "crop", title: L("Crop"), icon: "crop", changed: !l.crop.isFull),
                 PaneSection(id: "rotate", title: L("Rotate"), icon: "rotate.right", changed: l.rotation != 0 || l.flipHorizontal || l.flipVertical),
                 PaneSection(id: "canvas", title: L("Canvas"), icon: "aspectratio")]
        if !session.isPhoto {
            s += [PaneSection(id: "zoom", title: L("Zoom"), icon: "plus.magnifyingglass", changed: !l.motion.isEmpty),
                  PaneSection(id: "stable", title: L("Stabilize"), icon: "hand.raised", changed: l.stabilize > 0)]
        }
        s.append(PaneSection(id: "colour", title: L("Colour"), icon: "sun.max", changed: l.color.brightness != 0 || l.color.contrast != 0 || l.color.saturation != 0 || l.color.temperature != 0))
        return s
    }

    var body: some View {
        let v = session.info?.primaryVideo
        let tab = session.paneTab("picture", pictureSections).wrappedValue
        VStack(alignment: .leading, spacing: 10) {
            if v == nil { Text(L("This file has no picture.")).foregroundColor(.secondary) } else {
                SectionTabBar(sections: pictureSections, selection: session.paneTab("picture", pictureSections))
                if tab == "crop" {
                if session.isPhoto { photoCropCard } else {
                GroupBox(L("Crop")) {
                    VStack(alignment: .leading, spacing: 6) {
                        dbl(L("Left"), "crop-x", range: 0...0.95, \.crop.x)
                        dbl(L("Top"), "crop-y", range: 0...0.95, \.crop.y)
                        dbl(L("Width"), "crop-w", range: 0.05...1, \.crop.width)
                        dbl(L("Height"), "crop-h", range: 0.05...1, \.crop.height)
                        HStack {
                            ForEach(cropShapes, id: \.0) { name, a in
                                Button(name) { session.edit("Crop \(name)") { $0.activeLook.crop = CropRect.centered(aspect: a, sourceWidth: Double(v!.width), sourceHeight: Double(v!.height)) } }
                            }
                            Button(L("Reset")) { session.edit("Reset crop") { $0.activeLook.crop = .full } }
                        }.font(.caption)
                    }.padding(4)
                }
                }
                }
                if tab == "rotate" {
                GroupBox(L("Rotate and flip")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button { session.edit("Rotate left") { $0.activeLook.rotation = ($0.activeLook.rotation + 270) % 360 } } label: { Image(systemName: "rotate.left") }.accessibilityLabel(L("Rotate left"))
                            Button { session.edit("Rotate right") { $0.activeLook.rotation = ($0.activeLook.rotation + 90) % 360 } } label: { Image(systemName: "rotate.right") }.accessibilityLabel(L("Rotate right"))
                        }
                        Toggle(L("Flip ↔"), isOn: look("Flip horizontally", { $0.flipHorizontal }, { $0.flipHorizontal = $1 }))
                        Toggle(L("Flip ↕"), isOn: look("Flip vertically", { $0.flipVertical }, { $0.flipVertical = $1 }))
                    }.padding(4)
                }
                }
                if tab == "canvas" {
                GroupBox(L("Canvas")) {
                    VStack(alignment: .leading, spacing: 6) {
                        // A video project has one frame for the whole video: changed here, it changes for every clip (the export takes it from the first).
                        Picker(L("Shape"), selection: session.isProject ? Binding(get: { session.project.frameShape }, set: { v in session.edit("Frame shape") { $0.setFrame(v, fill: $0.frameFill) } })
                                                                         : look("Canvas", { $0.canvas }, { $0.canvas = $1 })) {
                            Text(session.isPhoto ? L("Same as photo") : L("Same as video")).tag(CanvasPreset.source)
                            Text("16:9").tag(CanvasPreset.landscape16x9); Text("9:16").tag(CanvasPreset.portrait9x16)
                            Text("1:1").tag(CanvasPreset.square1x1); Text("4:5").tag(CanvasPreset.portrait4x5); Text("4:3").tag(CanvasPreset.standard4x3)
                        }
                        Picker(L("Picture"), selection: session.isProject ? Binding(get: { session.project.frameFill == .fill ? FitMode.fill : FitMode.fit },
                                                                                     set: { v in session.edit("Frame fill") { $0.setFrame($0.frameShape, fill: v == .fill ? .fill : ($0.frameFill == .blurredBars ? .blurredBars : .fit)) } })
                                                                    : look("Fit", { $0.fit }, { $0.fit = $1 })) {
                            Text(L("Fit (black bars)")).tag(FitMode.fit); Text(L("Fill (crop edges)")).tag(FitMode.fill)
                        }.pickerStyle(.menu)
                        if let size = session.info?.primaryVideo {
                            let out = RenderGeometry.outputSize(source: PixelSize(width: size.width, height: size.height), look: session.project.activeLook)
                            Text(LF("Output picture: %d × %d", out.width, out.height)).font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(4)
                }
                }
                if tab == "zoom" { motionCard }
                if tab == "stable" { stabilizeCard }
                if tab == "colour" {
                GroupBox(L("Colour")) {
                    VStack(alignment: .leading, spacing: 6) {
                        dbl(L("Brightness"), "c-b", range: -1...1, \.color.brightness)
                        dbl(L("Contrast"), "c-c", range: -1...1, \.color.contrast)
                        dbl(L("Saturation"), "c-s", range: -1...1, \.color.saturation)
                        dbl(L("Temperature"), "c-t", range: -1...1, \.color.temperature)
                        Button(L("Reset colour")) { session.edit("Reset colour") { $0.activeLook.color = ColorAdjust() } }.font(.caption)
                    }.padding(4)
                }
                }
                if v?.isHDR == true {
                    Label(L("This video is HDR. Exports keep HDR (10-bit HEVC). Colour changes are applied to the HDR picture as stored, without tone mapping, so check the result."), systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                }
                Button(L("Reset all picture changes")) { session.edit("Reset picture") { $0.activeLook = VideoLook() } }.font(.caption)
            }
        }
    }
}
