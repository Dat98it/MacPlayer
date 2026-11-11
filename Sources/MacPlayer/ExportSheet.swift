import SwiftUI
import AppKit
import MacPlayerCore

/// The export window: a video project's frame, quality and file; a photo project's format and file.
struct ExportSheet: View {
    @ObservedObject var session: EditorSession
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.isPhoto ? L("Save the photo") : L("Export video"), systemImage: "square.and.arrow.up").font(.title3.weight(.semibold))
                Spacer()
                if session.isPhoto { Button(L("Close")) { close() }.keyboardShortcut(.cancelAction) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if session.isPhoto {
                ScrollView { PhotoExportPane(session: session).padding(18) }.groupBoxStyle(CardGroupBoxStyle())
            } else {
                ExportPane(session: session, onDone: close)       // scrolls its choices and keeps its buttons at the bottom
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}
