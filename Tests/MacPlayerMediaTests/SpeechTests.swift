import AVFoundation
import Foundation
import Testing
import MacPlayerCore
@testable import MacPlayerMedia

@Suite(.serialized) struct SpeechTests {
    @Test func theLanguagesTheMacCanRecogniseOnItsOwnCanBeListed() {
        let locales = SpeechTranscriber.onDeviceLocales()
        #expect(locales.allSatisfy { !$0.identifier.isEmpty })
        #expect(locales.map(\.identifier) == locales.map(\.identifier).sorted())
    }

    @Test func aLanguageThatIsNotAvailableOnTheDeviceIsRefusedInsteadOfSentAway() async throws {
        let src = try await Fixtures.shared.source()
        // Only when the person has already allowed speech recognition: asking would put a question on their screen.
        guard SpeechTranscriber.isAuthorized() else { return }
        do { _ = try await SpeechTranscriber.transcribe(source: src, span: nil, locale: Locale(identifier: "zz-ZZ")); Issue.record("should be refused") }
        catch let e as SpeechTranscriber.SpeechError { if case .notOnDevice = e {} else { Issue.record("wrong error: \(e)") } }
    }

    @Test func theMessagesSayWhatToDo() {
        #expect(SpeechTranscriber.SpeechError.notAuthorized.description.contains("System Settings"))
        #expect(SpeechTranscriber.SpeechError.notOnDevice("vi_VN").description.contains("does not send"))
    }

    /// Real recognition of spoken words made with the Mac's own voice. It runs only when speech recognition is already allowed and an
    /// English model is on the Mac; otherwise there is nothing to check and it is skipped.
    @Test func spokenWordsBecomeTimedSubtitles() async throws {
        guard SpeechTranscriber.isAuthorized(), SpeechTranscriber.onDeviceLocales().contains(where: { $0.identifier.hasPrefix("en") }) else { return }
        let locale = SpeechTranscriber.onDeviceLocales().first { $0.identifier.hasPrefix("en") }!
        let audio = Fixtures.shared.outputURL("speech.m4a")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        let aiff = Fixtures.shared.outputURL("speech.aiff")
        say.arguments = ["-o", aiff.path, "Hello everyone. This is a subtitle test for the video editor."]
        try say.run(); say.waitUntilExit()
        try await AudioExporter.export(source: aiff, span: TimeSpan(start: .zero, end: MediaTime(seconds: 8)), audio: AudioSettings(), to: audio)
        let words = try await SpeechTranscriber.transcribe(source: audio, span: nil, locale: locale)
        let cues = SubtitleBuilder.cues(from: words)
        #expect(!cues.isEmpty && cues.joined().lowercased().contains("subtitle"), "heard: \(cues.map(\.text))")
    }
}

private extension Array where Element == SubtitleCue { func joined() -> String { map(\.text).joined(separator: " ") } }
