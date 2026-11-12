import SwiftUI
import AppKit
import MacPlayerCore

/// Under a photo: going to the next and previous picture of the playlist, the slideshow, zoom, and what the picture is.
struct PhotoBar: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var playlists: PlaylistModel
    /// A photo opened on its own (0.15): nothing about playlists, even while one plays in another window.
    var solo = false
    var actualZoom: () -> CGFloat

    private var inPlaylist: Bool { !solo && session.role == .viewer && playlists.playingID != nil }

    private func button(_ icon: String, _ help: String, big: Bool = false, selected: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: big ? 16 : 13)).frame(width: big ? 30 : 24, height: 24).foregroundColor(selected ? .accentColor : .primary) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }

    private var details: String {
        guard let v = session.info?.primaryVideo else { return "" }
        var parts = ["\(v.width) × \(v.height)"]
        if let out = session.photoOutputSize, Int(out.width) != v.width || Int(out.height) != v.height { parts = [LF("%d × %d now", Int(out.width), Int(out.height))] + parts }
        if let a = session.photoAnimation { parts.append(LF("%d frames · %.1f s", a.frameCount, a.duration)) }
        if let size = session.info?.fileSize, size > 0 { parts.append(Format.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            if inPlaylist {
                button("chevron.left", L("Previous"), big: true) { playlists.previous() }
                button("chevron.right", L("Next"), big: true) { playlists.advance(auto: false) }
                button(playlists.slideshowOn ? "pause.fill" : "play.rectangle.fill", playlists.slideshowOn ? L("Stop the slideshow") : L("Start a slideshow"), big: true, selected: playlists.slideshowOn) { playlists.toggleSlideshow() }
                Divider().frame(height: 18)
            }
            if session.photoAnimation != nil {
                button(session.photoPlaying ? "pause.fill" : "play.fill", session.photoPlaying ? L("Pause the animation") : L("Play the animation"), big: true) { session.photoPlaying.toggle() }
            }
            Spacer(minLength: 8)
            button("minus.magnifyingglass", L("Zoom out")) { session.photoZoomOut() }
            Text(session.photoZoom <= 1.001 ? L("Fit") : String(format: "%.1f×", Double(session.photoZoom))).font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).frame(width: 52)
            button("plus.magnifyingglass", L("Zoom in")) { session.photoZoomIn() }
            button("arrow.up.left.and.arrow.down.right", L("Fit to the window")) { session.photoFit() }
            button("1.magnifyingglass", L("Actual pixels")) { session.photoZoom = actualZoom() }
            Spacer(minLength: 8)
            Text(details).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
