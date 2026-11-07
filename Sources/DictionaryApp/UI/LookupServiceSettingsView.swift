import SwiftUI

struct LookupServiceSettingsView: View {
    @ObservedObject var settings: LookupServiceSettings
    @ObservedObject var cloud: CloudSettings
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("当前：\(settings.label)").font(.system(size: 14, weight: .medium))
            if settings.isManaged {
                Text("本次启动已指定服务。请退出后从应用程序中正常打开，才能在这里选择。")
                    .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            } else {
                DictionaryCard {
                    Label("DeepSeek 云端查词", systemImage: "cloud").font(.system(size: 14, weight: .medium))
                    Text("无需安装 Ollama 或下载本地模型。使用你自己的 DeepSeek API 密钥。")
                        .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    Toggle("同意查词时将选词及可获取的原句、附近语境发送至 api.deepseek.com，并承担 API 用量费用。", isOn: $consent)
                        .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button(settings.selected == .deepSeek ? "已选择 DeepSeek" : "使用 DeepSeek 查词") {
                        settings.choose(.deepSeek, cloudConsent: consent)
                    }.disabled(!settings.cloudAvailable || !consent || settings.selected == .deepSeek)
                        .accessibilityIdentifier("choose-deepseek-service")
                    if !settings.cloudAvailable {
                        Text("请先在下方保存密钥，或启用已保存的密钥。")
                            .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
                    }
                }
                DictionaryCard {
                    Label("Ollama 本地查词", systemImage: "desktopcomputer").font(.system(size: 14, weight: .medium))
                    Text("选词和语境留在本机。需要另外安装并运行 Ollama、准备本地模型；可在「本地模型」检查连接。")
                        .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    Button(settings.selected == .local ? "已选择本地查词" : "使用本地查词") { settings.choose(.local) }
                        .disabled(settings.selected == .local).accessibilityIdentifier("choose-local-service")
                }
                CloudSettingsView(settings: cloud)
            }
        }
    }
}
