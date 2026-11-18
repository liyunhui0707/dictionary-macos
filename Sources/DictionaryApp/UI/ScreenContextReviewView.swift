import SwiftUI

struct ScreenContextReviewView: View {
    let request: LookupRequest
    let id: UUID
    let providerLabel: String
    var onConfirm: ((UUID, String?, Bool) -> Bool)?
    var onCancel: (() -> Void)?
    @State private var text: String
    init(request: LookupRequest, id: UUID, providerLabel: String,
         onConfirm: ((UUID, String?, Bool) -> Bool)?, onCancel: (() -> Void)?) {
        self.request = request; self.id = id; self.providerLabel = providerLabel
        self.onConfirm = onConfirm; self.onCancel = onCancel
        _text = State(initialValue: request.context ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.target).font(DictionaryStyle.wordFont(compact: true))
            Label("核对屏幕语境", systemImage: "viewfinder").font(.system(size: 13, weight: .medium))
            TextEditor(text: $text).font(.system(size: 15, design: .serif)).frame(minHeight: 70, maxHeight: 120)
                .padding(5).background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("可修改的屏幕语境").accessibilityIdentifier("screen-context-editor")
            Text("可修改识别错字。继续后将交给 \(providerLabel)；云端服务会收到选词与这段文字。图片不保存或发送。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            if !ScreenContextSafety.validEdit(text, target: request.target) {
                Text("请保留一处选中的词，并将语境控制在 2000 个字符内。")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button("使用语境") { _ = onConfirm?(id, text, true) }
                    .disabled(!ScreenContextSafety.validEdit(text, target: request.target))
                    .accessibilityIdentifier("screen-context-confirm")
                Button("仅查单词") { _ = onConfirm?(id, nil, false) }
                if let onCancel { Button("放弃", action: onCancel) }
            }.controlSize(.small)
        }
    }
}
