import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// How the selected clip arrives from the one before it. Each choice is shown part way through, between the real last frame of the
/// clip before and the real first frame of this one.
struct TransitionsPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var tiles = Box<[TransitionKind: NSImage]>([:])

    static func name(_ k: TransitionKind) -> String {
        switch k {
        case .dissolve: return L("Dissolve")
        case .dipBlack: return L("Dip to black")
        case .dipWhite: return L("Dip to white")
        case .slideLeft: return L("Slide left")
        case .slideRight: return L("Slide right")
        case .slideUp: return L("Slide up")
        case .slideDown: return L("Slide down")
        case .wipeRight: return L("Wipe")
        case .zoomIn: return L("Zoom")
        case .wipeLeft: return L("Wipe left")
        case .wipeUp: return L("Wipe up")
        case .wipeDown: return L("Wipe down")
        case .circleOpen: return L("Circle open")
        case .blur: return L("Blur")
        case .spin: return L("Spin")
        case .flash: return L("Flash")
        case .pixelate: return L("Pixelate")
        }
    }

    private var index: Int? { session.timingClip.flatMap { c in session.project.timeline.firstIndex { $0.id == c.id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let i = index, i > 0 {
                let clips = session.project.timeline
                let current = clips[i].look.transitionIn
                ToolCard(title: LF("Transition into clip %d", i + 1), icon: "rectangle.2.swap", onReset: current == nil ? nil : { session.edit("Remove transition") { $0.activeLook.transitionIn = nil } }) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        tile(nil, current: current)
                        ForEach(TransitionKind.allCases, id: \.self) { k in tile(k, current: current) }
                    }
                    if let t = current {
                        SliderRow(title: L("Length (s)"), value: session.binding("Transition length", coalesce: "tr-len", get: { $0.activeLook.transitionIn?.duration ?? t.duration }, set: { $0.activeLook.transitionIn?.duration = $1 }),
                                  range: ClipTransition.shortest...ClipTransition.longest, format: "%.1f", onDone: { session.endCoalescing() })
                        let real = t.effectiveDuration(prev: clips[i - 1], prevSourceDuration: session.infos[clips[i - 1].sourceID]?.duration.seconds ?? .infinity, cur: clips[i])
                        if real < t.clampedDuration - 0.05 {
                            Label(real > 0 ? LF("Only %.1f s of spare footage around this cut: the transition lasts %.1f s.", real / 2, real) : L("These clips have no spare footage around the cut, so there is no transition. Trim a clip shorter to make room."), systemImage: "info.circle")
                                .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(L("A transition is centred on the cut. It uses a little footage from the end of the clip before and the start of this one, and the video keeps the same length.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(index == 0 ? L("The first clip has nothing before it. Select a later clip to put a transition into it.") : L("Select a clip on the timeline to give it a transition.")).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: session.timingClip?.id) { await loadTiles() }
    }

    private func tile(_ kind: TransitionKind?, current: ClipTransition?) -> some View {
        let selected = kind == current?.kind
        return Button {
            session.edit(kind.map { LF("Transition %@", Self.name($0)) } ?? "Remove transition") { $0.activeLook.transitionIn = kind.map { ClipTransition(kind: $0, duration: current?.duration ?? 0.8) } }
        } label: {
            VStack(spacing: 3) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(Group {
                        if let k = kind, let img = tiles.value[k] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                        else { ZStack { Rectangle().fill(Color.secondary.opacity(0.25)); Image(systemName: kind == nil ? "nosign" : "photo").foregroundColor(.secondary) } }
                    })
                    .clipped().cornerRadius(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0))
                Text(kind.map(Self.name) ?? L("None")).font(.system(size: 10, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
        }
        .buttonStyle(.plain).accessibilityLabel(kind.map(Self.name) ?? L("None")).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func loadTiles() async {
        guard let i = index, i > 0 else { return }
        let clips = session.project.timeline, prev = clips[i - 1], cur = clips[i]
        guard let pu = session.sourceURLs[prev.sourceID], let cu = session.sourceURLs[cur.sourceID] else { return }
        let size = CGSize(width: 180, height: 120)
        let tA = max(prev.sourceStart, prev.sourceEnd - MediaTime(seconds: 0.2)), tB = min(cur.sourceEnd, cur.sourceStart + MediaTime(seconds: 0.2))
        guard let a = try? await FrameGrabber.image(url: pu, at: tA, accuracy: .nearest, maxSize: size),
              let b = try? await FrameGrabber.image(url: cu, at: tB, accuracy: .nearest, maxSize: size) else { return }
        var out: [TransitionKind: NSImage] = [:]
        for k in TransitionKind.allCases { if let cg = EffectPreview.transition(from: a, to: b, kind: k, progress: 0.5) { out[k] = NSImage(cgImage: cg, size: .zero) } }
        tiles.value = out
    }
}
