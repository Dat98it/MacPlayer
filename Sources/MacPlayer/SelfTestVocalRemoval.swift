import AppKit
import CryptoKit
import MacPlayerCore
import MacPlayerMedia

extension SelfTest {
    /// The real save-button path, cancellation and UI responsiveness. Source audio is read only.
    static func vocalRemovalFlow(env: AppEnvironment, work: URL, app: AppDelegate) async {
        app.quitWhenLastWindowCloses = false
        guard let path = ProcessInfo.processInfo.environment["MACPLAYER_VOCAL_SOURCE"] else { check(false, "a test source is supplied"); return }
        let source = URL(fileURLWithPath: path)
        let output = ProcessInfo.processInfo.environment["MACPLAYER_VOCAL_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? work.appendingPathComponent("instrumental.m4a")
        func checksum(_ url: URL) throws -> SHA256.Digest {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize()
        }
        do {
            let before = try checksum(source)
            let info = try await MediaProbe.probe(url: source)
            let tool = VocalRemovalWindow.shared
            tool.show(source: source)
            if let path = ProcessInfo.processInfo.environment["MACPLAYER_VOCAL_SNAPSHOT"] { tool.snapshot(to: URL(fileURLWithPath: path)) }
            let workBefore = Set(try FileManager.default.contentsOfDirectory(atPath: work.path))
            let cancelled = work.appendingPathComponent("cancelled.m4a")
            tool.start(to: cancelled)
            let started = Date()
            try? await Task.sleep(nanoseconds: 150_000_000)
            check(Date().timeIntervalSince(started) < 1, "the UI remains responsive while separation starts")
            check(tool.isRunning, "the tool shows a running job")
            let ignored = work.appendingPathComponent("second-job.m4a")
            tool.start(to: ignored)
            await tool.cancelAndWait()
            check(!tool.isRunning && tool.result == nil && tool.error == nil, "cancelling returns to the ready state")
            check(!FileManager.default.fileExists(atPath: cancelled.path) && !FileManager.default.fileExists(atPath: ignored.path), "cancelled and duplicate jobs leave no output")
            let leftover = Set(try FileManager.default.contentsOfDirectory(atPath: work.path)).subtracting(workBefore)
            check(leftover.isEmpty, "cancelling also removes the safe-save temp file")
            tool.start(to: output)
            let start = Date()
            await waitFor(max(120, info.duration.seconds * 3)) { !tool.isRunning }
            check(!tool.isRunning && tool.error == nil && tool.result == output, "the real tool saves an instrumental file")
            if let error = tool.error { print("Vocal removal error: \(error)") }
            if tool.isRunning { await tool.cancelAndWait() }
            if FileManager.default.fileExists(atPath: output.path) {
                let made = try await MediaProbe.probe(url: output)
                check(made.hasAudio && !made.hasVideo && abs(made.duration.seconds - info.duration.seconds) < 0.15, "the result is audio only and keeps the song's full duration")
                print(String(format: "INSTRUMENTAL %.3f s processed in %.2f s", made.duration.seconds, Date().timeIntervalSince(start)))
            }
            check(try checksum(source) == before, "the original song's SHA-256 is unchanged")
            // Choosing an existing destination must keep both the result and the original intact.
            if FileManager.default.fileExists(atPath: output.path) {
                let saved = try checksum(output)
                tool.start(to: output)
                await waitFor(10) { !tool.isRunning }
                let afterRefusedSave = try checksum(output)
                check(tool.error != nil && tool.result == nil && afterRefusedSave == saved, "an existing file is refused without overwriting it")
                check(try checksum(source) == before, "the original also stays unchanged after the refused save")
            }
        } catch { check(false, "vocal separation flow: \(error)") }
    }
}
