import SwiftUI

struct TranslationPopupView: View {
    @ObservedObject var state: PopupState
    let onClose: () -> Void
    @ObservedObject var cloud: CloudAssistanceState
    let primaryLabel: String?
    let primaryIsCloud: Bool

    init(state: PopupState, onClose: @escaping () -> Void, cloud: CloudAssistanceState? = nil,
         primaryLabel: String? = nil, primaryIsCloud: Bool = false) {
        self.state = state; self.onClose = onClose
        _cloud = ObservedObject(wrappedValue: cloud ?? CloudAssistanceState(provider: nil))
        self.primaryLabel = primaryLabel; self.primaryIsCloud = primaryIsCloud
    }

    private var controlsHeight: CGFloat { primaryIsCloud || cloud.offer == nil ? 0 : state.cloudControlsHeight }

    // Reuse the fixed toolbar only when content overflows. Never retain an old result during a new lookup.
    var toolbarTitle: String {
        let size = PopupContentSize(available: state.availableSize, measuredHeight: state.contentHeight, controlsHeight: controlsHeight)
        if state.contentHeight > size.contentHeight,
           case .finished(let request, .success(let result)) = cloud.displayedPhase(for: state.phase) {
            let source = cloud.showsCloudAnswer(for: state.phase) ? "DeepSeek AI" :
                primaryLabel ?? (cloud.offer == nil ? "AI 建议" : "原始 AI")
            let meaning = AIMeaningPresentation(target: request.target, answer: result.translation.meaningInContext)
            return "\(request.target) · \(source)：\(meaning.text)"
        }
        return "Dictionary"
    }

    var body: some View {
        let size = PopupContentSize(available: state.availableSize, measuredHeight: state.contentHeight, controlsHeight: controlsHeight)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(toolbarTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(toolbarTitle)
                Spacer(minLength: 0)
                Button {
                    state.isPinned.toggle()
                } label: {
                    Image(systemName: state.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.isPinned ? DictionaryStyle.accent : DictionaryStyle.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                        .background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(state.isPinned ? "取消固定，允许自动关闭" : "固定，保持显示")
                .accessibilityLabel(state.isPinned ? "取消固定" : "固定")
                .accessibilityIdentifier("popup-pin")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                        .background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .keyboardShortcut(.escape, modifiers: [])
                .help("关闭")
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("popup-close")
            }
            .frame(height: 28)
            Divider().frame(height: 1)
            if !primaryIsCloud, cloud.offer != nil {
                CloudAssistanceView(state: cloud, originalLabel: primaryLabel ?? "原始 AI")
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: CloudControlsHeight.self, value: geometry.size.height)
                    })
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LookupResultView(phase: state.phase, layout: .popup, onCancel: onClose, cloud: cloud, showsCloudControls: false,
                        primaryLabel: primaryLabel, showsAdditionalMeanings: !primaryIsCloud)
                        .id("lookup-result-top")
                        .padding(.trailing, 4)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: PopupContentHeight.self, value: geometry.size.height)
                        })
                }
                .frame(height: size.contentHeight)
                .onPreferenceChange(PopupContentHeight.self) { height in
                    if height.isFinite, height > 0, ceil(height) != state.contentHeight {
                        state.contentHeight = ceil(height)
                    }
                }
                .onChange(of: cloud.showsCloudAnswer(for: state.phase)) { _, _ in
                    proxy.scrollTo("lookup-result-top", anchor: .top)
                }
            }
        }
        .onPreferenceChange(CloudControlsHeight.self) { height in
            if height.isFinite, height > 0, ceil(height) != state.cloudControlsHeight {
                state.cloudControlsHeight = ceil(height)
            }
        }
        .padding(16)
        .frame(width: size.width, alignment: .topLeading)
        .background(DictionaryStyle.paper, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DictionaryStyle.line))
    }

}

private struct CloudControlsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PopupContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Toolbar (28), divider (1), spacing (24) and padding (32) stay outside scrolling.
struct PopupContentSize {
    let width: CGFloat
    let contentHeight: CGFloat

    init(available: CGSize, measuredHeight: CGFloat, controlsHeight: CGFloat = 0) {
        width = min(420, max(1, available.width))
        let controls = controlsHeight > 0 ? ceil(controlsHeight) + 12 : 0
        let limit = max(1, min(560, available.height) - 85 - controls)
        contentHeight = min(limit, max(1, ceil(measuredHeight)))
    }
}
