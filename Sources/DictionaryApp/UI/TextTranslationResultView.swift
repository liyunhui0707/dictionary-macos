import AppKit
import SwiftUI

struct TextTranslationResultView: View {
    let request: LookupRequest
    let translation: TextTranslation?
    let providerLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("译文 · \(providerLabel)").font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                Spacer()
                if let translation {
                    Button("复制译文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translation.translatedText, forType: .string)
                    }.font(.system(size: 12)).buttonStyle(.borderless)
                }
            }
            Text(translation?.translatedText ?? "未获得完整译文，请重新翻译。")
                .font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                .accessibilityIdentifier("full-text-translation")
            Divider()
            DisclosureGroup("英文原文 · \(request.source)") {
                Text(request.target).font(.system(size: 14, design: .serif)).lineSpacing(4).padding(.top, 6)
            }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            SpeechButton(text: request.target, label: "朗读原文")
            Text("AI 翻译，可能有误。").font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
        }
    }
}

struct LookupTaskSwitch: View {
    let request: LookupRequest
    let change: (LookupTask) -> Void
    var body: some View {
        HStack {
            Text(request.task == .dictionary ? "词语释义" : "句段翻译")
            Spacer()
            Button(request.task == .dictionary ? "改为翻译" : "改为查词") {
                change(request.task == .dictionary ? .translation : .dictionary)
            }.buttonStyle(.borderless).accessibilityIdentifier("switch-lookup-task")
        }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
    }
}
