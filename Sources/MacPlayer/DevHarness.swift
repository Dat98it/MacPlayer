import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Development switches used by `Scripts/crash_test.py` and `Scripts/open_with_test.py`. They run without a window.
@MainActor
extension AppDelegate {
    /// `--recover-check`: what a normal launch would do after a crash, printed as one JSON line, then exit.
    func runRecoverCheck() {
        let reports = env.saver.recoverInterrupted()
        func name(_ a: RecoveryReport.Action) -> String {
            switch a { case .discardedPartialExport: return "discardedPartialExport"; case .restoredOriginal: return "restoredOriginal"; case .finishedCleanup: return "finishedCleanup"; case .needsAttention(let m): return "needsAttention: \(m)" }
        }
        let obj: [String: Any] = [
            "journal": reports.map { ["path": $0.path, "action": name($0.action)] },
            "queueJobs": env.exports.queue.jobs.count,
            "restoredJobs": env.exports.restoredJobs.count,
            "recoverableProjects": env.projectStore.recoverable().count,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { print(s) }
        fflush(stdout)
        exit(0)
    }

    /// `--crash-export <source> <out-dir> <copy|replace|batch>`: starts a real export and keeps running, so a test can kill the process.
    func runCrashExport(source: String, outDir: String, mode: String) {
        Task { @MainActor in
            do {
                let s = try await EditorSession.open(url: URL(fileURLWithPath: source))
                var req = ExportRequest(scope: .whole, saveKind: .newCopy, options: ExportOptions(mode: .exact), folder: outDir, baseName: "copy-out")
                switch mode {
                case "replace": req.saveKind = .replaceOriginal
                case "batch":
                    s.edit("clips", refreshPreview: false) { p in for i in 0..<4 { _ = p.selections.add(start: MediaTime(seconds: Double(i) * 12), end: MediaTime(seconds: Double(i) * 12 + 10), name: "Part \(i + 1)") } }
                    req.scope = .allClips
                default: break
                }
                let (jobs, _) = try s.planExport(req)
                env.exports.enqueue(jobs)
                print("STARTED " + jobs.map(\.outputPath).joined(separator: "|"))
                fflush(stdout)
            } catch { print("ERROR \(error)"); fflush(stdout); exit(2) }
        }
    }
}
