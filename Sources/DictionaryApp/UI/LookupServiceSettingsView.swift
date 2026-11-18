import SwiftUI

struct LookupServiceSettingsView: View {
    @ObservedObject var settings: LookupServiceSettings
    @ObservedObject var cloud: CloudSettings
    @State private var consent = false
    @State private var choosingCloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前：\(settings.label)").font(.system(size: 14, weight: .medium))
            if settings.isManaged {
                Text("本次启动已指定服务。正常重开应用后可在此选择。").font(.system(size: 12))
            } else {
                HStack {
                    Button(settings.selected == .local ? "✓ Ollama 本地" : "Ollama 本地") { settings.choose(.local); choosingCloud = false }
                        .disabled(settings.selected == .local).accessibilityIdentifier("choose-local-service")
                    Button(settings.selected == .deepSeek ? "✓ DeepSeek 云端" : "DeepSeek 云端…") { choosingCloud = true }
                        .disabled(settings.selected == .deepSeek).accessibilityIdentifier("choose-deepseek-service")
                }
                Text(settings.selected == .deepSeek ? "查询文字会发送至 DeepSeek，API 按用量收费。" : "本地查询需要已运行的 Ollama 和已安装模型；文字留在本机。")
                    .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                if choosingCloud {
                    Toggle("同意查询时发送所选文字及可用语境至 api.deepseek.com，并承担 API 用量费用。", isOn: $consent)
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if !settings.cloudAvailable { Text("请展开 DeepSeek 配置，保存或启用密钥。").font(.system(size: 12)) }
                    Button("确认使用 DeepSeek") { settings.choose(.deepSeek, cloudConsent: consent); choosingCloud = false }
                        .disabled(!settings.cloudAvailable || !consent)
                }
            }
        }
    }
}
