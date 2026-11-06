import SwiftUI

/// Fixed above popup scrolling. Only the explicit cloud button sends data; source switching does not.
struct CloudAssistanceView: View {
    @ObservedObject var state: CloudAssistanceState

    var body: some View {
        if let offer = state.offer {
            VStack(alignment: .leading, spacing: 6) {
                if state.phase.isLoading || state.phase.result != nil {
                    Picker("释义来源", selection: Binding(get: { state.selectedSource }, set: { state.selectSource($0) })) {
                        Text("原始 AI").tag(CloudAssistanceState.AnswerSource.original)
                        Text("DeepSeek AI").tag(CloudAssistanceState.AnswerSource.cloud)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("answer-source")
                }
                switch state.phase {
                case .idle:
                    HStack {
                        Text("原始 AI").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 4)
                        Button("询问 DeepSeek") { state.ask(offerID: offer.id) }
                            .disabled(!state.isConfigured)
                            .accessibilityIdentifier("ask-deepseek")
                    }
                    Text(state.isConfigured ?
                         "将发送单词、语境及选中位置，API 可能产生费用。" :
                         "云端辅助未开启，可在偏好设置中配置。")
                        .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                case .loading(_, let startedAt):
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let waiting = LookupWaitingPresentation(startedAt: startedAt, now: .now)
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("DeepSeek · \(waiting.title)")
                            Text(waiting.elapsed).monospacedDigit()
                            Spacer(minLength: 0)
                            Button("取消") { state.cancel() }.accessibilityLabel("取消云端请求")
                        }.font(.system(size: 12))
                    }
                case .finished(_, let outcome):
                    switch outcome {
                    case .success:
                        Text("可切换来源比较，原始答案已保留。AI 释义仍可能有误。")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    case .failure(let message, _):
                        Text(message).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    case .cancelled:
                        Text("已取消云端请求，已发送的文字无法撤回。")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Disclosure stays in the scroll area, so arbitrary input cannot push Pin/Close or actions off-screen.
struct CloudInputPreview: View {
    let request: LookupRequest
    var body: some View {
        DisclosureGroup("发送给 DeepSeek 的内容") {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.target).bold()
                Text(request.context ?? request.target)
                if let sentence = request.containingSentence {
                    Text("随语境提供的句子").foregroundStyle(DictionaryStyle.secondary)
                    Text(sentence)
                }
            }.font(.system(size: 13)).textSelection(.enabled)
        }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
    }
}
