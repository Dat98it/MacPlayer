import AVFoundation
import Foundation

/// Records the microphone into a file in the app's own folder (a voice-over). The recording never leaves the Mac.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    enum RecorderError: Error, CustomStringConvertible {
        case denied, failed(String)
        var description: String {
            switch self {
            case .denied: return L("MacPlayer is not allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone, then try again.")
            case .failed(let m): return LF("The recording could not start: %@", m)
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var seconds = 0.0
    /// 0...1, how loud the voice is right now.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    /// Asks for the microphone the first time; true when it may be used.
    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(in folder: URL) async throws -> URL {
        guard !isRecording else { throw RecorderError.failed("already recording") }
        guard await Self.authorize() else { throw RecorderError.denied }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = folder.appendingPathComponent("Voice-\(f.string(from: Date())).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw RecorderError.failed("the microphone is busy") }
            recorder = r
        } catch let e as RecorderError { throw e } catch { throw RecorderError.failed(error.localizedDescription) }
        isRecording = true; seconds = 0; level = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.seconds = r.currentTime
                self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
            }
        }
        return url
    }

    /// Stops and returns the file (nil if nothing was recording).
    @discardableResult
    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        guard let r = recorder else { return nil }
        let url = r.url
        r.stop()
        recorder = nil; isRecording = false; level = 0
        return url
    }
}
