import AppKit
import SwiftUI
import MacPlayerCore

// MARK: Home

/// The first screen: two big doors. Watching (playlists) and editing (projects) never mix.
struct HomeView: View {
    var openPlaylists: () -> Void
    var openProjects: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("MacPlayer").font(.system(size: 34, weight: .bold))
                Text(L("What would you like to do?")).font(.title3).foregroundColor(.secondary)
            }
            HStack(spacing: 24) {
                HomeCard(icon: "play.rectangle.on.rectangle", tint: .accentColor, title: L("Playlists"),
                         subtitle: L("Watch videos and photos. Rename or tidy files."), shortcut: "⌘1", action: openPlaylists)
                HomeCard(icon: "slider.horizontal.below.rectangle", tint: .orange, title: L("Editing"),
                         subtitle: L("Your video and photo projects. Saved as you work."), shortcut: "⌘2", action: openProjects)
            }
            Text(L("Or drop videos, photos, a folder or a project here.")).font(.callout).foregroundColor(.secondary)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct HomeCard: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let shortcut: String
    let action: () -> Void
    @StateObject private var hover = Box<Bool>(false)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 54, weight: .regular)).foregroundColor(tint).frame(height: 64)
                Text(title).font(.title2.weight(.semibold)).foregroundColor(.primary)
                Text(subtitle).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(shortcut).font(.caption.monospaced()).foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .padding(26).frame(width: 260, height: 250)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(hover.value ? tint : Color.secondary.opacity(0.25), lineWidth: hover.value ? 2 : 1))
            .shadow(color: .black.opacity(hover.value ? 0.12 : 0.05), radius: hover.value ? 10 : 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

/// A small "back to the start" button for the top of a screen.
struct HomeButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) { Label(L("Home"), systemImage: "house") }
            .help(L("Back to the start screen (⇧⌘H)")).accessibilityLabel(L("Home"))
    }
}

// MARK: Playlists, nothing playing

struct PlaylistStartView: View {
    var open: () -> Void
    var openFolder: () -> Void
    var openURL: (URL) -> Void
    var home: () -> Void
    @StateObject private var refresh = Box<Int>(0)

    var body: some View {
        let _ = refresh.value      // read so that the view is rebuilt when the recent list is cleared
        let recents = Array(NSDocumentController.shared.recentDocumentURLs.filter { !ProjectFile.isProject($0) }.prefix(8))
        VStack(spacing: 0) {
            HStack { HomeButton(action: home); Spacer() }.padding(10)
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 54)).foregroundColor(.accentColor).accessibilityHidden(true)
                Text(L("Playlists")).font(.largeTitle.bold())
                Text(L("Watch videos and photos. Nothing here changes your files, except renaming or moving one to the Trash when you ask.")).font(.callout).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack {
                    Button(L("Open a Video or Photo…")) { open() }.controlSize(.large).keyboardShortcut(.defaultAction)
                    Button(L("Open a Folder as Playlist…")) { openFolder() }.controlSize(.large)
                }
                Text(L("Or drop a video, photo or folder here.")).font(.callout).foregroundColor(.secondary)
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Recent")).font(.headline)
                        ForEach(recents, id: \.self) { u in
                            Button { openURL(u) } label: { Label(u.lastPathComponent, systemImage: ImageFiles.isCandidate(u.path) ? "photo" : "film").lineLimit(1) }.buttonStyle(.link)
                        }
                    }.frame(maxWidth: 360, alignment: .leading).padding(.top, 6)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(NSColor.windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .recentsChanged)) { _ in refresh.value += 1 }
    }
}

// MARK: The list of projects

final class ProjectsViewState: ObservableObject {
    @Published var query = ""
    @Published var selected: UUID?
}

struct ProjectsView: View {
    @ObservedObject var projects: ProjectsController
    var home: () -> Void
    @StateObject private var state = ProjectsViewState()
    @StateObject private var filter = Box<ProjectFilter>(AppEnvironment.shared.prefs.projectFilter)
    @StateObject private var sort = Box<ProjectSort>(AppEnvironment.shared.prefs.projectSort)

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    var body: some View {
        let _ = projects.version
        let list = projects.visible(filter: filter.value, sort: sort.value, query: state.query)
        VStack(spacing: 0) {
            toolbar
            Divider()
            if list.isEmpty { empty } else { grid(list) }
            if projects.registry.inTrashCount > 0 {
                Divider()
                Text(LF("%d projects are in the Trash. Put one back in Finder to see it here again.", projects.registry.inTrashCount))
                    .font(.caption).foregroundColor(.secondary).padding(6)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HomeButton(action: home)
            Text(L("Projects")).font(.title2.bold()).padding(.leading, 4)
            Spacer()
            Picker("", selection: Binding(get: { filter.value }, set: { filter.value = $0; AppEnvironment.shared.prefs.projectFilter = $0 })) {
                Text(L("All")).tag(ProjectFilter.all)
                Label(L("Video"), systemImage: "film").tag(ProjectFilter.video)
                Label(L("Photo"), systemImage: "photo").tag(ProjectFilter.photo)
            }.pickerStyle(.segmented).frame(width: 220).labelsHidden().accessibilityLabel(L("Show"))
            Menu {
                Picker(L("Sort by"), selection: Binding(get: { sort.value }, set: { sort.value = $0; AppEnvironment.shared.prefs.projectSort = $0 })) {
                    Text(L("Last edited")).tag(ProjectSort.modified); Text(L("Name")).tag(ProjectSort.name); Text(L("Date created")).tag(ProjectSort.created)
                }.pickerStyle(.inline)
            } label: { Image(systemName: "arrow.up.arrow.down") }.frame(width: 44).help(L("Sort")).accessibilityLabel(L("Sort"))
            TextField(L("Search"), text: $state.query).textFieldStyle(.roundedBorder).frame(width: 170)
            Menu {
                Button(L("Open a Project File…")) { app?.openProjectFile(nil) }
            } label: { Image(systemName: "ellipsis.circle") }.frame(width: 44).help(L("More")).accessibilityLabel(L("More"))
            Button { app?.newProject(nil) } label: { Label(L("New Project"), systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large).help(L("Make a new video or photo project (⌘N)"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack.3d.up").font(.system(size: 48)).foregroundColor(.secondary).accessibilityHidden(true)
            Text(state.query.isEmpty ? L("No projects yet.") : LF("No project matches “%@”.", state.query)).font(.title3)
            if state.query.isEmpty {
                Text(L("A project keeps your edits of a video or a photo. Your original files are never changed.")).foregroundColor(.secondary)
                Button { app?.newProject(nil) } label: { Label(L("New Project"), systemImage: "plus") }.controlSize(.large).buttonStyle(.borderedProminent)
                Text(L("Or drop a .macplayer file here.")).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func grid(_ list: [ProjectEntry]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)], spacing: 16) {
                ForEach(list) { e in
                    ProjectCard(entry: e, image: projects.thumbnail(e.projectID), selected: state.selected == e.id)
                        .onTapGesture(count: 2) { app?.openProject(entry: e) }.clickable()
                        .simultaneousGesture(TapGesture().onEnded { state.selected = e.id })
                        .contextMenu { menu(e) }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func menu(_ e: ProjectEntry) -> some View {
        Button(L("Open")) { app?.openProject(entry: e) }.disabled(!(e.status == .ok))
        Button(L("Rename…")) { app?.renameProject(entry: e) }.disabled(e.status != .ok)
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }.disabled(e.status != .ok && e.status != .unreadable)
        if e.status == .missing { Button(L("Find…")) { app?.findProject(entry: e) } }
        Divider()
        if e.status == .ok || e.status == .unreadable || e.status == .newerVersion {
            Button(L("Move to Trash…")) { app?.trashProject(entry: e) }
        }
        Button(L("Remove from List")) { app?.forgetProject(entry: e) }
    }
}

struct ProjectCard: View {
    let entry: ProjectEntry
    let image: NSImage?
    let selected: Bool

    private var subtitle: String {
        switch entry.status {
        case .missing: return L("File not found")
        case .driveOffline: return L("Drive not connected")
        case .inTrash: return L("In the Trash")
        case .unreadable: return L("Cannot be read")
        case .newerVersion: return L("Made by a newer MacPlayer")
        case .ok: break
        }
        if entry.kind == .photo {
            if let w = entry.photoWidth, let h = entry.photoHeight { return "\(w) × \(h)" }
            return entry.sourcePaths.isEmpty ? L("No photo yet") : L("Photo")
        }
        return entry.clipCount == 0 ? L("Empty") : LF("%d clips · %@", entry.clipCount, Format.duration(MediaTime(seconds: entry.seconds)))
    }

    private var edited: String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: entry.modified, relativeTo: Date())
    }

    var body: some View {
        let ok = entry.status == .ok
        VStack(alignment: .leading, spacing: 0) {
            // The picture fills a box of fixed height; it never decides how wide the card is.
            Color.secondary.opacity(0.12)
                .frame(maxWidth: .infinity).frame(height: 130)
                .overlay {
                    if let image, ok { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: entry.kind == .photo ? "photo" : "film").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.6)) }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: entry.kind == .photo ? "photo" : "film")
                        Text(entry.kind == .photo ? L("Photo") : L("Video"))
                    }
                    .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(entry.kind == .photo ? Color.purple.opacity(0.85) : Color.blue.opacity(0.85))).foregroundColor(.white)
                    .padding(8)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if !ok { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange) }
                    Text(subtitle).lineLimit(1)
                }.font(.caption).foregroundColor(ok ? .secondary : .orange)
                HStack(spacing: 6) {
                    Text(edited).lineLimit(1)
                    if ok, entry.missingSources > 0 { Text("· " + LF("%d missing", entry.missingSources)).foregroundColor(.orange) }
                    if entry.olderFormat { Text("· " + L("older format")).help(L("Written by an older MacPlayer. It is upgraded when opened; a copy of the old file is kept.")) }
                }.font(.caption2).foregroundColor(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(ok ? 1 : 0.75)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LF("%@ project %@, %@, edited %@", entry.kind == .photo ? L("Photo") : L("Video"), entry.name, subtitle, edited))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Editor

/// Above the picture of a project: back to the list, the project's name (click to rename), and where saving stands.
struct EditorHeader: View {
    @ObservedObject var session: EditorSession
    var onBack: () -> Void
    /// A video project: the Export button at the right.
    var onExport: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Label(L("Projects"), systemImage: "chevron.left") }
                .controlSize(.small).help(L("Back to the list of projects (⇧⌘W). Your edits are already saved."))
            Divider().frame(height: 16)
            Image(systemName: session.isPhoto ? "photo" : "film").foregroundColor(.secondary).accessibilityHidden(true)
            Text(session.projectPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? session.project.name)
                .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Button { (NSApp.delegate as? AppDelegate)?.renameCurrentProject(nil) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help(L("Rename the project")).accessibilityLabel(L("Rename the project"))
            Spacer(minLength: 8)
            saveStatus
            if let onExport {
                Button(action: onExport) { Label(L("Export"), systemImage: "square.and.arrow.up").padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent).controlSize(.regular).disabled(session.isPhoto ? session.project.sources.isEmpty : session.project.timeline.isEmpty)
                    .help(session.isPhoto ? L("Save the edited photo as a new file") : L("Make a video file of the project"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, onExport == nil ? 5 : 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder private var saveStatus: some View {
        if let why = session.readOnlyReason {
            Label(L("Read only"), systemImage: "lock.fill").font(.caption).foregroundColor(.orange).help(why)
        } else {
            switch session.saveState {
            case .saved(let d):
                Label(d.map { LF("Saved %@", DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)) } ?? L("Saved"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundColor(.secondary).help(L("Your edits are saved into the project file as you work."))
            case .pending, .saving:
                Label(L("Saving…"), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundColor(.secondary)
            case .failed(let m):
                HStack(spacing: 6) {
                    Label(L("Not saved"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange).help(m)
                    Button(L("Try Again")) { session.save() }.controlSize(.small)
                }
            case .externallyChanged:
                HStack(spacing: 6) {
                    Label(L("Changed outside MacPlayer"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange)
                    Button(L("Keep My Edits")) { Task { await session.resolveExternalChange(keepMine: true) } }.controlSize(.small)
                    Button(L("Use the File on Disk")) { Task { await session.resolveExternalChange(keepMine: false) } }.controlSize(.small)
                }
            }
        }
    }
}

/// On the picture of a video project without clips: what to do.
struct EmptyVideoProjectView: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if session.project.timeline.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "film.stack").font(.system(size: 42)).foregroundColor(.white.opacity(0.85))
                Text(L("This video project is empty.")).font(.title3.weight(.semibold)).foregroundColor(.white)
                Text(L("Drop videos here, or add them from your Mac.")).foregroundColor(.white.opacity(0.8))
                Button { (NSApp.delegate as? AppDelegate)?.addVideoToProject(nil) } label: { Label(L("Add Video…"), systemImage: "plus") }
                    .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .padding(24).background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
        }
    }
}

/// On a photo project without its photo: choose it.
struct EmptyPhotoProjectView: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        if session.project.sources.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo").font(.system(size: 42)).foregroundColor(.white.opacity(0.85))
                Text(L("This photo project has no photo yet.")).font(.title3.weight(.semibold)).foregroundColor(.white)
                Text(L("A photo project holds one photo. Drop it here, or choose it.")).foregroundColor(.white.opacity(0.8))
                Button { (NSApp.delegate as? AppDelegate)?.choosePhoto(nil) } label: { Label(L("Choose Photo…"), systemImage: "plus") }
                    .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .padding(24).background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
        }
    }
}
