import SwiftUI
import AppKit
import MacPlayerCore

/// What is typed in the sheet, and the new names that follow from it (worked out again after every change).
@MainActor
final class BatchRenameDraft: ObservableObject {
    @Published var rule = BatchRenameRule()
    @Published var failure: String?
    let request: BatchRenameRequest

    init(_ request: BatchRenameRequest) { self.request = request }

    var plan: [BatchRenameEntry] {
        BatchRename.plan(paths: request.paths, rule: rule, blocked: request.blocked, fs: AppEnvironment.shared.fs)
    }
}

/// Renaming the files that are chosen in a playlist: pick a way to name them, see every old and new name, then confirm.
struct BatchRenameSheet: View {
    @ObservedObject var model: PlaylistModel
    @StateObject private var draft: BatchRenameDraft

    init(model: PlaylistModel, request: BatchRenameRequest) {
        self.model = model
        _draft = StateObject(wrappedValue: BatchRenameDraft(request))
    }

    private func problemText(_ e: RenameError) -> String {
        switch e {
        case .exists: return L("This name is already taken")
        case .sourceMissing: return L("The file is not there any more.")
        case .emptyName: return L("The name is empty.")
        case .invalidCharacters: return L("A name cannot contain / or : or control characters.")
        case .hiddenName: return L("A name cannot start with a dot: the file would become hidden.")
        case .tooLong: return L("The name is too long.")
        case .sameName: return L("That is already its name.")
        case .failed(let m): return m
        }
    }

    var body: some View {
        let plan = draft.plan
        let renaming = plan.filter { $0.status == .willRename }.count
        let unchanged = plan.filter { $0.status == .unchanged }.count
        let blocked = plan.filter { if case .blocked = $0.status { return true } else { return false } }.count
        let problems = plan.filter { if case .problem = $0.status { return true } else { return false } }.count
        VStack(alignment: .leading, spacing: 12) {
            Text(LF("Rename %d files", plan.count)).font(.title3.bold())
            Text(L("The files on the disk are renamed, and each keeps its extension. Projects that use them by their old names will have to find them again."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $draft.rule.mode) {
                Text(L("Number them")).tag(BatchRenameRule.Mode.numbered)
                Text(L("Find and replace")).tag(BatchRenameRule.Mode.findReplace)
                Text(L("Add text")).tag(BatchRenameRule.Mode.prefixSuffix)
            }.pickerStyle(.segmented).labelsHidden()

            Group {
                switch draft.rule.mode {
                case .numbered:
                    TextField(L("Name (optional)"), text: $draft.rule.baseName).textFieldStyle(.roundedBorder)
                    HStack(spacing: 16) {
                        Stepper(LF("Start at %d", draft.rule.startNumber), value: $draft.rule.startNumber, in: 0...99_999)
                        Stepper(LF("At least %d digits", draft.rule.digits), value: $draft.rule.digits, in: 1...9)
                    }
                    Text(L("The files are numbered in the order they are listed in the playlist.")).font(.caption).foregroundColor(.secondary)
                case .findReplace:
                    TextField(L("Find"), text: $draft.rule.find).textFieldStyle(.roundedBorder)
                    TextField(L("Replace with (can be empty)"), text: $draft.rule.replacement).textFieldStyle(.roundedBorder)
                    Toggle(L("Ignore capital letters"), isOn: $draft.rule.ignoreCase)
                case .prefixSuffix:
                    TextField(L("Text before the name"), text: $draft.rule.prefix).textFieldStyle(.roundedBorder)
                    TextField(L("Text after the name"), text: $draft.rule.suffix).textFieldStyle(.roundedBorder)
                }
            }

            Text(L("Preview")).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(plan) { e in previewRow(e) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 210)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))

            summary(renaming: renaming, unchanged: unchanged, blocked: blocked, problems: problems)
            if let f = draft.failure { Label(f, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                Spacer()
                Button(L("Cancel")) { model.batchRename = nil }.keyboardShortcut(.cancelAction)
                Button(LF("Rename %d files", max(renaming, 0))) { run() }
                    .keyboardShortcut(.defaultAction).disabled(renaming == 0 || problems > 0)
            }
        }
        .padding(16).frame(width: 520)
    }

    private func previewRow(_ e: BatchRenameEntry) -> some View {
        let color: Color
        let note: String?
        switch e.status {
        case .willRename: color = .primary; note = nil
        case .unchanged: color = .secondary; note = L("No change")
        case .blocked(let why): color = .orange; note = why
        case .problem(let p): color = .red; note = problemText(p)
        }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(e.oldName).lineLimit(1).truncationMode(.middle).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary).accessibilityHidden(true)
                Text(e.newName).lineLimit(1).truncationMode(.middle).foregroundColor(color).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.callout)
            if let note { Text(note).font(.caption2).foregroundColor(e.status == .unchanged ? .secondary : color).lineLimit(2) }
        }
        .help(e.oldName + " → " + e.newName)
        .accessibilityElement(children: .combine)
    }

    private func summary(renaming: Int, unchanged: Int, blocked: Int, problems: Int) -> some View {
        var parts = [LF("%d will be renamed", renaming)]
        if unchanged > 0 { parts.append(LF("%d unchanged", unchanged)) }
        if blocked > 0 { parts.append(LF("%d in use, left out", blocked)) }
        if problems > 0 { parts.append(LF("%d with a problem", problems)) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(parts.joined(separator: " · ")).font(.callout)
            if problems > 0 { Text(L("Fix the names marked in red first: nothing is renamed while one of them has a problem.")).font(.caption).foregroundColor(.red) }
        }
    }

    private func run() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        do {
            try app.performBatchRename(paths: draft.request.paths, rule: draft.rule)
            model.batchRename = nil
        } catch let e as RenameError {
            draft.failure = LF("Nothing was renamed: %@", problemText(e))
        } catch {
            draft.failure = LF("Nothing was renamed: %@", error.localizedDescription)
        }
    }
}
