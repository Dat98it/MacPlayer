import SwiftUI
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// The Export tool of a photo: format, quality, size, privacy, and where it is saved.
struct PhotoExportPane: View {
    @ObservedObject var session: EditorSession

    private var d: PhotoSaveDraft { session.photoDraft }
    private func set(_ f: (inout PhotoSaveDraft) -> Void) { var x = session.photoDraft; f(&x); session.photoDraft = x }
    private func opt<T>(_ get: @escaping (PhotoExportOptions) -> T, _ put: @escaping (inout PhotoExportOptions, T) -> Void) -> Binding<T> {
        Binding(get: { get(d.options) }, set: { v in set { put(&$0.options, v) } })
    }

    static func formatName(_ f: PhotoFormat) -> String {
        switch f { case .jpeg: return "JPEG"; case .png: return "PNG"; case .heic: return "HEIC"; case .tiff: return "TIFF"; case .gif: return "GIF" }
    }

    /// GIF is offered for animations (and for a GIF that is open); the others for every picture.
    private var formats: [PhotoFormat] { PhotoFormat.allCases.filter { $0 != .gif || session.photoAnimation != nil || session.sourceURL?.pathExtension.lowercased() == "gif" } }

    private var sizes: [(Int?, String)] { [(nil, L("Same as the edit")), (4096, "4096"), (2560, "2560"), (1920, "1920"), (1280, "1280"), (1080, "1080")] }

    private var resultSize: String? {
        guard let s = session.photoSavedSize else { return nil }
        return LF("The saved photo is %d × %d pixels.", s.width, s.height)
    }

    private func folderPath() -> String { d.folder ?? session.env.prefs.lastExportFolder ?? (session.sourceURL.map { PathUtil.directory(of: $0.path) } ?? NSHomeDirectory()) }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { set { $0.folder = u.path }; session.env.prefs.lastExportFolder = u.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolCard(title: L("Format"), icon: "photo") {
                Picker("", selection: opt({ $0.format }, { $0.format = $1 })) { ForEach(formats, id: \.self) { Text(Self.formatName($0)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                if d.options.format.isLossy {
                    SliderRow(title: L("Quality"), value: opt({ $0.quality }, { $0.quality = $1 }), range: 0.3...1, format: "%.2f")
                } else if d.options.format == .gif {
                    Text(session.photoAnimation != nil ? LF("The animation is saved with the same edit on all %d frames.", session.photoAnimation?.frameCount ?? 0) : L("GIF keeps at most 256 colours."))
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("Saved without losing any quality; the file is larger.")).font(.caption).foregroundColor(.secondary)
                }
                if session.photoAnimation != nil, d.options.format != .gif {
                    Label(L("Only the first frame is saved in this format. Choose GIF to keep the animation."), systemImage: "info.circle").font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Picker(L("Longest side"), selection: opt({ $0.maxLongEdge }, { $0.maxLongEdge = $1 })) { ForEach(sizes, id: \.1) { Text($0.1).tag($0.0) } }
                if let r = resultSize { Text(r).font(.caption).foregroundColor(.secondary) }
            }
            ToolCard(title: L("Privacy"), icon: "hand.raised") {
                Toggle(L("Leave out where it was taken"), isOn: opt({ $0.removeLocation }, { $0.removeLocation = $1 }))
                Text(L("Removes the GPS position and the camera details. The date and the rest stay.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ToolCard(title: L("Save"), icon: "square.and.arrow.down") {
                Text(L("Saves a new photo. The original photo is never changed.")).font(.caption).foregroundColor(.secondary)
                Group {
                    TextField(L("File name"), text: Binding(get: { d.name }, set: { v in set { $0.name = v } }),
                              prompt: Text((session.sourceURL?.deletingPathExtension().lastPathComponent ?? "") + session.env.prefs.copySuffix)).textFieldStyle(.roundedBorder)
                    HStack {
                        Text(folderPath()).font(.caption).lineLimit(1).truncationMode(.head).foregroundColor(.secondary)
                        Spacer()
                        Button(L("Choose Folder…")) { chooseFolder() }
                    }
                    Text(L("An existing file is never overwritten: a number is added to the name instead.")).font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Button { session.savePhoto() } label: { Label(L("Save Photo"), systemImage: "checkmark.circle.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                        .disabled(d.saving || session.sourceURL == nil)
                    if d.saving { ProgressView().controlSize(.small) }
                    if let url = d.lastSaved {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.caption)
                    }
                }
            }
        }
    }
}
