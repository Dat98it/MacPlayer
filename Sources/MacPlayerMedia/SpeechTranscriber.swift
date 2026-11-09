import AVFoundation
import Foundation
import MacPlayerCore
import Speech

/// Turns the speech in a video into timed words, with the Mac's own speech recogniser, working on the Mac only. Nothing is sent anywhere:
/// a language that cannot be recognised on the device is refused rather than handed to a server.
public enum SpeechTranscriber {
    public enum SpeechError: Error, CustomStringConvertible {
        case notAuthorized, notOnDevice(String), noSpeech, noAudio, failed(String)
        public var description: String {
            switch self {
            case .notAuthorized: return "Speech recognition is not allowed for MacPlayer. It can be switched on in System Settings ▸ Privacy & Security ▸ Speech Recognition."
            case .notOnDevice(let l): return "The language “\\(l)” cannot be recognised on this Mac without the internet. MacPlayer does not send your video or sound anywhere, so it was not used."
            case .noSpeech: return "No speech was found."
            case .noAudio: return "This video has no sound to listen to."
            case .failed(let m): return "Recognising the speech failed: \\(m)"
            }
        }
    }

    /// The languages this Mac can recognise on its own.
    public static func onDeviceLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales().filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }.sorted { $0.identifier < $1.identifier }
    }

    public static func isAuthorized() -> Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static func requestAuthorization() async -> Bool {
        if isAuthorized() { return true }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    /// Listens to `span` of the video (all of it when nil). Times in the result count from the start of the video.
    public static func transcribe(source: URL, span: TimeSpan?, locale: Locale) async throws -> [TimedWord] {
        guard await requestAuthorization() else { throw SpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw SpeechError.notOnDevice(locale.identifier)
        }
        let asset = AVURLAsset(url: source)
        guard (try? await asset.loadTracks(withMediaType: .audio).first) != nil else { throw SpeechError.noAudio }
        let whole = TimeSpan(start: .zero, end: MediaTime(try await asset.load(.duration)))
        let part = span ?? whole
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("macplayer-speech-\\(UUID().uuidString.prefix(8)).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        do { try await AudioExporter.export(source: source, span: part, audio: AudioSettings(), to: temp) } catch { throw SpeechError.failed(error.localizedDescription) }

        let request = SFSpeechURLRecognitionRequest(url: temp)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let offset = part.start.seconds
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TimedWord], Error>) in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map { TimedWord(text: $0.substring, start: $0.timestamp + offset, duration: $0.duration) }
                    words.isEmpty ? cont.resume(throwing: SpeechError.noSpeech) : cont.resume(returning: words)
                } else if let error {
                    finished = true
                    cont.resume(throwing: SpeechError.failed(error.localizedDescription))
                }
            }
        }
    }
}
