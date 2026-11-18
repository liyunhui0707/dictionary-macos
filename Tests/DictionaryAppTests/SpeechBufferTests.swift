import AVFoundation
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct SpeechBufferTests {
    /// Silent, in-memory synthesis only: never plays to speakers or orders a window front.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_SPEECH_BUFFER_CHECK"] == "1"), .timeLimit(.minutes(1)))
    func installedNaturalAmericanVoiceProducesAudioForSelectedIPA() async throws {
        let voices = SystemSpeechDriver().voices
        let selected = try #require(voices.first)
        let voice = try #require(AVSpeechSynthesisVoice(identifier: selected.id))
        #expect(voice.language == "en-US")
        #expect(!voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice))
        let synthesizer = AVSpeechSynthesizer()
        let attributed = NSAttributedString(string: "bank", attributes: [NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute): "bæŋk"])
        let utterance = AVSpeechUtterance(attributedString: attributed); utterance.voice = voice
        let buffers = SpeechBufferCounter()
        synthesizer.write(utterance) { buffer in buffers.append(buffer) }
        for _ in 0..<500 {
            if buffers.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        synthesizer.stopSpeaking(at: .immediate)
        #expect(buffers.frames > 0 && buffers.finished)
    }
}

private final class SpeechBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var done = false
    var frames: Int { lock.withLock { total } }
    var finished: Bool { lock.withLock { done } }
    func append(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.withLock { total += Int(pcm.frameLength); if pcm.frameLength == 0 { done = true } }
    }
}
