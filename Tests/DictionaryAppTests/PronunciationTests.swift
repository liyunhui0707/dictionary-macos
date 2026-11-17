import Foundation
import Testing
@testable import DictionaryApp

struct PronunciationTests {
    @Test func arpabetUsesUSVowelsStressAndConsonantsWithoutGuessingUnknownPhones() {
        #expect(AmericanPronunciation.ipa(["B", "AE1", "NG", "K"]) == "ˈbæŋk")
        #expect(AmericanPronunciation.ipa(["B", "R", "IH1", "JH"]) == "ˈbɹɪdʒ")
        #expect(AmericanPronunciation.ipa(["R", "IH0", "K", "AO1", "R", "D"]) == "ɹɪˈkɔɹd")
        #expect(AmericanPronunciation.ipa(["Y", "UW2", "N", "AH0", "V", "ER1", "S", "AH0", "T", "IY0"]) == "ˌjunəˈvɝsəti")
        #expect(AmericanPronunciation.ipa(["INVALID"]) == nil)
    }

    @Test func bundledReadingsAreAvailableOfflineAndUnknownWordsStayUnknown() async {
        #expect(await AmericanPronunciation.shared.lookup("bank") == ["ˈbæŋk"])
        let read = await AmericanPronunciation.shared.lookup("read")
        #expect(read.contains("ˈɹɛd") && read.contains("ˈɹid"))
        #expect(await AmericanPronunciation.shared.lookup("vqxtralen").isEmpty)
        #expect(await AmericanPronunciation.shared.lookup("This is a sentence.").isEmpty)
    }

    @MainActor @Test func playbackIsExplicitCancellableAndNeverFallsBackToAnotherLocale() {
        let driver = SilentSpeechDriver()
        let playback = SpeechPlayback(driver: driver)
        #expect(driver.spoken.isEmpty)
        playback.toggle("bank", ipa: "bæŋk")
        #expect(driver.spoken == ["bank"] && playback.playingText == "bank")
        playback.toggle("bank")
        #expect(playback.playingText == nil && driver.spoken.count == 1)
        playback.toggle("company")
        driver.onFinished?()
        #expect(playback.playingText == nil)
        playback.voiceID = "unavailable-voice"
        playback.toggle("bridge")
        #expect(driver.spoken == ["bank", "company"] && playback.message != nil)
        let unavailable = SilentSpeechDriver(voices: [])
        let noVoice = SpeechPlayback(driver: unavailable)
        noVoice.toggle("bank")
        #expect(unavailable.spoken.isEmpty && noVoice.message != nil)
    }
}

@MainActor
private final class SilentSpeechDriver: SpeechDriver {
    let voices: [AmericanVoice]
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    init(voices: [AmericanVoice] = [.init(id: "synthetic-en-US", name: "Synthetic US")]) { self.voices = voices }
    func speak(text: String, ipa: String?, voiceID: String, rate: Float) { spoken.append(text) }
    func stop() {}
}
