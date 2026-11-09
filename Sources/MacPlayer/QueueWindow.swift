import SwiftUI
import AppKit
import MacPlayerCore

/// The export queue: progress, cancel, retry, show the result.
@MainActor
final class QueueWindow {
    static let shared = QueueWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: QueueView(exports: AppEnvironment.shared.exports))
            let w = NSWindow(contentViewController: host)
            w.title = L("Export Queue"); w.setContentSize(NSSize(width: 520, height: 420)); w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacPlayerQueueWindow")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct QueueView: View {
    @ObservedObject var exports: ExportController

    var body: some View {
        let jobs = exports.queue.jobs
        let s = exports.queue.summary
        VStack(spacing: 0) {
            if !exports.restoredJobs.isEmpty {
                HStack {
                    Label(LF("%d exports were interrupted when MacPlayer closed.", exports.restoredJobs.count), systemImage: "arrow.counterclockwise")
                    Spacer()
                    Button(L("Run Again")) { exports.startRestored() }
                    Button(L("Discard")) { exports.discardRestored() }
                }.padding(10).background(Color.orange.opacity(0.15))
            }
            HStack {
                Text(jobs.isEmpty ? L("Nothing in the queue.") : LF("%d done · %d failed · %d cancelled · %d waiting", s.succeeded, s.failed, s.cancelled, s.remaining)).font(.callout)
                Spacer()
                Button(L("Retry Failed")) { exports.retryFailed() }.disabled(s.failed == 0)
                Button(L("Cancel All")) { exports.cancelAll() }.disabled(!exports.queue.hasWork)
                Button(L("Clear Finished")) { exports.clearFinished() }.disabled(jobs.allSatisfy { !$0.state.isFinished })
            }.padding(10)
            Divider()
            List {
                ForEach(jobs) { j in row(j) }
            }
        }
        .frame(minWidth: 460, minHeight: 280)
    }

    @ViewBuilder private func row(_ j: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(j.state)).foregroundColor(color(j.state)).accessibilityHidden(true)
                Text(j.label).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(status(j)).font(.caption).foregroundColor(.secondary)
                switch j.state {
                case .queued, .running: Button(L("Cancel")) { exports.cancel(j.id) }.font(.caption)
                case .failed, .cancelled: Button(L("Retry")) { exports.retry(j.id) }.font(.caption)
                case .succeeded(let path):
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.font(.caption)
                    Button(L("Open")) { (NSApp.delegate as? AppDelegate)?.open(urls: [URL(fileURLWithPath: path)]) }.font(.caption)
                }
            }
            if j.state == .running { ProgressView(value: j.progress).accessibilityLabel(LF("Progress %d percent", Int(j.progress * 100))) }
            if case .failed(let m) = j.state { Text(ErrorText.localized(m)).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            if j.restoredAfterCrash, j.state == .queued { Text(L("Interrupted earlier: it will start again from the beginning.")).font(.caption).foregroundColor(.orange) }
            if let r = exports.results[j.id], !r.warnings.isEmpty { Text(r.warnings.joined(separator: "\n")).font(.caption).foregroundColor(.orange) }
            Text(j.outputPath).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        }.padding(.vertical, 3)
    }

    private func icon(_ s: JobState) -> String {
        switch s { case .queued: return "clock"; case .running: return "arrow.triangle.2.circlepath"; case .succeeded: return "checkmark.circle.fill"; case .failed: return "exclamationmark.triangle.fill"; case .cancelled: return "xmark.circle" }
    }
    private func color(_ s: JobState) -> Color {
        switch s { case .succeeded: return .green; case .failed: return .red; case .running: return .accentColor; default: return .secondary }
    }
    private func status(_ j: ExportJob) -> String {
        switch j.state {
        case .queued: return L("Waiting")
        case .running: return LF("%d%%", Int(j.progress * 100))
        case .succeeded: return L("Done")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }
}
