import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia
import UserNotifications

/// Runs the export queue: starts jobs within the concurrency limit, reports progress, survives a crash.
/// One job failing never stops the others.
@MainActor
final class ExportController: ObservableObject {
    @Published private(set) var queue: ExportQueueModel
    @Published private(set) var results: [UUID: ExportResult] = [:]

    private let store: QueueStore
    private let runner: ExportRunner
    private let saver: SafeSaver
    private let prefs: AppPreferences
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Called when a job ends (success or not), for the UI to update libraries and show messages.
    var onJobFinished: ((ExportJob) -> Void)?

    init(fs: FileSystem, saver: SafeSaver, queuePath: String, prefs: AppPreferences) {
        store = QueueStore(fs: fs, path: queuePath)
        runner = ExportRunner(saver: saver, fs: fs)
        self.saver = saver
        self.prefs = prefs
        queue = store.load()
        queue.maxConcurrent = prefs.maxConcurrentExports
        // A crash while a copy was being written leaves a hidden partial file beside its destination. Nothing refers to it any
        // more, so it is removed now (only files with MacPlayer's own temp name are touched).
        for j in queue.jobs where j.restoredAfterCrash { saver.cleanStalePartials(inFolder: PathUtil.directory(of: j.outputPath)) }
        persist()
    }

    /// Jobs restored after a crash wait for the user to look at them; nothing restarts on its own.
    var restoredJobs: [ExportJob] { queue.jobs.filter { $0.restoredAfterCrash && $0.state == .queued } }

    func enqueue(_ jobs: [ExportJob]) {
        queue.enqueue(jobs)
        persist()
        pump()
    }

    func startRestored() { queue.releaseRestored(); persist(); pump() }

    func discardRestored() { for j in restoredJobs { queue.cancel(j.id) }; persist() }

    func cancel(_ id: UUID) {
        queue.cancel(id)
        tasks[id]?.cancel()
        persist()
    }

    func cancelAll() { for j in queue.jobs where !j.state.isFinished { cancel(j.id) } }

    func retry(_ id: UUID) { queue.retry(id); persist(); pump() }
    func retryFailed() { queue.retryAllFailed(); persist(); pump() }
    func clearFinished() { queue.removeFinished(); persist() }

    private func pump() {
        queue.maxConcurrent = prefs.maxConcurrentExports
        // After a crash, restored jobs only start once the user asks (`startRestored`); new jobs are not held up by them.
        for job in queue.nextToStart(includeRestored: false) { start(job) }
    }

    private func start(_ job: ExportJob) {
        queue.markRunning(job.id)
        persist()
        let id = job.id
        tasks[id] = Task { [runner] in
            do {
                let result = try await runner.run(job: job) { p in
                    Task { @MainActor in AppEnvironment.shared.exports.progress(id, p) }
                }
                await MainActor.run { self.finish(id, result: .success(result)) }
            } catch {
                await MainActor.run { self.finish(id, result: .failure(error)) }
            }
        }
    }

    func progress(_ id: UUID, _ p: Double) { queue.setProgress(id, p) }

    private func finish(_ id: UUID, result: Result<ExportResult, Error>) {
        tasks[id] = nil
        switch result {
        case .success(let r):
            results[id] = r
            queue.markSucceeded(id, path: r.outcome.finalPath)
        case .failure(let e):
            // A cancelled job stays "cancelled"; anything else is a failure with its reason.
            if let j = queue.jobs.first(where: { $0.id == id }), j.state == .cancelled { break }
            if let s = e as? SaveError, s == .cancelled { queue.cancel(id); break }
            if let x = e as? ExportError, x == .cancelled { queue.cancel(id); break }
            queue.markFailed(id, message: (e as? CustomStringConvertible)?.description ?? e.localizedDescription)
        }
        persist()
        if let j = queue.jobs.first(where: { $0.id == id }) { onJobFinished?(j) }
        if !queue.hasWork { announceIfDone() }
        pump()
    }

    private func persist() { try? store.save(queue) }

    private func announceIfDone() {
        let s = queue.summary
        guard s.succeeded + s.failed > 0 else { return }
        NSApp.requestUserAttention(.informationalRequest)
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MacPlayer"
            content.body = s.failed == 0 ? LF("%d export(s) finished.", s.succeeded) : LF("%d finished, %d failed.", s.succeeded, s.failed)
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
