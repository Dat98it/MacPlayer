import SwiftUI
import MacPlayerCore

/// Cutting a highlight (0.22): find the best moments, look them over, keep only those.
struct HighlightCard: View {
    @ObservedObject var session: EditorSession
    @StateObject private var settings = Box<EditorSession.HighlightSettings>(EditorSession.HighlightSettings())
    @StateObject private var selectedOnly = Box<Bool>(false)
    @StateObject private var toBeat = Box<Bool>(true)
    @StateObject private var showMore = Box<Bool>(false)

    var body: some View {
        ToolCard(title: L("Highlight"), icon: "flame") {
            Text(L("Finds the goals, walk-out, team line-ups, opening kick-off, cards, full time and the best action. Leaves out the half-time break and second-half kick-off. Look the list over, then make the highlight. Everything is looked at on this Mac."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L("Add the broadcast's replay after goals"), isOn: Binding(get: { settings.value.withReplays }, set: { v in
                settings.value.withReplays = v
                if !session.highlightSignals.isEmpty { session.rebuildHighlights(settings.value) }
            })).help(L("When the video replays a goal or a chance, the replay goes in right after it"))
            if session.selectedClipIDs.count > 1 {
                Toggle(LF("Only the %d selected clips", session.selectedClipIDs.count), isOn: Binding(get: { selectedOnly.value }, set: { selectedOnly.value = $0 }))
            }
            if let p = session.highlightProgress {
                HStack { ProgressView(value: p).frame(maxWidth: .infinity); Button(L("Stop")) { session.cancelHighlights() }.controlSize(.small) }
                Text(LF("Looking at the clips… %d%%", Int(p * 100))).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: panelColumns(120), spacing: 4) {
                    PanelButton(title: session.highlights.isEmpty ? L("Find highlight") : L("Look again"), icon: "sparkle.magnifyingglass",
                                help: L("Looks at every clip (or the selected ones) and chooses the highlight")) {
                        session.findHighlights(settings.value, only: selectedOnly.value && session.selectedClipIDs.count > 1 ? session.selectedClipIDs : nil)
                    }
                }
            }
            if !session.highlights.isEmpty { list }
        }
    }

    static func label(_ e: MatchEventKind, _ goal: String?) -> String {
        switch e {
        case .walkout: return L("Walk out")
        case .lineup: return L("Line-up")
        case .kickoff: return L("Kick-off")
        case .goal: return LF("Goal %@", goal ?? "")
        case .setPiece: return L("Set piece")
        case .yellowCard: return L("Yellow card")
        case .redCard: return L("Red card")
        case .check: return L("VAR check")
        case .substitution: return L("Substitution")
        case .halfTime: return L("Half-time")
        case .fullTime: return L("Full time")
        }
    }

    static func colour(_ e: MatchEventKind) -> Color {
        switch e {
        case .goal: return .green
        case .setPiece: return .orange
        case .yellowCard: return .yellow
        case .redCard: return .red
        default: return .accentColor
        }
    }

    static func why(_ e: MatchEventKind) -> String {
        switch e {
        case .goal: return L("The score changed on the scoreboard: this is the goal")
        case .kickoff, .halfTime, .fullTime: return L("Read from the match clock on the scoreboard")
        case .walkout, .lineup: return L("The teams stand in a row")
        case .setPiece: return L("Play stood still, then the kick: a free kick, a corner or a penalty")
        case .yellowCard, .redCard, .check, .substitution: return L("Read in words on the picture")
        }
    }

    @ViewBuilder private var list: some View {
        let chosen = session.highlights.filter(\.chosen)
        let more = session.highlights.filter { !$0.chosen }
        let total = chosen.reduce(0) { $0 + $1.length }
        Text(LF("%d moments: the highlight will be %@ long.", chosen.count, Format.duration(MediaTime(seconds: total))))
            .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        if session.beatSound?.beats != nil {
            Toggle(L("Then cut to the beat of the music"), isOn: Binding(get: { toBeat.value }, set: { toBeat.value = $0 }))
        }
        LazyVGrid(columns: panelColumns(120), spacing: 4) {
            PanelButton(title: L("Make the highlight"), icon: "film.stack", help: L("Keeps only the checked moments, in order. Undo brings the whole video back.")) {
                session.makeHighlight(toBeat: toBeat.value)
            }.disabled(chosen.isEmpty).opacity(chosen.isEmpty ? 0.4 : 1)
            PanelButton(title: L("Only mark them"), icon: "bookmark", help: L("Puts a marker at each checked moment and cuts nothing")) { session.markHighlights() }
                .disabled(chosen.isEmpty).opacity(chosen.isEmpty ? 0.4 : 1)
        }
        VStack(alignment: .leading, spacing: 2) { ForEach(chosen) { row($0) } }
        if !more.isEmpty {
            // The words open it too (on macOS only the small arrow of a disclosure group does, and a click on the words did nothing).
            DisclosureGroup(isExpanded: Binding(get: { showMore.value }, set: { showMore.value = $0 })) {
                VStack(alignment: .leading, spacing: 2) { ForEach(more) { row($0) } }
            } label: {
                Button { showMore.value.toggle() } label: { Text(LF("More suggestions (%d)", more.count)) }.buttonStyle(.plain)
            }.font(.caption)
        }
    }

    private func row(_ h: HighlightFound) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { h.chosen }, set: { v in if let i = session.highlights.firstIndex(where: { $0.id == h.id }) { session.highlights[i].chosen = v } })).labelsHidden()
            Text(Timecode.format(h.timeline.start)).font(.caption.monospacedDigit())
            if let e = h.event {
                Text(Self.label(e, h.goal)).font(.caption.weight(.semibold)).foregroundColor(Self.colour(e)).lineLimit(1)
                    .help(Self.why(e))
            } else if h.setPiece {
                Text(L("Set piece")).font(.caption).foregroundColor(.orange).lineLimit(1).help(Self.why(.setPiece))
            } else if h.replayed {
                Image(systemName: "arrow.counterclockwise").font(.caption).foregroundColor(.orange)
                    .help(L("The broadcast showed this again")).accessibilityLabel(L("The broadcast showed this again"))
            }
            Text(String(format: "%.0f s", h.length)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Spacer()
            Button { session.previewHighlight(h) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                .help(L("Play this moment")).accessibilityLabel(L("Play this moment"))
        }
    }
}
