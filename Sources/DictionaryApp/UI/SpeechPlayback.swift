import AVFoundation
import SwiftUI

struct AmericanVoice: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
protocol SpeechDriver: AnyObject {
    var voices: [AmericanVoice] { get }
    var onFinished: (() -> Void)? { get set }
    func speak(text: String, ipa: String?, voiceID: String, rate: Float)
    func stop()
}

@MainActor
final class SystemSpeechDriver: NSObject, SpeechDriver, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    var onFinished: (() -> Void)?
    var voices: [AmericanVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == "en-US" && $0.identifier.hasPrefix("com.apple.") &&
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }.sorted {
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.name < $1.name
        }
            .map { AmericanVoice(id: $0.identifier, name: $0.name) }
    }
    override init() { super.init(); synthesizer.delegate = self }
    func speak(text: String, ipa: String?, voiceID: String, rate: Float) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance: AVSpeechUtterance
        if let ipa {
            utterance = AVSpeechUtterance(attributedString: NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute): ipa]))
        } else { utterance = AVSpeechUtterance(string: text) }
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rate
        current = utterance; synthesizer.speak(utterance)
    }
    func stop() { current = nil; synthesizer.stopSpeaking(at: .immediate) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }
            self.current = nil; self.onFinished?()
        }
    }
}

@MainActor
final class SpeechPlayback: ObservableObject {
    static let shared = SpeechPlayback(driver: SystemSpeechDriver(), preferences: .standard)
    @Published private(set) var playingText: String?
    @Published private(set) var message: String?
    @Published var voiceID: String { didSet { preferences?.set(voiceID, forKey: "americanSpeechVoice"); stop() } }
    @Published var rate: Double { didSet { preferences?.set(rate, forKey: "americanSpeechRate") } }
    let voices: [AmericanVoice]
    private let driver: SpeechDriver
    private let preferences: UserDefaults?

    init(driver: SpeechDriver, preferences: UserDefaults? = nil) {
        self.driver = driver; self.preferences = preferences; voices = driver.voices
        let saved = preferences?.string(forKey: "americanSpeechVoice")
        voiceID = voices.first(where: { $0.id == saved })?.id ?? voices.first?.id ?? ""
        let savedRate = preferences?.double(forKey: "americanSpeechRate") ?? 0
        rate = savedRate.isFinite && (0.6...1.2).contains(savedRate) ? savedRate : 1
        driver.onFinished = { [weak self] in self?.playingText = nil }
    }
    func toggle(_ text: String, ipa: String? = nil) {
        if playingText == text { stop(); return }
        stop()
        guard voices.contains(where: { $0.id == voiceID }) else {
            message = "未找到已安装的美式系统语音。请在 macOS 朗读设置中准备英语（美国）语音。"; return
        }
        message = nil; playingText = text
        driver.speak(text: text, ipa: ipa, voiceID: voiceID, rate: Float(min(1.2, max(0.6, rate))))
    }
    func stop() { driver.stop(); playingText = nil }
    func dismissMessage() { message = nil }
}

struct SpeechButton: View {
    let text: String
    var ipa: String? = nil
    var label = "美式发音"
    @ObservedObject private var playback = SpeechPlayback.shared
    var body: some View {
        Button { playback.toggle(text, ipa: ipa) } label: {
            Label(playback.playingText == text ? "停止" : label, systemImage: playback.playingText == text ? "stop.fill" : "speaker.wave.2")
        }.font(.system(size: 12)).buttonStyle(.borderless)
            .help("美式系统合成语音，点击播放或停止")
            .accessibilityIdentifier("american-pronunciation-play")
            .popover(isPresented: Binding(get: { playback.message != nil }, set: { if !$0 { playback.dismissMessage() } })) {
                Text(playback.message ?? "").font(.system(size: 13)).padding().frame(width: 280)
            }
            .onDisappear { if playback.playingText == text { playback.stop() } }
    }
}

struct PronunciationView: View {
    let word: String
    @State private var readings: [String] = []
    @State private var selected = 0
    var body: some View {
        HStack(spacing: 10) {
            if readings.count == 1 { Text("美 /\(readings[0])/").textSelection(.enabled) }
            else if readings.count > 1 {
                Picker("美式读音", selection: $selected) {
                    ForEach(readings.indices, id: \.self) { Text("/\(readings[$0])/").tag($0) }
                }.labelsHidden().fixedSize().help("有多种美式读音，请选择与语境对应的读音。")
            }
            SpeechButton(text: word, ipa: readings.indices.contains(selected) ? readings[selected] : nil)
            if !readings.isEmpty {
                Menu { Text("CMUdict 美式宽式音标参考；未按语境排序。系统合成发音，不是真人录音。") } label: {
                    Image(systemName: "info.circle")
                }.menuStyle(.borderlessButton).fixedSize().help("音标与发音来源")
            }
        }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            .task(id: word) { readings = []; selected = 0; let values = await AmericanPronunciation.shared.lookup(word)
                guard !Task.isCancelled else { return }; readings = values }
    }
}

struct SpeechSettingsView: View {
    @ObservedObject private var playback = SpeechPlayback.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("美式发音").font(.headline)
            if playback.voices.isEmpty {
                Text("尚无可用的美式系统语音。请在 macOS 朗读设置中准备英语（美国）语音，再重开 Wordlit。")
            } else {
                Picker("语音", selection: $playback.voiceID) { ForEach(playback.voices) { Text($0.name).tag($0.id) } }
                HStack { Text("语速"); Slider(value: $playback.rate, in: 0.6...1.2); Text(playback.rate, format: .number.precision(.fractionLength(1))) }
                SpeechButton(text: "They walked along the bank of the river.", label: "试听")
            }
            Text("点击才播放，使用本机已安装的 Apple 美式合成语音；不会自动下载语音或调用翻译服务。")
                .font(.caption).foregroundStyle(DictionaryStyle.secondary)
        }.font(.system(size: 13))
    }
}
