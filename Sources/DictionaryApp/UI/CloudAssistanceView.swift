import SwiftUI

/// Fixed above popup scrolling. Only the explicit cloud button sends data; source switching does not.
struct CloudAssistanceView: View {
    @ObservedObject var state: CloudAssistanceState
    var originalLabel = "原始 AI"

    var body: some View {
        if let offer = state.offer, state.isConfigured {
            VStack(alignment: .leading, spacing: 6) {
                if state.phase.isLoading || state.phase.result != nil {
                    Picker("释义来源", selection: Binding(get: { state.selectedSource }, set: { state.selectSource($0) })) {
                        Text(originalLabel).tag(CloudAssistanceState.AnswerSource.original)
                        Text("DeepSeek AI").tag(CloudAssistanceState.AnswerSource.cloud)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("answer-source")
                }
                switch state.phase {
                case .reviewingContext: EmptyView()
                case .idle:
                    HStack {
                        Text(originalLabel).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 4)
                        Button("询问 DeepSeek") { state.ask(offerID: offer.id) }
                            .disabled(!state.isConfigured)
                            .accessibilityIdentifier("ask-deepseek")
                    }
                    Text(state.isConfigured ?
                         "主动调用会发送当前文本与可用语境，API 可能产生费用。" :
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
        DisclosureGroup("查看云端发送内容") {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.target).bold()
                if request.task == .dictionary, let context = request.context, context != request.target { Text(context) }
                if request.task == .dictionary, let sentence = request.containingSentence, sentence != request.context, sentence != request.target {
                    Text("随语境提供的句子").foregroundStyle(DictionaryStyle.secondary)
                    Text(sentence)
                }
            }.font(.system(size: 13)).textSelection(.enabled)
        }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
    }
}
