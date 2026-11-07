import SwiftUI

struct LookupResultView: View {
    enum Layout { case standard, popup }
    let phase: LookupPhase
    var layout: Layout = .standard
    var onCancel: (() -> Void)? = nil
    @ObservedObject var cloud: CloudAssistanceState
    var showsCloudControls: Bool

    init(phase: LookupPhase, layout: Layout = .standard, onCancel: (() -> Void)? = nil,
         cloud: CloudAssistanceState? = nil, showsCloudControls: Bool = true) {
        self.phase = phase; self.layout = layout; self.onCancel = onCancel
        _cloud = ObservedObject(wrappedValue: cloud ?? CloudAssistanceState(provider: nil))
        self.showsCloudControls = showsCloudControls
    }

    var displayedPhase: LookupPhase { cloud.displayedPhase(for: phase) }
    var meaningLabel: String {
        if cloud.showsCloudAnswer(for: phase) { return "AI 释义建议 · DeepSeek" }
        return cloud.offer == nil ? "AI 释义建议" : "AI 释义建议 · 原始答案"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsCloudControls { CloudAssistanceView(state: cloud) }
            switch displayedPhase {
            case .idle:
                Label("选中英文单词，按 ⌥D 查词。", systemImage: "text.cursor")
                    .font(.system(size: 13)).foregroundStyle(DictionaryStyle.secondary)
            case .loading(let request, let startedAt):
                inputSummary(request)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let waiting = LookupWaitingPresentation(startedAt: startedAt, now: .now)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(waiting.title)
                            Text(waiting.elapsed).monospacedDigit().foregroundStyle(DictionaryStyle.secondary)
                            Spacer(minLength: 0)
                            if let onCancel { Button("取消", action: onCancel).controlSize(.small) }
                        }.font(.system(size: 13))
                        if let notice = waiting.notice {
                            Text(notice).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            case .finished(let request, let outcome):
                switch outcome {
                case .success(let result): resultContent(request, translation: result.translation)
                case .failure(let message, _):
                    inputSummary(request)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("暂时无法完成查词", systemImage: "exclamationmark.circle").font(.system(size: 15, weight: .medium))
                        Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Text(request.target.isEmpty ? "也可以在主窗口手动输入单词和语境。" : "请检查翻译服务，然后重新查词。")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }.padding(14).background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                case .cancelled:
                    Text("已取消查词").font(.system(size: 13)).foregroundStyle(DictionaryStyle.secondary)
                }
            }
            if let offer = cloud.offer { CloudInputPreview(request: offer.request).id(offer.id) }
            // Request identity and source safety remain independent of the selected AI answer.
            if let target = referenceTarget { EnglishDictionaryReferenceView(target: target).id(target) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private var referenceTarget: String? {
        switch phase {
        case .idle: return nil
        case .loading(let request, _), .finished(let request, _): return request.target.isEmpty ? nil : request.target
        }
    }

    private func resultContent(_ request: LookupRequest, translation: Translation) -> some View {
        let presentation = LookupResultPresentation(request: request, translation: translation)
        let meaning = AIMeaningPresentation(target: request.target, answer: translation.meaningInContext)
        let additional = translation.additionalMeanings
        let hasMeaning = Translation.displayText(translation.meaningInContext) != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(request.target).font(DictionaryStyle.wordFont(compact: layout == .popup))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if hasMeaning, let pos = Translation.displayText(translation.partOfSpeech) {
                    Text(pos).font(.system(size: 12, design: .serif).italic()).foregroundStyle(DictionaryStyle.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1).fill(DictionaryStyle.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(meaningLabel).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    Text(meaning.text).font(.system(size: layout == .popup ? 22 : 28, weight: .medium))
                    if let notice = meaning.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                    if let original = meaning.originalAnswer {
                        DisclosureGroup("查看 AI 原始回答") { Text(original).font(.system(size: 13)) }
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                    if hasMeaning, let notice = presentation.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary).padding(.top, 3)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
            if let sentence = presentation.sentence, let label = presentation.sentenceLabel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(DictionaryStyle.secondary)
                    Text(sentence).font(.system(size: layout == .popup ? 15 : 18, design: .serif)).lineSpacing(3)
                    if let translated = presentation.sentenceTranslation {
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("句译 · AI").font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary).fixedSize()
                            Text(translated).font(.system(size: 13)).lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DictionaryStyle.line))
            }
            capturedContext(presentation, source: request.source)
            if !cloud.showsCloudAnswer(for: phase), additional.literal != nil || !additional.alternatives.isEmpty {
                DisclosureGroup("更多释义 · AI") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let gloss = additional.literal { row("一般含义 · AI", gloss) }
                        if !additional.alternatives.isEmpty { row("其他解释 · AI", additional.alternatives.joined(separator: " · ")) }
                    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            }
        }
    }

    @ViewBuilder private func capturedContext(_ presentation: LookupResultPresentation, source: String) -> some View {
        if let context = presentation.context {
            DisclosureGroup("\(presentation.contextLabel) · \(source)") {
                Text(context).font(.system(size: 13)).lineSpacing(3).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
        }
    }

    @ViewBuilder private func inputSummary(_ request: LookupRequest) -> some View {
        if !request.target.isEmpty {
            Text(request.target).font(DictionaryStyle.wordFont(compact: layout == .popup))
            let presentation = LookupResultPresentation(request: request)
            if let sentence = presentation.sentence, let label = presentation.sentenceLabel { row(label, sentence) }
            capturedContext(presentation, source: request.source)
            if let notice = presentation.notice { Text(notice).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary) }
            Divider()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(DictionaryStyle.secondary)
            Text(value).font(.system(size: 14)).lineSpacing(3)
        }
    }
}

/// Describes missing, quoted-null or echo output; never judges accuracy or vocabulary coverage.
/// The original Translation remains untouched for source switching and inspection.
struct AIMeaningPresentation {
    let text: String
    let notice: String?
    let originalAnswer: String?

    init(target: String, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if Translation.displayText(answer) == nil {
            text = "暂未获得释义"
            notice = "AI 未返回释义内容，可查看英文词典参考。"
            originalAnswer = trimmed.isEmpty ? nil : answer
        } else if trimmed.lowercased() == target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            text = "暂无进一步释义"
            notice = "AI 返回了原词，未提供进一步解释。"
            originalAnswer = answer
        } else {
            text = answer
            notice = nil
            originalAnswer = nil
        }
    }
}

/// Elapsed time only; no inferred model-loading stage, completion percentage or ETA.
struct LookupWaitingPresentation {
    let elapsed: String
    let title: String
    let notice: String?

    init(startedAt: ContinuousClock.Instant, now: ContinuousClock.Instant) {
        let seconds = max(0, startedAt.duration(to: now).components.seconds)
        elapsed = "\(seconds) 秒"
        title = seconds < 5 ? "正在查词…" : "仍在处理中…"
        notice = seconds < 5 ? nil : "正在等待翻译服务，你可以随时取消。"
    }
}

/// Presentation consumes request-owned source evidence, never a model-created source sentence.
struct LookupResultPresentation {
    // Capture evidence qualifies the source, not the model's interpretation.
    let meaningLabel = "AI 释义建议"
    let context: String?
    let sentence: String?
    let sentenceLabel: String?
    let sentenceTranslation: String?
    let contextLabel: String
    let notice: String?

    init(request: LookupRequest, translation: Translation? = nil) {
        context = request.capture?.reliability == .targetOnly ? nil : request.context.flatMap { $0.isEmpty ? nil : $0 }
        sentence = context == nil || request.capture?.reason == .sentenceUnavailable ? nil : request.containingSentence
        if sentence == nil { sentenceLabel = nil }
        else if request.isManual { sentenceLabel = "推断原句 · 手动输入" }
        else {
            switch request.capture?.reliability {
            case .anchored: sentenceLabel = "原句"
            case .heuristic: sentenceLabel = "可能的原句"
            default: sentenceLabel = "提供的原句 · 未核实"
            }
        }
        sentenceTranslation = sentence == nil ? nil : Translation.displayText(translation?.exampleTranslation)
        if request.isManual { contextLabel = "你提供的语境" }
        else {
            switch request.capture?.reliability {
            case .anchored: contextLabel = "捕获的语境"
            case .heuristic: contextLabel = "可能的语境"
            default: contextLabel = "未核实的语境"
            }
        }
        if context == nil {
            notice = "缺少完整语境，释义仅供一般参考。"
        } else if request.isManual {
            notice = nil
        } else {
            switch request.capture?.reliability {
            case .anchored:
                notice = sentence == nil ? "已定位选词，但未能确认完整原句。" : nil
            case .heuristic:
                notice = "语境来自推断，可能与选词不完全对应。"
            default:
                notice = "提供的语境尚未核实。"
            }
        }
    }
}
