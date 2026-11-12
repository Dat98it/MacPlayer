import AppKit
import CoreImage
import SwiftUI
import MacPlayerCore
import MacPlayerMedia

// MARK: A sound playing on its own (0.16)

extension EditorSession {
    /// A sound with no picture (a song, a recording, a video file that only holds sound) being watched: the picture's place shows its
    /// cover and tags instead of black.
    var isSoundOnly: Bool {
        if isPhoto || role == .editor { return false }
        if let r = remote {
            guard r.kind != .photo else { return false }
            return AudioFiles.isCandidate(r.link.path) || [r.contentType, r.playbackMIME].contains { $0?.lowercased().hasPrefix("audio/") == true }
        }
        return info.map { !$0.hasVideo } ?? false
    }
}

/// What a sound file says about itself, read once, off the main thread.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var tags: AudioCover.Info?
    @Published private(set) var artwork: NSImage?
    /// The artwork blurred and darkened, made once with Core Image (a SwiftUI blur is redrawn all the time, and is missing from window pictures).
    @Published private(set) var backdrop: NSImage?
    private var loadedFor: URL?

    func load(_ url: URL?, fallbackTitle: String) async {
        guard let url, loadedFor != url else { return }
        loadedFor = url
        if tags == nil { tags = AudioCover.Info(title: fallbackTitle) }
        let info = await Task.detached(priority: .userInitiated) { await AudioCover.info(of: url) }.value
        var t = info
        if url.isFileURL == false, t.title == url.deletingPathExtension().lastPathComponent { t.title = fallbackTitle }
        tags = t
        if let d = info.artwork, let cg = AudioCover.artworkImage(d, maxPixel: 900) {
            artwork = NSImage(cgImage: cg, size: .zero)
            let blurred = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let small = AudioCover.artworkImage(d, maxPixel: 160) else { return nil }
                let ci = CIImage(cgImage: small)
                let out = ci.clampedToExtent().applyingGaussianBlur(sigma: 9)
                    .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.22, kCIInputSaturationKey: 1.25]).cropped(to: ci.extent)
                return CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(out, from: ci.extent)
            }.value
            backdrop = blurred.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

/// In the picture's place while a sound plays: its cover (or a coloured tile with a note), title, artist and album, on a blurred copy of
/// the cover. Takes no clicks: they go to the player underneath, as on a video.
struct NowPlayingView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var player: PlayerController
    @StateObject private var model = NowPlayingModel()

    private var fallbackTitle: String {
        session.remote?.displayName ?? session.sourceURL?.deletingPathExtension().lastPathComponent ?? session.project.name
    }
    private var title: String { model.tags?.title ?? fallbackTitle }
    private var colors: (Color, Color) {
        let (a, b) = AudioCover.palette(for: title)
        return (Color(cgColor: a), Color(cgColor: b))
    }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height * 1.25
            let side = max(80, min(wide ? g.size.height * 0.62 : g.size.height * 0.46, wide ? g.size.width * 0.36 : g.size.width * 0.62, 420))
            ZStack {
                background
                if wide {
                    HStack(spacing: max(20, side * 0.14)) {
                        cover(side)
                        words(side, alignment: .leading).frame(maxWidth: min(520, g.size.width - side - 120), alignment: .leading)
                    }
                    .padding(.horizontal, 32)
                } else {
                    VStack(spacing: max(12, side * 0.08)) {
                        cover(side)
                        words(side, alignment: .center).frame(maxWidth: g.size.width - 48)
                    }
                    .padding(.vertical, 20)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        // A sound that cannot be played says why, on the player underneath.
        .opacity(player.failure == nil ? 1 : 0)
        .task(id: session.remote?.link ?? session.sourceURL) { await model.load(session.remote?.link ?? session.sourceURL, fallbackTitle: fallbackTitle) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LF("Playing the sound “%@”", title))
    }

    @ViewBuilder private var background: some View {
        if let back = model.backdrop {
            Image(nsImage: back).resizable().interpolation(.high).scaledToFill().overlay(Color.black.opacity(0.3))
        } else if model.artwork != nil {
            Color.black
        } else {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Color.black.opacity(0.3))
        }
    }

    private func cover(_ side: CGFloat) -> some View {
        ZStack {
            if let art = model.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [colors.0.opacity(0.95), colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: side * 0.36, weight: .regular)).foregroundColor(.white.opacity(0.88))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: side * 0.08, y: side * 0.03)
        .scaleEffect(player.isPlaying ? 1 : 0.94)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.isPlaying)
    }

    private func words(_ side: CGFloat, alignment: HorizontalAlignment) -> some View {
        let big = min(30, max(15, side * 0.1))
        let text: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
                Text(player.isPlaying ? L("Playing") : L("Paused")).textCase(.uppercase).tracking(0.8)
            }
            .font(.system(size: max(10, big * 0.42), weight: .semibold)).foregroundColor(.white.opacity(0.6))
            .padding(.bottom, 2)
            Text(title).font(.system(size: big, weight: .bold)).foregroundColor(.white).lineLimit(3).multilineTextAlignment(text)
            if let a = model.tags?.artist { Text(a).font(.system(size: big * 0.62, weight: .medium)).foregroundColor(.white.opacity(0.85)).lineLimit(2).multilineTextAlignment(text) }
            if let a = model.tags?.album { Text(a).font(.system(size: big * 0.5)).foregroundColor(.white.opacity(0.6)).lineLimit(2).multilineTextAlignment(text) }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
    }
}
