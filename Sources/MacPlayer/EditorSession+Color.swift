import Foundation
import AppKit
import MacPlayerCore
import MacPlayerMedia

/// What the colour tool copies, so a grade made on one clip or photo can be put on another.
@MainActor
final class ColorClipboard {
    static let shared = ColorClipboard()
    var value: ColorAdjust?
}

extension EditorSession {
    /// The key the preview uses for the clip being edited (see `ColorLive`).
    private var colorKey: UUID? { isProject ? project.activeClipID : project.id }

    /// Changes the colour of the clip (or photo) being edited. When the preview is already drawn by the compositor the new settings are handed
    /// to it directly, so the picture changes at the next frame; the first change, which has to switch the compositor on, builds the preview.
    func editColor(_ label: String, coalesce: String? = nil, _ change: @escaping (inout ColorAdjust) -> Void) {
        if colorCompare { setColorCompare(false) }
        var probe = project
        change(&probe.activeLook.color)
        guard probe != project else { return }
        if isPhoto { edit(label, coalesce: coalesce) { change(&$0.activeLook.color) }; return }
        guard previewHasCompositor, let key = colorKey else { edit(label, coalesce: coalesce) { change(&$0.activeLook.color) }; return }
        edit(label, coalesce: coalesce, refreshPreview: false) { change(&$0.activeLook.color) }
        ColorLive.set(project.activeLook.color, for: key)
        if !player.isPlaying { Task { await player.seek(to: player.currentTime) } }
    }

    /// Shows the picture as it was before the colour changes (while a button is held), or with them again.
    func setColorCompare(_ on: Bool) {
        guard colorCompare != on else { return }
        colorCompare = on
        if isPhoto { renderPhoto(); return }
        guard previewHasCompositor, let key = colorKey else { return }
        ColorLive.set(on ? ColorAdjust() : project.activeLook.color, for: key)
        if !player.isPlaying { Task { await player.seek(to: player.currentTime) } }
    }

    /// Puts one colour setting on every clip of the project.
    func applyColorToAllClips(_ c: ColorAdjust) {
        edit("Colour for all clips") { p in for i in p.timeline.indices { p.timeline[i].look.color = c } }
    }

    func copyColor() { ColorClipboard.shared.value = project.activeLook.color; flash(L("Colour copied.")) }

    func pasteColor() {
        guard let c = ColorClipboard.shared.value else { return }
        edit("Paste colour") { $0.activeLook.color = c }
    }

    /// Asks for a look file (.cube) and uses it; a file that cannot be read is explained, not silently ignored.
    func chooseLookFile() {
        let panel = NSOpenPanel()
        panel.title = L("Choose a colour look")
        panel.message = L("Choose a .cube look file.")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let lut = try LutStore.read(path: url.path)
            let name = lut.title.isEmpty ? url.deletingPathExtension().lastPathComponent : lut.title
            edit("Colour look") { $0.activeLook.color.lut = LutRef(name: name, path: url.path, strength: 1) }
            ColorLive.clear()
            schedulePreviewRefresh()
        } catch {
            flash(LF("“%@” cannot be used as a colour look. %@", url.lastPathComponent, Self.lookErrorText(error)), error: true)
        }
    }

    /// Why a look file cannot be used, in the person's language.
    static func lookErrorText(_ error: Error) -> String {
        guard let e = error as? CubeLUT.ParseError else { return error.localizedDescription }
        switch e {
        case .oneDimensional: return L("This is a 1D look file; only 3D .cube files can be used.")
        case .noSize: return L("This file does not say how big the look is (LUT_3D_SIZE).")
        case .badSize(let n): return LF("A look of size %d is not supported (2 to 65).", n)
        case .wrongCount(let expected, let found): return LF("The file has %1$d colours, but its size needs %2$d.", found, expected)
        case .badLine(let n): return LF("Line %d of the file cannot be read.", n)
        }
    }
}
