import SwiftUI
import AppKit
import MacPlayerCore

/// A speed curve drawn small: time across, speed up.
struct SpeedCurve: Shape {
    let preset: SpeedRamp.Preset
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = 40
        for i in 0...n {
            let u = Double(i) / Double(n)
            let s = min(max(SpeedRamp.speed(preset, at: u), 0), 3)
            let pt = CGPoint(x: r.minX + r.width * u, y: r.maxY - r.height * (s / 3))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

/// Speed, speed ramps, freeze frames and reversing: the tools that change how time runs in a clip.
struct TimingPane: View {
    @ObservedObject var session: EditorSession
    @StateObject private var hold = Box<Double>(2)

    static func name(_ p: SpeedRamp.Preset) -> String {
        switch p {
        case .montage: return L("Montage")
        case .bullet: return L("Slow-mo")
        case .hero: return L("Hero")
        case .flashIn: return L("Flash in")
        case .flashOut: return L("Flash out")
        case .jumpCut: return L("Jump cut")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.timingClip == nil {
                Text(L("Select a clip on the timeline to use these tools.")).foregroundColor(.secondary)
            } else {
                ToolCard(title: L("Speed"), icon: "speedometer") {
                    SliderRow(title: L("Speed"), value: session.binding("Clip speed", coalesce: "spd-timing", get: { $0.activeLook.speed }, set: { $0.activeLook.speed = $1 }), range: 0.25...4, format: "%.2f×", onDone: { session.endCoalescing() })
                    HStack(spacing: 6) {
                        ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { v in
                            Button(String(format: "%g×", v)) { session.edit("Clip speed") { $0.activeLook.speed = v } }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                ToolCard(title: L("Speed ramp"), icon: "chart.line.uptrend.xyaxis") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(SpeedRamp.Preset.allCases, id: \.self) { p in
                            Button { session.applySpeedRamp(p, name: Self.name(p)) } label: {
                                VStack(spacing: 3) {
                                    SpeedCurve(preset: p).stroke(Color.accentColor, lineWidth: 2).frame(height: 34).padding(4)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                                    Text(Self.name(p)).font(.system(size: 10)).lineLimit(1)
                                }
                            }.buttonStyle(.plain).help(Self.name(p)).accessibilityLabel(LF("Speed ramp %@", Self.name(p)))
                        }
                    }
                    Text(L("The speed changes smoothly along the clip. The clip is cut into ten parts, each at its own steady speed; you can still change any of them.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ToolCard(title: L("Freeze frame"), icon: "snowflake") {
                    SliderRow(title: L("Hold for (s)"), value: Binding(get: { hold.value }, set: { hold.value = $0 }), range: 0.5...10, format: "%.1f")
                    Button(L("Freeze the Frame at the Playhead")) { session.freezeFrameAtPlayhead(hold: hold.value) }
                    Text(L("The picture stops on this frame for the time you choose, then the clip carries on.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ToolCard(title: L("Reverse"), icon: "arrow.counterclockwise") {
                    Button(L("Reverse This Clip")) { session.reverseClip() }
                    Text(L("Makes a copy of the clip that plays backwards, picture and sound, and uses it in the clip's place. The original video is not changed. Works on clips up to three minutes.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
