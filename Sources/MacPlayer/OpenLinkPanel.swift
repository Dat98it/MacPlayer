import AppKit
import SwiftUI
import MacPlayerCore

/// File ▸ Open Link… (⌘U, 0.15): paste a link straight to a video, a stream or a photo and watch it in a window of its own.
/// The link is checked as it is typed (no network); the server is asked only on Open.
@MainActor
final class LinkPanelModel: ObservableObject {
    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            error = nil
            // Pasted (several characters at once): spaces and line breaks around it go, and only its first line is kept.
            if text.count > oldValue.count + 1 {
                let cleaned = Self.cleanPasted(text)
                if cleaned != text { text = cleaned; return }
            } else { pasted = false }
        }
    }

    /// What was pasted, as a link: the first line that is not empty, without the spaces around it.
    static func cleanPasted(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty } ?? s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @Published private(set) var opening = false
    /// What is happening while it opens ("Checking the link…", "Fetching the photo… 40%").
    @Published private(set) var step: String?
    @Published var error: String?
    @Published private(set) var recents: [String]
    /// The text field was filled from the clipboard.
    @Published var pasted = false
    private var task: Task<Void, Never>?
    var onOpened: (EditorSession) -> Void = { _ in }

    private var prefs: AppPreferences { AppEnvironment.shared.prefs }

    init() { recents = AppEnvironment.shared.prefs.recentLinks }

    var verdict: MediaLink.Verdict { MediaLink.check(text) }
    var canOpen: Bool { if case .ok = verdict { return !opening }; return false }

    /// Fills the field from the clipboard when it holds a link that can be opened.
    func pasteIfUseful() {
        guard text.isEmpty, let s = NSPasteboard.general.string(forType: .string), case .ok = MediaLink.check(s) else { return }
        text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        pasted = true
    }

    func open() {
        guard case .ok(let link) = verdict, !opening else { return }
        opening = true; error = nil; step = L("Checking the link…")
        task = Task {
            defer { opening = false; step = nil }
            do {
                let head = try await LinkFetcher.inspect(link)
                if Task.isCancelled { return }
                let source = RemoteSource(link: link.url, kind: head.kind, contentType: head.contentType, byteCount: head.byteCount, playbackMIME: head.sniffedMIME)
                var photo: URL?
                if head.kind == .photo {
                    if let n = head.byteCount, n > LinkFetcher.photoByteLimit { throw LinkError(LinkErrors.message(code: NSURLErrorDataLengthExceedsMaximum)) }
                    step = L("Fetching the photo…")
                    photo = try await LinkFetcher.fetchPhoto(link.url, contentType: head.contentType) { [weak self] f in
                        if f >= 0 { self?.step = LF("Fetching the photo… %d%%", Int((f * 100).rounded())) }
                    }
                }
                if Task.isCancelled { if let p = photo { try? FileManager.default.removeItem(at: p) }; return }
                step = L("Opening…")
                let s: EditorSession
                do { s = try await EditorSession.openRemote(source, photoFile: photo) }
                catch {
                    if let p = photo { try? FileManager.default.removeItem(at: p) }
                    throw LinkError(head.kind == .photo ? L("The file at this link is not a photo this Mac can show.") : LinkErrors.describe(error))
                }
                remember(link.url.absoluteString)
                onOpened(s)
            } catch {
                if !Task.isCancelled { self.error = LinkErrors.describe(error) }
            }
        }
    }

    func cancelOpening() { task?.cancel(); task = nil; opening = false; step = nil }

    func remember(_ link: String) { recents = RecentLinks.adding(link, to: recents); prefs.recentLinks = recents }
    func forget(_ link: String) { recents = RecentLinks.removing(link, from: recents); prefs.recentLinks = recents }
    func forgetAll() { recents = []; prefs.recentLinks = [] }
}

struct OpenLinkView: View {
    @ObservedObject var model: LinkPanelModel
    var close: () -> Void
    @StateObject private var showHelp = Box<Bool>(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                field
                status
            }
            .padding(.horizontal, 22).padding(.top, 16)
            if !model.recents.isEmpty { recents.padding(.horizontal, 22).padding(.top, 18) }
            helpSection.padding(.horizontal, 22).padding(.top, 14)
            Spacer(minLength: 14)
            Divider()
            footer.padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 580)
        .frame(minHeight: 330)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { model.pasteIfUseful() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "link").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: 42, height: 42).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Open a Video or Photo from a Link")).font(.title3.weight(.semibold))
                Text(L("Paste a link straight to a file, such as .mp4, .mov, .m3u8, .jpg or .png. It plays in a window of its own."))
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22).padding(.top, 6)
    }

    private var field: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "globe").foregroundColor(.secondary).accessibilityHidden(true)
                // Paste (⌘V, or right-click ▸ Paste) or type right here.
                TextField(L("Paste or type a link here (⌘V), e.g. https://example.com/video.mp4"), text: $model.text, onCommit: { if model.canOpen { model.open() } })
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .disabled(model.opening)
                    .accessibilityLabel(L("Link"))
                if !model.text.isEmpty && !model.opening {
                    Button { model.text = ""; model.pasted = false } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.borderless).help(L("Clear")).accessibilityLabel(L("Clear"))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(borderColor, lineWidth: 1))
        }
    }

    private var borderColor: Color {
        switch model.verdict {
        case .empty: return Color.secondary.opacity(0.3)
        case .ok: return model.error == nil ? Color.green.opacity(0.6) : Color.orange.opacity(0.7)
        case .page, .problem: return Color.orange.opacity(0.7)
        }
    }

    /// One line under the field: what the link is, or why it cannot be opened, or what is happening.
    @ViewBuilder private var status: some View {
        if let step = model.step {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step).font(.callout).foregroundColor(.secondary) }
        } else if let e = model.error {
            StatusLine(icon: "exclamationmark.triangle.fill", color: .orange, text: e)
        } else {
            switch model.verdict {
            case .empty:
                StatusLine(icon: "info.circle", color: .secondary, text: L("Links to YouTube, Facebook or TikTok pages do not work: they open a web page, not a file."))
            case .problem(.notWeb):
                StatusLine(icon: "exclamationmark.triangle.fill", color: .orange, text: L("Only web links (https://…) open here. To open a file on this Mac, use File ▸ Open… (⌘O)."))
            case .problem(.malformed):
                StatusLine(icon: "questionmark.circle", color: .secondary, text: L("This is not a complete link yet."))
            case .problem(.unsupported(let ext)):
                StatusLine(icon: "exclamationmark.triangle.fill", color: .orange, text: LF("%@ files cannot be played on this Mac. Use a link to an MP4, MOV or M3U8 file.", ext))
            case .page(let site):
                StatusLine(icon: "hand.raised.fill", color: .orange,
                           text: LF("This is a %@ page, not a link to a file. MacPlayer only plays links straight to a video or photo file.", site.name))
            case .ok(let link):
                VStack(alignment: .leading, spacing: 4) {
                    StatusLine(icon: "checkmark.circle.fill", color: .green, text: Self.describe(link))
                    if link.notes.contains(.dropboxMadeDirect) {
                        StatusLine(icon: "wand.and.stars", color: .secondary, text: L("This Dropbox link was changed to open the file itself."))
                    }
                    if link.notes.contains(.notEncrypted) {
                        StatusLine(icon: "lock.open", color: .secondary, text: L("An http:// link is not encrypted. Prefer https:// when the server offers it."))
                    }
                    if model.pasted { StatusLine(icon: "doc.on.clipboard", color: .secondary, text: L("Pasted from the clipboard.")) }
                }
            }
        }
    }

    static func describe(_ link: MediaLink.Link) -> String {
        let host = link.url.host ?? ""
        switch link.kind {
        case .video: return LF("A video or sound file on %@", host)
        case .stream: return LF("A stream (HLS) on %@ — it can be live", host)
        case .photo: return LF("A photo on %@", host)
        case .unknown: return LF("A file on %@ — MacPlayer will ask the server what it is", host)
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Recent Links")).font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                Button(L("Clear List")) { model.forgetAll() }.buttonStyle(.link).font(.caption)
                    .help(L("Forget these links. Nothing else is deleted."))
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.recents, id: \.self) { r in RecentLinkRow(link: r, open: { model.text = r; model.pasted = false; model.open() }, forget: { model.forget(r) }) }
                }
            }
            // Three rows show; more scroll.
            .frame(height: CGFloat(min(model.recents.count, 3)) * 44)
            .disabled(model.opening)
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showHelp.value.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showHelp.value ? 90 : 0))
                    Text(L("Which links work?")).font(.callout)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.accentColor)
            if showHelp.value {
                VStack(alignment: .leading, spacing: 5) {
                    HelpRow(ok: true, text: L("A link that opens only the video or photo in a browser, often ending in .mp4, .mov, .m3u8, .jpg or .png."))
                    HelpRow(ok: true, text: L("Files on your server or a CDN, an IP camera's HLS stream, a Dropbox share link."))
                    HelpRow(ok: false, text: L("Watch pages of YouTube, Facebook, TikTok, Instagram or Google Drive."))
                    HelpRow(ok: false, text: L("MKV, WebM, AVI and links that need a sign-in."))
                    Text(L("MacPlayer connects to the Internet only to open a link you give it. Nothing else is sent."))
                        .font(.caption).foregroundColor(.secondary).padding(.top, 2)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
                .transition(.opacity)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(L("Return opens · Esc closes")).font(.caption).foregroundColor(.secondary)
            Spacer()
            if model.opening {
                Button(L("Stop")) { model.cancelOpening() }
            } else {
                Button(L("Cancel")) { close() }.keyboardShortcut(.cancelAction)
            }
            Button {
                model.open()
            } label: { Text(model.opening ? L("Opening…") : L("Open")).frame(minWidth: 70) }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canOpen)
        }
    }
}

private struct StatusLine: View {
    let icon: String
    let color: Color
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 12))
            Text(text).font(.callout).foregroundColor(color == .secondary ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HelpRow: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ok ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(ok ? .green : .red).frame(width: 12)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecentLinkRow: View {
    let link: String
    var open: () -> Void
    var forget: () -> Void
    @StateObject private var hover = Box<Bool>(false)

    private var parsed: MediaLink.Link? { if case .ok(let l) = MediaLink.check(link) { return l }; return nil }
    private var icon: String {
        switch parsed?.kind { case .stream?: return "dot.radiowaves.left.and.right"; case .photo?: return "photo"; default: return "film" }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(parsed?.displayName ?? link).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(link.removingPercentEncoding ?? link).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if hover.value {
                Button(action: forget) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).help(L("Remove from the list")).accessibilityLabel(L("Remove from the list"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover.value ? Color.accentColor.opacity(0.1) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open).clickable()
        .onHover { hover.value = $0 }
        .help(link)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityHint(L("Opens this link"))
    }
}

/// The window of File ▸ Open Link…: one at a time, brought back to the front when asked again.
@MainActor
final class LinkPanel: NSObject, NSWindowDelegate {
    static let shared = LinkPanel()
    private var window: NSWindow?
    private(set) var model: LinkPanelModel?

    func show(text: String? = nil) {
        if let w = window {
            if let t = text { model?.text = t; model?.pasted = false }
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            focusField()
            return
        }
        let m = LinkPanelModel()
        if let t = text { m.text = t }
        model = m
        let host = NSHostingController(rootView: OpenLinkView(model: m, close: { [weak self] in self?.close() }))
        // The window follows its content (a longer message, the recent links, the help opened).
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.title = L("Open Link")
        w.isReleasedWhenClosed = false
        w.delegate = self
        m.onOpened = { [weak self] s in
            guard let app = NSApp.delegate as? AppDelegate else { return }
            self?.close()
            let target = app.soloTarget()
            target.showSolo(s)
            target.window?.makeKeyAndOrderFront(nil)
        }
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusField()
    }

    /// The link field takes the keyboard at once, so ⌘V pastes into it (and a link already there is selected, to be replaced).
    func focusField() {
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.window, let field = Self.textField(in: w.contentView) else { return }
            w.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.selectAll(nil)
        }
    }

    private static func textField(in v: NSView?) -> NSTextField? {
        guard let v else { return nil }
        if let f = v as? NSTextField, f.isEditable { return f }
        for sub in v.subviews { if let f = textField(in: sub) { return f } }
        return nil
    }

    /// The text field's editor while it has the keyboard (for the self-test: paste goes through it as ⌘V does).
    var fieldEditor: NSTextView? { window?.firstResponder as? NSTextView }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        model?.cancelOpening()
        window = nil; model = nil
    }

    var isOpen: Bool { window != nil }
    var panelWindow: NSWindow? { window }
}
