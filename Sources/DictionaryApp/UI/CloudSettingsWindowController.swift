import AppKit
import SwiftUI

@MainActor
final class CloudSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: CloudSettings
    private let localSettings: LocalModelSettings
    private let readiness: AppReadiness

    init(settings: CloudSettings, localSettings: LocalModelSettings, readiness: AppReadiness? = nil) {
        self.settings = settings
        self.localSettings = localSettings
        self.readiness = readiness ?? .preview()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dictionary · 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func open() {
        if window?.contentViewController == nil {
            let height = min(580, max(240, (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 660) - 80)
            let host = NSHostingController(rootView:
                DictionarySettingsView(settings: settings, localSettings: localSettings, readiness: readiness).frame(width: 580, height: height))
            window?.contentViewController = host
            window?.setContentSize(host.view.fittingSize)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil // discard any unsubmitted secure-field draft
    }
}

enum DictionarySettingsSection: String, CaseIterable {
    case general = "通用", local = "本地模型", cloud = "云端辅助"
}

@MainActor
private final class SettingsNavigation: ObservableObject {
    @Published var section: DictionarySettingsSection
    init(_ section: DictionarySettingsSection) { self.section = section }
}

struct DictionarySettingsView: View {
    @ObservedObject var settings: CloudSettings
    @ObservedObject var localSettings: LocalModelSettings
    @ObservedObject var readiness: AppReadiness
    @StateObject private var navigation: SettingsNavigation

    init(settings: CloudSettings, localSettings: LocalModelSettings, section: DictionarySettingsSection = .general, readiness: AppReadiness? = nil) {
        self.settings = settings; self.localSettings = localSettings
        self.readiness = readiness ?? .preview()
        _navigation = StateObject(wrappedValue: SettingsNavigation(section))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    DictionaryMark()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("偏好设置").font(.system(size: 23, weight: .medium))
                        Text("让查词更适合你的阅读习惯。")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                }
                Picker("设置分类", selection: $navigation.section) {
                    ForEach(DictionarySettingsSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.top, 12)
            }.padding(28)
            Divider()
            ScrollView {
                Group {
                    switch navigation.section {
                    case .general: general
                    case .local: LocalModelSettingsView(settings: localSettings)
                    case .cloud: CloudSettingsView(settings: settings)
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(DictionaryStyle.paper).foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
            .onAppear { readiness.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readiness.refresh() }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            DictionaryCard {
                HStack {
                    Label(readiness.permissionLabel, systemImage: readiness.permission == .granted ? "checkmark.circle" : "hand.raised")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("重新检查") { readiness.refresh() }
                }
                if readiness.permission != .granted {
                    Text("在系统设置的隐私与安全中，为当前 Dictionary 开启选词权限。未授权时仍可手动输入查词。")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("打开权限设置") { readiness.openSettings() }
                        Button("定位当前 App") { readiness.reveal() }
                    }
                    if readiness.settingsOpenFailed {
                        Text("请手动打开系统设置 → 隐私与安全 → 辅助功能（或设备控制和数据访问）。")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                } else {
                    Text("当前运行的 App 已获授权；其他应用能否提供语境仍取决于其支持情况。")
                        .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                }
            }
            DictionaryCard {
                preference("外观", value: "跟随 macOS 系统")
                Divider()
                preference("翻译语言", value: "简体中文")
            }
            Text("阅读时查词").font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            DictionaryCard {
                preference("选词快捷键", value: "⌥ D")
                Divider()
                preference("手动提交", value: "⌘ Return")
            }
            Text("选中英文后呼出弹窗，读懂后继续阅读。\n需要保留结果时，点击弹窗右上角的固定按钮。")
                .font(.system(size: 12)).lineSpacing(5).foregroundStyle(DictionaryStyle.secondary)
            DictionaryCard {
                Text("当前版本").font(.system(size: 13, weight: .medium))
                Text(readiness.buildLabel).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("在 Finder 中显示当前 App") { readiness.reveal() }
            }
        }
    }

    private func preference(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(DictionaryStyle.secondary) }.font(.system(size: 13))
    }
}

struct LocalModelSettingsView: View {
    @ObservedObject var settings: LocalModelSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if settings.configuration.isActive {
                DictionaryCard {
                    HStack {
                        Label("本地查词", systemImage: "desktopcomputer").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("Ollama").font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                    Divider()
                    HStack(alignment: .top) {
                        Text("当前模型").font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                        Spacer()
                        Text(settings.configuration.model).font(.system(size: 13)).textSelection(.enabled)
                    }
                    Text(settings.statusMessage).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("local-model-status")
                    HStack {
                        Button("检查连接") { Task { await settings.check() } }.disabled(settings.isChecking)
                        if settings.isChecking { ProgressView().controlSize(.small) }
                        Spacer()
                        if let date = settings.checkedAt {
                            Text("上次检查 \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
                        }
                    }
                }
                if settings.configuration.environmentOverride {
                    Text("本次启动指定了模型。退出后以普通方式打开 Dictionary，才能在这里更改。")
                        .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                } else {
                    DictionaryCard {
                        Text("下次启动使用").font(.system(size: 13, weight: .medium))
                        if !settings.models.isEmpty {
                            Picker("本地模型", selection: $settings.selectedModel) {
                                Text("选择本地模型").tag("")
                                ForEach(settings.models, id: \.self) { Text($0).tag($0) }
                            }.disabled(settings.isChecking)
                            HStack {
                                Text("保存后，重新打开应用生效。")
                                    .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
                                Spacer()
                                Button("保存选择") { settings.saveSelection() }.disabled(!settings.canSave)
                            }
                        } else {
                            Text("先检查连接，再选择已安装的本地模型。")
                                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                        }
                        Text("已保存：\(settings.savedModel ?? LocalModelConfiguration.defaultModel)")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                    if settings.restartRequired {
                        Label("重新打开 Dictionary 后使用新模型。当前查询不受影响。", systemImage: "arrow.clockwise")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.accent)
                    }
                }
                DisclosureGroup("连接详情") {
                    Text("Ollama · localhost:11434\n仅检查本地模型列表，不执行翻译，也不加载或下载模型。远程模型不会列在这里。")
                        .font(.system(size: 12)).lineSpacing(4).padding(.top, 8)
                }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            } else {
                DictionaryCard {
                    Text("当前服务：Claude").font(.system(size: 14, weight: .medium))
                    Text(settings.configuration.model).font(.system(size: 13))
                    Text("本次启动使用原有 Claude 配置，本地模型设置不生效。")
                        .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                }
            }
        }
    }
}

struct CloudSettingsView: View {
    @ObservedObject var settings: CloudSettings
    @StateObject private var input = CloudSettingsInput()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DictionaryCard {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DeepSeek 云端辅助").font(.system(size: 14, weight: .medium))
                        Text(settings.isEnabled ? "已开启" : "未开启")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                    Spacer()
                    if settings.isEnabled { Button("关闭") { settings.disable() } }
                    else { Button("启用已存密钥") { Task { await settings.enableSavedKey() } } }
                }
            }
            Text("仅点击「询问 DeepSeek」时，才会发送单词、语境及选中位置。API 可能产生费用。原始答案会保留。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
            DictionaryCard {
                Label("API 密钥", systemImage: "key").font(.system(size: 13, weight: .medium))
                SecureField("输入新密钥或替换现有密钥", text: $input.draft)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("deepseek-api-key")
                HStack {
                    Button("保存并启用") {
                        let key = input.draft
                        input.draft = ""
                        Task { await settings.save(key) }
                    }.disabled(input.draft.isEmpty)
                    Spacer()
                    Button("移除密钥…", role: .destructive) { input.confirmRemoval = true }
                    if settings.isBusy { ProgressView().controlSize(.small) }
                }
            }
            Text(settings.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deepseek-settings-status")
            Label {
                Text("密钥保存在 macOS 钥匙串中。保存不发送测试请求，也不代表 API 验证成功。系统可能会询问是否允许访问。")
            } icon: { Image(systemName: "lock") }
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(settings.isBusy)
        .alert("移除已保存的 DeepSeek 密钥？", isPresented: $input.confirmRemoval) {
            Button("移除", role: .destructive) { input.draft = ""; Task { await settings.remove() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("云端辅助将关闭。这不会撤销 DeepSeek 账户中的密钥，也无法撤回已发送的文字。")
        }
        .onDisappear { input.draft = "" }
    }
}

@MainActor
private final class CloudSettingsInput: ObservableObject {
    @Published var draft = ""
    @Published var confirmRemoval = false
}
