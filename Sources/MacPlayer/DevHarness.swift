import AppKit
import Foundation
import MacPlayerCore
import MacPlayerMedia

/// Development switches used by `Scripts/crash_test.py` and `Scripts/open_with_test.py`. They run without a window.
@MainActor
extension AppDelegate {
    /// `--recover-check`: what a normal launch would do after a crash, printed as one JSON line, then exit.
    func runRecoverCheck() {
        let reports = env.saver.recoverLegacyReplaceJournals()
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

    /// `--crash-export <source> <out-dir> <copy|batch>`: starts a real export of a project made from `source` and keeps running, so a
    /// test can kill the process. The project file goes into the test's data folder; the source is only read.
    func runCrashExport(source: String, outDir: String, mode: String) {
        Task { @MainActor in
            do {
                let path = env.support.appendingPathComponent("crash-\(UUID().uuidString.prefix(6)).macplayer").path
                let s = try await EditorSession.makeProjectFile(kind: .video, media: URL(fileURLWithPath: source), at: path)
                var jobs: [ExportJob] = []
                if mode == "batch" {
                    for i in 0..<4 {
                        s.edit("range", refreshPreview: false) { $0.timeline[0].sourceStart = MediaTime(seconds: Double(i) * 12); $0.timeline[0].sourceEnd = MediaTime(seconds: Double(i) * 12 + 10) }
                        jobs += try s.planExport(ExportRequest(options: ExportOptions(mode: .exact), folder: outDir, baseName: "batch-\(i + 1)")).jobs
                    }
                } else {
                    jobs = try s.planExport(ExportRequest(options: ExportOptions(mode: .exact), folder: outDir, baseName: "copy-out")).jobs
                }
                env.exports.enqueue(jobs)
                print("STARTED " + jobs.map(\.outputPath).joined(separator: "|"))
                fflush(stdout)
            } catch { print("ERROR \(error)"); fflush(stdout); exit(2) }
        }
    }

    /// `--crash-autosave <source> <dir> <any>`: makes a project from `source` in `dir` and saves it into its file again and again
    /// (one marker more each time), so a test can kill the process in the middle of a write.
    func runCrashAutosave(source: String, dir: String) {
        Task { @MainActor in
            do {
                let path = PathUtil.join(dir, "crash.macplayer")
                let s = try await EditorSession.makeProjectFile(kind: .video, media: URL(fileURLWithPath: source), at: path)
                print("STARTED " + path); fflush(stdout)
                var n = 0
                while true {
                    n += 1
                    s.edit("marker") { $0.markers.append(Marker(time: MediaTime(seconds: Double(n % 50) / 10), name: "m\(n)")) }
                    if n % 3 == 0 { _ = s.saveNow() } else { s.save() }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            } catch { print("ERROR \(error)"); fflush(stdout); exit(2) }
        }
    }
}
