import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import MacPlayerCore
import MacPlayerMedia

/// What can be dragged from the library onto the timeline besides files: a filter or a transition (dropped on a clip or a cut), a text
/// style or a sticker (dropped at a time). Carried as plain text, so it needs no registered type.
enum DragPayload: Equatable {
    case filter(FilterPreset), transition(TransitionKind), text(TextTemplate?), sticker(String), shape(ShapeKind), preset(TextPreset)

    static let prefix = "macplayer:"
    var string: String {
        switch self {
        case .filter(let p): return Self.prefix + "filter:" + p.rawValue
        case .transition(let k): return Self.prefix + "transition:" + k.rawValue
        case .text(let t): return Self.prefix + "text:" + (t?.rawValue ?? "plain")
        case .sticker(let e): return Self.prefix + "sticker:" + e
        case .shape(let k): return Self.prefix + "shape:" + k.rawValue
        case .preset(let p): return Self.prefix + "preset:" + p.rawValue
        }
    }
    static func parse(_ s: String) -> DragPayload? {
        guard s.hasPrefix(prefix) else { return nil }
        let parts = s.dropFirst(prefix.count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "filter": return FilterPreset(rawValue: parts[1]).map { .filter($0) }
        case "transition": return TransitionKind(rawValue: parts[1]).map { .transition($0) }
        case "text": return .text(TextTemplate(rawValue: parts[1]))
        case "sticker": return .sticker(parts[1])
        case "shape": return ShapeKind(rawValue: parts[1]).map { .shape($0) }
        case "preset": return TextPreset(rawValue: parts[1]).map { .preset($0) }
        default: return nil
        }
    }
    var provider: NSItemProvider { NSItemProvider(object: string as NSString) }
    /// What a drag of it puts on the pasteboard (plain text).
    var writer: NSPasteboardWriting { string as NSString }

    /// What a library file carries when dragged: its file URL (the same as a file dragged from Finder).
    static func fileProvider(_ path: String) -> NSItemProvider { NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
}

enum LibraryTab: String, CaseIterable {
    case media, audio, text, filters, transitions
    var title: String {
        switch self {
        case .media: return L("Media"); case .audio: return L("Audio"); case .text: return L("Text")
        case .filters: return L("Filters"); case .transitions: return L("Transitions")
        }
    }
    var icon: String {
        switch self {
        case .media: return "photo.on.rectangle"; case .audio: return "music.note"; case .text: return "textformat"
        case .filters: return "camera.filters"; case .transitions: return "rectangle.2.swap"
        }
    }
}

/// The left panel of the video editor: everything that can be put into the project, ready to drag onto the timeline (or click to add).
struct LibraryPanel: View {
    @ObservedObject var session: EditorSession
    @StateObject private var tab = Box<LibraryTab>(LibraryTab(rawValue: ProcessInfo.processInfo.environment["MACPLAYER_LIBRARY_TAB"] ?? "") ?? .media)

    var body: some View {
        // A photo project: logos (pictures), text and filters; there is no time, so no sound or transitions.
        let tabs: [LibraryTab] = session.isPhoto ? [.media, .text, .filters] : LibraryTab.allCases
        let current = tabs.contains(tab.value) ? tab.value : tabs[0]
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { t in
                    Button { tab.value = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 15)).frame(height: 18)
                            Text(t == .media && session.isPhoto ? L("Pictures") : t.title).font(.system(size: 10.5, weight: current == t ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundColor(current == t ? .accentColor : .secondary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(current == t ? Color.accentColor.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(t.title).accessibilityAddTraits(current == t ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            Divider()
            ScrollView {
                Group {
                    switch current {
                    case .media: MediaLibrary(session: session, kinds: session.isPhoto ? [.photo] : [.video, .photo])
                    case .audio: AudioLibrary(session: session)
                    case .text: TextLibrary(session: session)
                    case .filters: FilterLibrary(session: session)
                    case .transitions: TransitionLibrary(session: session)
                    }
                }
                .padding(10)
            }
        }
        .background(Color(NSColor.underPageBackgroundColor).opacity(0.35))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { urls in session.importToLibrary(urls) }
            return true
        }
    }
}

/// Reads the file URLs out of dropped items, then hands them over on the main thread.
func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    final class Bag: @unchecked Sendable { var urls: [URL] = []; let lock = NSLock() }
    let bag = Bag(), group = DispatchGroup()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { bag.lock.lock(); bag.urls.append(url); bag.lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(bag.urls) } }
}

/// A small heading with a line of help under it.
private struct LibraryHeading: View {
    let title: String
    var hint: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            if let hint { Text(hint).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Media

/// Pictures and lengths of library files, read once and kept (shared by every window).
@MainActor
final class LibraryThumbs {
    static let shared = LibraryThumbs()
    var images: [String: NSImage] = [:]
    var durations: [String: Double] = [:]
    private var loading: Set<String> = []

    func load(_ item: BinItem) async -> (NSImage?, Double?) {
        let key = item.path
        if images[key] != nil || durations[key] != nil || loading.contains(key) { return (images[key], durations[key]) }
        loading.insert(key); defer { loading.remove(key) }
        let url = URL(fileURLWithPath: item.path)
        let kind = item.kind
        let size = CGSize(width: 260, height: 160)
        let (cg, secs): (CGImage?, Double?) = await Task.detached(priority: .utility) {
            switch kind {
            case .photo: return (PhotoLoader.thumbnail(url: url, maxSize: size), nil)
            case .video:
                let d = try? await AVURLAsset(url: url).load(.duration)
                let t = MediaTime(seconds: min(1, (d?.seconds ?? 0) / 2))
                return (try? await FrameGrabber.image(url: url, at: t, accuracy: .nearest, maxSize: size), d?.seconds)
            case .audio:
                let d = try? await AVURLAsset(url: url).load(.duration)
                return (nil, d?.seconds)
            }
        }.value
        if let cg { images[key] = NSImage(cgImage: cg, size: .zero) }
        if let secs, secs.isFinite { durations[key] = secs }
        return (images[key], durations[key])
    }
}

struct MediaLibrary: View {
    @ObservedObject var session: EditorSession
    let kinds: Set<BinKind>

    var body: some View {
        let items = session.project.libraryItems.filter { kinds.contains($0.kind) }
        VStack(alignment: .leading, spacing: 10) {
            Button { session.chooseLibraryFiles() } label: {
                Label(L("Import media"), systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(session.isPhoto ? L("Drag pictures here from Finder") : L("Drag videos and photos here from Finder")).font(.callout.weight(.medium)).multilineTextAlignment(.center)
                    Text(session.isPhoto ? L("Then drag one onto the photo to put it on as a logo. Your files are never copied or changed.") : L("Then drag them onto the timeline below. Your files are never copied or changed.")).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundColor(.secondary.opacity(0.5)))
            } else {
                Text(session.isPhoto ? L("Click + or drag a picture onto the photo to put it on as a logo.") : L("Drag onto the timeline, or click + to add: videos and photos at the end, sounds at the playhead.")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 10) {
                    ForEach(items, id: \.path) { item in MediaTile(session: session, item: item) }
                }
            }
        }
    }
}

struct MediaTile: View {
    @ObservedObject var session: EditorSession
    let item: BinItem
    @StateObject private var thumb: Box<NSImage?>
    @StateObject private var length: Box<Double?>

    init(session: EditorSession, item: BinItem) {
        self.session = session; self.item = item
        // A picture already read is shown at once, so a tile made again never blinks through its empty state.
        _thumb = StateObject(wrappedValue: Box(LibraryThumbs.shared.images[item.path]))
        _length = StateObject(wrappedValue: Box(LibraryThumbs.shared.durations[item.path]))
    }
    @StateObject private var hover = Box(false)

    var body: some View {
        let missing = !FileManager.default.fileExists(atPath: item.path)
        let used = session.project.uses(path: item.path)
        VStack(alignment: .leading, spacing: 3) {
            Color.clear.aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay(Group {
                    if let img = thumb.value { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                    else { ZStack { Rectangle().fill(Color.secondary.opacity(0.2)); Image(systemName: item.kind == .audio ? "waveform" : (item.kind == .photo ? "photo" : "film")).font(.title2).foregroundColor(.secondary) } }
                })
                .clipped().cornerRadius(6)
                .overlay(alignment: .bottomTrailing) {
                    if let d = length.value { Text(Format.duration(MediaTime(seconds: d))).font(.system(size: 9.5, weight: .semibold).monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(.black.opacity(0.65))).foregroundColor(.white).padding(4) }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        if used { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).background(Circle().fill(.white)).help(L("Used in the project")) }
                        if missing { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).help(L("The file is no longer at its location.")) }
                    }.font(.system(size: 12)).padding(4)
                }
                // Pressed and moved: dragged onto the picture or the timeline. Double-clicked: added.
                .libraryDrag(URL(fileURLWithPath: item.path) as NSURL, onClick: nil, onDoubleClick: { if !missing { add() } })
                .overlay(alignment: .topTrailing) {
                    if !missing {
                        Button { add() } label: { Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Color.accentColor) }
                            .buttonStyle(.plain).padding(3).help(L("Add to the project")).accessibilityLabel(LF("Add %@", item.name))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(hover.value ? 0.8 : 0), lineWidth: 1.5))
            Text(item.name).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle).foregroundColor(missing ? .red : .primary)
        }
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .contextMenu {
            Button(L("Add to the project")) { add() }.disabled(missing)
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }.disabled(missing)
            Divider()
            Button(L("Remove from Library")) { session.removeFromLibrary(item) }.disabled(used)
        }
        .help(item.name)
        .accessibilityElement(children: .combine).accessibilityLabel(item.name).accessibilityAddTraits(.isButton)
        .onAppear { MediaTile.appeared += 1 }
        .task(id: item.path) {
            guard thumb.value == nil || length.value == nil else { return }
            let (i, d) = await LibraryThumbs.shared.load(item)
            if thumb.value == nil { thumb.value = i }; if length.value == nil { length.value = d }
        }
    }

    private func add() { Task { await session.place([URL(fileURLWithPath: item.path)]) } }

    /// How many times a tile came on screen (for the self-test: playing must not make the tiles again).
    nonisolated(unsafe) static var appeared = 0
}

// MARK: Audio

struct AudioLibrary: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        let items = session.project.libraryItems.filter { $0.kind == .audio }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { session.chooseLibraryFiles() } label: { Label(L("Import"), systemImage: "plus").frame(maxWidth: .infinity) }
                Button { session.toggleVoiceRecording() } label: {
                    Label(session.recorder.isRecording ? L("Stop") : L("Record voice"), systemImage: session.recorder.isRecording ? "stop.circle.fill" : "mic.fill").frame(maxWidth: .infinity)
                }
                .tint(session.recorder.isRecording ? .red : nil)
            }
            .controlSize(.large)
            Button { session.chooseSounds(kind: .effect) } label: { Label(L("Add a sound effect…"), systemImage: "speaker.wave.2").frame(maxWidth: .infinity) }
            LibraryHeading(title: L("Music and sounds"), hint: items.isEmpty ? L("Import music or drag sound files here, then drag them onto the timeline.") : L("Drag onto the timeline at the time it should start, or click + to start at the playhead."))
            ForEach(items, id: \.path) { item in AudioRow(session: session, item: item) }
        }
    }
}

private struct AudioRow: View {
    @ObservedObject var session: EditorSession
    let item: BinItem
    @StateObject private var length = Box<Double?>(nil)

    var body: some View {
        let missing = !FileManager.default.fileExists(atPath: item.path)
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "music.note").frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.25)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle).foregroundColor(missing ? .red : .primary)
                    if let d = length.value { Text(Format.duration(MediaTime(seconds: d))).font(.caption.monospacedDigit()).foregroundColor(.secondary) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .libraryDrag(URL(fileURLWithPath: item.path) as NSURL, onClick: nil, onDoubleClick: { if !missing { Task { await session.place([URL(fileURLWithPath: item.path)]) } } })
            Button { Task { await session.place([URL(fileURLWithPath: item.path)]) } } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless).disabled(missing).help(L("Add at the playhead")).accessibilityLabel(LF("Add %@", item.name))
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .contextMenu {
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }.disabled(missing)
            Button(L("Remove from Library")) { session.removeFromLibrary(item) }.disabled(session.project.uses(path: item.path))
        }
        .task(id: item.path) { let (_, d) = await LibraryThumbs.shared.load(item); length.value = d }
    }
}

// MARK: Text

/// The groups of the library's Text tab, one at a time (0.14.1: shown all together they made a very long list to scroll).
enum TextLibrarySection: String, CaseIterable {
    case styles, presets, shapes, stickers
    var title: String {
        switch self { case .styles: return L("Styles"); case .presets: return L("Presets"); case .shapes: return L("Shapes"); case .stickers: return L("Stickers") }
    }
    /// The group open last (kept while the app runs, for every window).
    nonisolated(unsafe) static var last: TextLibrarySection = TextLibrarySection(rawValue: ProcessInfo.processInfo.environment["MACPLAYER_TEXT_SECTION"] ?? "") ?? .styles
}

struct TextLibrary: View {
    @ObservedObject var session: EditorSession
    @StateObject private var section = Box<TextLibrarySection>(TextLibrarySection.last)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { session.addText(nil) } label: { Label(L("Add text"), systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            // Own tabs, which share the panel's width: the system's segmented control asked for more width than a narrow panel has and
            // pushed the whole column out of it.
            HStack(spacing: 2) {
                ForEach(TextLibrarySection.allCases, id: \.self) { t in
                    let on = section.value == t
                    Button { section.value = t; TextLibrarySection.last = t } label: {
                        Text(t.title).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .foregroundColor(on ? .white : .primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
            .accessibilityElement(children: .contain).accessibilityLabel(L("Show"))
            Text(hint).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            switch section.value {
            case .styles:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(TextTemplate.allCases, id: \.self) { t in
                        TextStyleTile(template: t)
                            .libraryDrag(DragPayload.text(t).writer) { session.addText(t) }
                            .accessibilityLabel(TextPane.templateName(t))
                    }
                }
            case .presets:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(TextPreset.allCases, id: \.self) { p in
                        let o = p.make()
                        TextLookTile(overlay: o, sample: o.text, name: p.name)
                            .libraryDrag(DragPayload.preset(p).writer) { session.addPreset(p) }
                            .accessibilityLabel(p.name)
                    }
                }
            case .shapes:
                // With room to spare now, each shape is shown bigger, with its name.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(ShapeKind.allCases, id: \.self) { k in
                        VStack(spacing: 4) {
                            Image(systemName: TextPane.shapeIcon(k)).font(.system(size: 26)).foregroundColor(color(k.defaultFillHex))
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                            Text(TextPane.shapeName(k)).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .contentShape(Rectangle())
                        .libraryDrag(DragPayload.shape(k).writer) { session.addShape(k) }
                        .help(TextPane.shapeName(k)).accessibilityLabel(TextPane.shapeName(k))
                    }
                }
            case .stickers:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(TextPane.stickers, id: \.self) { e in
                        Text(e).font(.system(size: 28)).frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                            .libraryDrag(DragPayload.sticker(e).writer) { session.addSticker(e) }
                            .accessibilityLabel(LF("Sticker %@", e))
                    }
                }
            }
        }
    }

    private var hint: String {
        switch section.value {
        case .presets: return L("With their words already in: double-click on the picture to change them.")
        case .shapes, .stickers: return session.isPhoto ? L("Click to add, or drag onto the photo where it should go.") : L("Click to add at the playhead, or drag onto the picture where it should go.")
        default: return session.isPhoto ? L("Click to add, or drag onto the photo where it should go. Then double-click it on the photo to type.")
                                       : L("Click to add at the playhead, or drag onto the picture where it should go (or onto the timeline). Then double-click it on the picture to type.")
        }
    }
}

/// A preview of a text style: its name drawn roughly the way the style looks.
private struct TextStyleTile: View {
    let template: TextTemplate
    var body: some View {
        let o: TextOverlay = { var o = TextOverlay(text: "Aa", start: .zero, end: MediaTime(seconds: 1)); template.apply(to: &o); return o }()
        TextLookTile(overlay: o, sample: "Aa", name: TextPane.templateName(template), size: 22)
    }
}

/// A small picture of a text's look: its words (or a sample) in its font, colour, background, outline and glow.
private struct TextLookTile: View {
    let overlay: TextOverlay
    let sample: String
    let name: String
    var size: CGFloat = 16
    var body: some View {
        let o = overlay
        let colour = color(o.colorHex)
        let f = o.flair
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                Text((f?.uppercase ?? false) ? sample.uppercased() : sample).font(.custom(o.fontName, size: size)).foregroundColor(colour)
                    .tracking(CGFloat(f?.letterSpacing ?? 0) * size)
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .padding(.horizontal, o.backgroundHex == nil ? 4 : 7).padding(.vertical, o.backgroundHex == nil ? 0 : 2)
                    .background(o.backgroundHex.map { RoundedRectangle(cornerRadius: 5).fill(color($0)) })
                    .shadow(color: (f?.shadow ?? false) ? color(f?.shadowHex ?? "#000000") : .clear, radius: 4)
                    .padding(.horizontal, 5)
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            Text(name).font(.system(size: 10.5)).lineLimit(1)
        }
        .contentShape(Rectangle()).clickable()
    }
}

/// Ready-made texts with their words already in them: a subscribe button, a sale badge, a "live" tag… (0.14). The words are in the
/// person's language and can be typed over (double-click on the picture).
enum TextPreset: String, CaseIterable {
    case subscribe, live, new, sale, likeShare, follow, comingSoon, thanks, location, breaking

    var name: String {
        switch self {
        case .subscribe: return L("Subscribe button"); case .live: return L("Live tag"); case .new: return L("New badge"); case .sale: return L("Sale badge")
        case .likeShare: return L("Like and share"); case .follow: return L("Follow me"); case .comingSoon: return L("Coming soon"); case .thanks: return L("Thanks for watching")
        case .location: return L("Place"); case .breaking: return L("Breaking news")
        }
    }

    /// The text as it goes on the picture (time and place are set by whoever adds it).
    func make() -> TextOverlay {
        var o = TextOverlay(text: "", start: .zero, end: MediaTime(seconds: 3))
        func look(_ t: TextTemplate) { t.apply(to: &o) }
        switch self {
        case .subscribe:
            look(.sale); o.text = L("SUBSCRIBE"); o.fontName = "HelveticaNeue-Bold"; o.backgroundHex = "#FF0000"; o.sizeFraction = 0.065; o.y = 0.8
        case .live:
            look(.pill); o.text = L("● LIVE"); o.backgroundHex = "#FF3B30"; o.fontName = "HelveticaNeue-Bold"; o.x = 0.12; o.y = 0.1
        case .new:
            look(.highlight); o.text = L("NEW"); o.fontName = "AvenirNext-Heavy"; o.sizeFraction = 0.08
        case .sale:
            look(.sale); o.text = L("SALE 50%")
        case .likeShare:
            look(.pill); o.text = L("Like & share 👍"); o.backgroundHex = "#0A84FF"; o.sizeFraction = 0.05; o.y = 0.82
        case .follow:
            look(.hashtag); o.text = L("Follow @yourname"); o.y = 0.86
        case .comingSoon:
            look(.elegant); o.text = L("Coming soon")
        case .thanks:
            look(.handwritten); o.text = L("Thanks for watching!")
        case .location:
            look(.lowerThird); o.text = L("📍 Place name"); o.backgroundHex = "#1C1C1E"
        case .breaking:
            look(.lowerThird); o.text = L("BREAKING NEWS"); o.backgroundHex = "#D70015"; o.fontName = "HelveticaNeue-CondensedBlack"; o.sizeFraction = 0.06
        }
        return o
    }
}

// MARK: Filters

struct FilterLibrary: View {
    @ObservedObject var session: EditorSession
    @StateObject private var tiles = Box<[FilterPreset: NSImage]>([:])

    var body: some View {
        let clip = session.selectedClipIDs.first
        let photo = session.isPhoto
        VStack(alignment: .leading, spacing: 10) {
            LibraryHeading(title: L("Filters"), hint: photo ? L("Click a filter to put it on the photo, or drag it onto the photo.") : clip == nil ? L("Drag a filter onto a clip on the timeline, or select a clip and click a filter.") : L("Click a filter to put it on the selected clip, or drag it onto any clip."))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(FilterPreset.allCases, id: \.self) { p in
                    let current = (photo || clip != nil) && session.project.activeLook.effects.filter == p
                    LookTile(image: tiles.value[p], name: EffectsPane.name(p), selected: current)
                    .libraryDrag(DragPayload.filter(p).writer) {
                        if photo { session.applyPhotoFilter(p); return }
                        guard let id = session.selectedClipIDs.first else { session.flash(L("Select a clip on the timeline first, or drag the filter onto it."), error: true); return }
                        session.applyFilter(p, toClip: id)
                    }
                    .accessibilityLabel(EffectsPane.name(p)).accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .task(id: "\(session.project.activeClipID?.uuidString ?? "")|\(session.project.timeline.count)|\(session.project.sources.first?.path ?? "")") { await load() }
    }

    private func load() async {
        guard let (frame, key) = await session.toolFrame(maxSize: CGSize(width: 180, height: 120)) else { return }
        let tileKey = "filters|" + key
        if let cached = ToolFrameCache.shared.tiles[tileKey] {
            tiles.value = Dictionary(uniqueKeysWithValues: FilterPreset.allCases.compactMap { p in cached[p.rawValue].map { (p, $0) } }); return
        }
        final class Frame: @unchecked Sendable { let image: CGImage; init(_ i: CGImage) { image = i } }
        let f = Frame(frame)
        let drawn = await EditorSession.drawOffMain(FilterPreset.allCases) { p in var e = LookEffects(); e.filter = p; return EffectPreview.image(from: f.image, effects: e) }
        if Task.isCancelled { return }
        tiles.value = drawn
        ToolFrameCache.shared.rememberTiles(Dictionary(uniqueKeysWithValues: drawn.map { ($0.key.rawValue, $0.value) }), for: tileKey)
    }
}

/// A picture with a name under it, outlined when it is the current choice.
struct LookTile: View {
    let image: NSImage?
    let name: String
    var selected = false
    var body: some View {
        VStack(spacing: 3) {
            Color.clear.aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay(Group { if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(Color.secondary.opacity(0.22)) } })
                .clipped().cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0))
            Text(name).font(.system(size: 10.5, weight: selected ? .semibold : .regular)).lineLimit(1)
        }
        .contentShape(Rectangle()).clickable()
    }
}

// MARK: Transitions

struct TransitionLibrary: View {
    @ObservedObject var session: EditorSession
    @StateObject private var tiles = Box<[TransitionKind: NSImage]>([:])

    var body: some View {
        let index = session.selectedClipIDs.first.flatMap { id in session.project.timeline.firstIndex { $0.id == id } }
        VStack(alignment: .leading, spacing: 10) {
            LibraryHeading(title: L("Transitions"), hint: L("Drag a transition onto the cut between two clips. Or select the clip after the cut and click a transition."))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(TransitionKind.allCases, id: \.self) { k in
                    let current = (index ?? 0) > 0 && session.project.activeLook.transitionIn?.kind == k
                    LookTile(image: tiles.value[k], name: TransitionsPane.name(k), selected: current)
                    .libraryDrag(DragPayload.transition(k).writer) {
                        guard let id = session.selectedClipIDs.first else { session.flash(L("Select the clip after a cut first, or drag the transition onto the cut."), error: true); return }
                        session.applyTransition(k, intoClip: id)
                    }
                    .accessibilityLabel(TransitionsPane.name(k)).accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .task { await load() }
    }

    /// Each transition half way between two plain pictures (the same for every project, so drawn once).
    private func load() async {
        let key = "library-transitions"
        if let cached = ToolFrameCache.shared.tiles[key] {
            tiles.value = Dictionary(uniqueKeysWithValues: TransitionKind.allCases.compactMap { k in cached[k.rawValue].map { (k, $0) } }); return
        }
        let drawn = await EditorSession.drawOffMain(TransitionKind.allCases) { k in
            guard let a = Self.card(top: (0.20, 0.45, 0.95), bottom: (0.10, 0.20, 0.55)), let b = Self.card(top: (1.0, 0.62, 0.20), bottom: (0.85, 0.25, 0.30)) else { return nil }
            return EffectPreview.transition(from: a, to: b, kind: k, progress: 0.5)
        }
        tiles.value = drawn
        ToolFrameCache.shared.rememberTiles(Dictionary(uniqueKeysWithValues: drawn.map { ($0.key.rawValue, $0.value) }), for: key)
    }

    /// A small picture: a gradient with a white disc, so movement and blending show.
    nonisolated static func card(top: (Double, Double, Double), bottom: (Double, Double, Double)) -> CGImage? {
        let w = 180, h = 112
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colorComponents: [top.0, top.1, top.2, 1, bottom.0, bottom.1, bottom.2, 1].map { CGFloat($0) }, locations: [0, 1], count: 2)
        else { return nil }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 66, y: 32, width: 48, height: 48))
        return ctx.makeImage()
    }
}

// MARK: Dragging out of the library

extension View {
    /// Makes a library tile draggable with AppKit's own drag (what Finder uses): pressed and moved, it carries `writer` (a file URL or a
    /// `DragPayload` string) to the picture or the timeline; clicked, it runs `onClick`; double-clicked, `onDoubleClick` (else `onClick`).
    /// SwiftUI's `onDrag` on a button did not start reliably on macOS (0.12).
    func libraryDrag(_ writer: NSPasteboardWriting, onClick: (() -> Void)?, onDoubleClick: (() -> Void)? = nil) -> some View {
        overlay(LibraryDragSource(writer: writer, onClick: onClick, onDoubleClick: onDoubleClick))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { (onClick ?? onDoubleClick)?() }
    }
}

struct LibraryDragSource: NSViewRepresentable {
    let writer: NSPasteboardWriting
    let onClick: (() -> Void)?
    let onDoubleClick: (() -> Void)?
    func makeNSView(context: Context) -> LibraryDragSourceView { let v = LibraryDragSourceView(); update(v); return v }
    func updateNSView(_ v: LibraryDragSourceView, context: Context) { update(v) }
    private func update(_ v: LibraryDragSourceView) { v.writer = writer; v.onClick = onClick; v.onDoubleClick = onDoubleClick }
}

/// A transparent view over a library tile: a click is a click, a press that moves a few points starts a drag.
final class LibraryDragSourceView: NSView, NSDraggingSource {
    var writer: NSPasteboardWriting?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pressed: NSEvent?
    /// Drags started (for the self-test).
    nonisolated(unsafe) static var dragsStarted = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with e: NSEvent) { pressed = e }

    override func mouseDragged(with e: NSEvent) {
        guard let start = pressed, let writer else { return }
        let a = convert(start.locationInWindow, from: nil), b = convert(e.locationInWindow, from: nil)
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        pressed = nil
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: snapshot())
        Self.dragsStarted += 1
        beginDraggingSession(with: [item], event: start, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil }
        guard pressed != nil else { return }
        if e.clickCount >= 2, let onDoubleClick { onDoubleClick() } else if e.clickCount == 1 { onClick?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    /// What the tile looks like, to follow the pointer during the drag.
    private func snapshot() -> NSImage {
        guard let host = superview, let rep = host.bitmapImageRepForCachingDisplay(in: frame) else { return NSImage(size: bounds.size) }
        host.cacheDisplay(in: frame, to: rep)
        let img = NSImage(size: bounds.size); img.addRepresentation(rep)
        return img
    }
}

