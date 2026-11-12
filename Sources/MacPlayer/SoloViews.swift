import AppKit
import SwiftUI
import MacPlayerCore

// MARK: The bar of a window that plays one file on its own (0.15)

/// Above the picture of a file opened on its own: what it is (name, size, length, where from), and what can be done with it.
/// Nothing about playlists. A file of the person's can be edited, shown in Finder, renamed or put in the Trash; a link can be
/// saved to the Mac, copied or opened in the browser.
struct SoloHeader: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var linkSave: LinkSave
    var onRename: () -> Void = {}
    var onTrash: () -> Void = {}
    var onEdit: () -> Void = {}

    private var remote: RemoteSource? { session.remote }
    private var icon: String {
        if let r = remote { return r.kind == .stream ? "dot.radiowaves.left.and.right" : r.kind == .photo ? "photo" : "link" }
        if session.isPhoto { return session.photoAnimation != nil ? "photo.stack" : "photo" }
        return session.isSoundOnly ? "music.note" : "film"
    }
    private var tint: Color { remote != nil ? .teal : session.isPhoto ? .orange : session.isSoundOnly ? .pink : .accentColor }
    private var name: String {
        if let r = remote { return r.displayName }
        return session.sourceURL?.lastPathComponent ?? session.project.name
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16))
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(tint)
            }
            .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .help(remote?.link.absoluteString ?? session.sourceURL?.path ?? name)
                    if remote != nil { SoloBadge(text: L("Link"), color: .teal) }
                }
                SummaryLine(session: session, player: session.player)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            // The buttons keep their whole width; a long name is the one that gets shorter (a 120-character song name squeezed "Edit" to "E").
            Group { if let r = remote { linkActions(r) } else if session.localFileURL != nil { fileActions } }.fixedSize()
            moreMenu
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: A file of the person's

    @ViewBuilder private var fileActions: some View {
        // The bar's main action, in the accent colour, with an icon of what editing it means (see `EditButtonIcon`).
        Button(action: onEdit) { Label(L("Edit"), systemImage: EditButtonIcon.name(for: session)).labelStyle(.titleAndIcon) }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .help(L("Make a project from this file and edit it (⌘E). The file itself is never changed."))
    }

    // MARK: A link

    @ViewBuilder private func linkActions(_ r: RemoteSource) -> some View {
        switch linkSave.state {
        case .idle:
            if r.canSave {
                Button { LinkActions.save(session) } label: { Label(L("Download…"), systemImage: "arrow.down.circle") }
                    .controlSize(.small)
                    .help(L("Save this file on your Mac, to keep it or to edit it."))
            } else {
                Label(L("Cannot be downloaded"), systemImage: "arrow.down.circle.dotted").font(.caption).foregroundColor(.secondary).labelStyle(.titleAndIcon)
                    .help(L("A stream comes in small pieces and cannot be saved as one file."))
            }
        case .saving(let f):
            HStack(spacing: 6) {
                if f >= 0 {
                    ProgressView(value: f).progressViewStyle(.linear).frame(width: 90)
                    Text("\(Int((f * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("Downloading…")).font(.caption).foregroundColor(.secondary)
                }
                Button { linkSave.cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.borderless).help(L("Stop downloading")).accessibilityLabel(L("Stop downloading"))
            }
            .accessibilityElement(children: .combine).accessibilityLabel(L("Downloading"))
        case .saved(let file):
            HStack(spacing: 6) {
                Label(L("Downloaded"), systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundColor(.green)
                Button(L("Open")) { LinkActions.openSaved(file, replacing: session) }.controlSize(.small)
                    .help(L("Watch the downloaded file instead of the link (it can then be edited)."))
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help(L("Show in Finder")).accessibilityLabel(L("Show in Finder"))
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(message).accessibilityLabel(message)
                Text(L("Not downloaded")).font(.caption).foregroundColor(.secondary).help(message)
                Button(L("Try Again")) { LinkActions.save(session) }.controlSize(.small)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let r = remote {
                Button(L("Copy Link")) { LinkActions.copy(r.link.absoluteString) }
                Button(L("Open Link in Browser")) { NSWorkspace.shared.open(r.link) }
                if r.canSave {
                    Divider()
                    Button(L("Download…")) { LinkActions.save(session) }.disabled(linkSave.isSaving)
                }
            } else if let u = session.localFileURL {
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                Button(L("Copy Path")) { LinkActions.copy(u.path) }
                Divider()
                Button(L("Edit…")) { onEdit() }
                Button(L("Rename File…")) { onRename() }
                Button(L("Move File to Trash…")) { onTrash() }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("More")).accessibilityLabel(L("More"))
    }
}

/// The second line of the bar: size, rate, length and file size, or where a link comes from. Follows the player, which learns
/// a link's size and length as it connects.
private struct SummaryLine: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var player: PlayerController
    var body: some View {
        HStack(spacing: 6) {
            if player.isLive { SoloBadge(text: L("LIVE"), color: .red, dot: true) }
            Text(session.mediaSummary).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// The icon of the "Edit" button: scissors for a video or a sound (it goes on a timeline to be cut and put together), a magic wand for a
/// photo (colour, crop, effects). Only symbols this macOS has: `pencil.and.scissors` does not exist and showed no icon at all (0.16.1).
@MainActor
enum EditButtonIcon {
    static func name(for s: EditorSession) -> String { s.isPhoto ? "wand.and.stars" : "scissors" }
    static let all = ["scissors", "wand.and.stars"]
}

struct SoloBadge: View {
    let text: String
    let color: Color
    var dot = false
    var body: some View {
        HStack(spacing: 3) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.4)
        }
        .foregroundColor(color)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .accessibilityLabel(text)
    }
}

// MARK: Over the picture of a link

/// While a link connects or waits for data: a spinner; when it fails: why, with Try Again. Lets the mouse through otherwise.
struct LinkOverlay: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var player: PlayerController
    @StateObject private var shown = Box<Bool>(false)

    private var host: String { session.remote?.host ?? "" }

    var body: some View {
        ZStack {
            if let failure = player.failure {
                errorCard(failure).transition(.opacity)
            } else if shown.value, !player.isReady || player.isWaiting {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular).colorScheme(.dark)
                    Text(player.isReady ? L("Waiting for data…") : LF("Connecting to %@…", host))
                        .font(.callout).foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.55)))
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: player.failure)
        .animation(.easeOut(duration: 0.18), value: player.isWaiting)
        // A spinner that would only flash for a moment is not shown at all.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { shown.value = true } }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 30, weight: .medium)).foregroundColor(.orange)
            Text(L("This link cannot be played")).font(.headline).foregroundColor(.white)
            Text(text).font(.callout).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button(L("Try Again")) { Task { await session.retryRemote() } }.keyboardShortcut(.defaultAction)
                if let r = session.remote { Button(L("Copy Link")) { LinkActions.copy(r.link.absoluteString) } }
            }
            .padding(.top, 2)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.7)))
        .padding(20)
    }
}

/// A SwiftUI overlay that lets clicks and drops through to the picture below, except where it shows something to click.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var takesClicks: () -> Bool = { false }
    override func hitTest(_ point: NSPoint) -> NSView? { takesClicks() ? super.hitTest(point) : nil }
}

// MARK: What can be done with a link

@MainActor
enum LinkActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "Download…": asks where (the Downloads folder first), then fetches the file there. A file chosen to be replaced goes to the
    /// Trash first, never deleted.
    static func save(_ s: EditorSession) {
        guard let r = s.remote, r.canSave, !s.linkSave.isSaving else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MediaLink.suggestedFileName(for: r.link, kind: r.kind, contentType: r.contentType)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = L("The file is downloaded from the link to this place.")
        panel.prompt = L("Download")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if FileManager.default.fileExists(atPath: dest.path) {
            do { try FileActions.trasher(dest) } catch {
                s.flash(LF("“%@” is already there and could not be moved to the Trash.", dest.lastPathComponent), error: true); return
            }
        }
        // A photo is already on the Mac (in the cache): it is copied, not fetched again.
        if r.kind == .photo, let cached = s.sourceURL, FileManager.default.fileExists(atPath: cached.path) {
            do { try FileManager.default.copyItem(at: cached, to: dest); s.linkSave.markSaved(dest) }
            catch { s.flash(LF("The file could not be written: %@", error.localizedDescription), error: true) }
            return
        }
        s.linkSave.start(r, to: dest)
    }

    /// Watches the downloaded file in this window instead of the link, at the same moment.
    static func openSaved(_ file: URL, replacing s: EditorSession) {
        guard let app = NSApp.delegate as? AppDelegate, let w = app.controllers.first(where: { $0.session === s }) else { return }
        let at = s.player.currentTime, playing = s.player.isPlaying
        Task {
            guard await w.openSolo(url: file, autoplay: false), let fresh = w.session, !fresh.isPhoto else { return }
            if at > .zero { await fresh.player.seek(to: at) }
            if playing { fresh.player.play() }
        }
    }
}

extension LinkSave {
    func markSaved(_ url: URL) { setSaved(url) }
}
