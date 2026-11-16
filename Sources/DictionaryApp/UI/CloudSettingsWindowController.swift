import AppKit
import SwiftUI

@MainActor
final class CloudSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: CloudSettings
    private let localSettings: LocalModelSettings
    private let readiness: AppReadiness
    private let serviceSettings: LookupServiceSettings
    private let progress: FirstLookupProgress
    private let support: SupportDiagnostics
    private let booksScreenSettings: BooksScreenSettings
    private let extensionSetup: BrowserExtensionSetup
    private let onExample: () -> Void
    private let onCopyExtensionToken: () -> Bool

    init(settings: CloudSettings, localSettings: LocalModelSettings, readiness: AppReadiness? = nil,
         serviceSettings: LookupServiceSettings? = nil, progress: FirstLookupProgress? = nil,
         support: SupportDiagnostics? = nil,
         booksScreenSettings: BooksScreenSettings? = nil,
         extensionSetup: BrowserExtensionSetup? = nil,
         onCopyExtensionToken: @escaping () -> Bool = { false },
         onExample: @escaping () -> Void = {}) {
        self.onExample = onExample
        self.onCopyExtensionToken = onCopyExtensionToken
        self.settings = settings
        self.localSettings = localSettings
        self.readiness = readiness ?? .preview()
        self.serviceSettings = serviceSettings ?? .preview()
        self.progress = progress ?? FirstLookupProgress()
        self.support = support ?? SupportDiagnostics()
        self.booksScreenSettings = booksScreenSettings ?? BooksScreenSettings()
        self.extensionSetup = extensionSetup ?? BrowserExtensionSetup()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dictionary · 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func open(section: DictionarySettingsSection = .general) {
        let height = min(580, max(240, (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 660) - 80)
        let host = NSHostingController(rootView:
            DictionarySettingsView(settings: settings, localSettings: localSettings, section: section,
                    readiness: readiness, serviceSettings: serviceSettings, progress: progress, support: support,
                    booksScreenSettings: booksScreenSettings, extensionSetup: extensionSetup,
                    onCopyExtensionToken: onCopyExtensionToken, onExample: onExample).frame(width: 580, height: height))
        window?.contentViewController = host
        window?.setContentSize(host.view.fittingSize)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil // discard any unsubmitted secure-field draft
    }
}

enum DictionarySettingsSection: String, CaseIterable {
    case started = "开始使用", general = "通用", service = "查词服务", local = "本地模型", cloud = "DeepSeek", support = "问题反馈"
}

@MainActor
private final class SettingsNavigation: ObservableObject {
    @Published var section: DictionarySettingsSection
    @Published var readingRoute: ReadingSetupRoute
    init(_ section: DictionarySettingsSection, readingRoute: ReadingSetupRoute) {
        self.section = section; self.readingRoute = readingRoute
    }
}

struct DictionarySettingsView: View {
    @ObservedObject var settings: CloudSettings
    @ObservedObject var localSettings: LocalModelSettings
    @ObservedObject var readiness: AppReadiness
    @ObservedObject var serviceSettings: LookupServiceSettings
    @ObservedObject var progress: FirstLookupProgress
    @ObservedObject var support: SupportDiagnostics
    @ObservedObject var booksScreenSettings: BooksScreenSettings
    @ObservedObject var extensionSetup: BrowserExtensionSetup
    let onExample: () -> Void
    let onCopyExtensionToken: () -> Bool
    @StateObject private var navigation: SettingsNavigation

    init(settings: CloudSettings, localSettings: LocalModelSettings, section: DictionarySettingsSection = .general,
         readiness: AppReadiness? = nil, serviceSettings: LookupServiceSettings? = nil,
         progress: FirstLookupProgress? = nil, support: SupportDiagnostics? = nil,
         booksScreenSettings: BooksScreenSettings? = nil, extensionSetup: BrowserExtensionSetup? = nil,
         readingRoute: ReadingSetupRoute = .browser,
         onCopyExtensionToken: @escaping () -> Bool = { false },
         onExample: @escaping () -> Void = {}) {
        self.onExample = onExample
        self.onCopyExtensionToken = onCopyExtensionToken
        self.settings = settings; self.localSettings = localSettings
        self.readiness = readiness ?? .preview()
        self.serviceSettings = serviceSettings ?? .preview()
        self.progress = progress ?? FirstLookupProgress()
        self.support = support ?? SupportDiagnostics()
        self.booksScreenSettings = booksScreenSettings ?? BooksScreenSettings()
        self.extensionSetup = extensionSetup ?? BrowserExtensionSetup()
        _navigation = StateObject(wrappedValue: SettingsNavigation(section, readingRoute: readingRoute))
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
                    case .started: GettingStartedView(service: serviceSettings, local: localSettings,
                        readiness: readiness, progress: progress, extensionSetup: extensionSetup,
                        booksScreenSettings: booksScreenSettings, readingRoute: $navigation.readingRoute,
                        onService: { navigation.section = .service },
                        onLocal: { navigation.section = .local }, onPermission: { navigation.section = .general },
                        onExample: onExample, onCopyExtensionToken: onCopyExtensionToken)
                    case .general: general
                    case .service: LookupServiceSettingsView(settings: serviceSettings, cloud: settings)
                    case .local: LocalModelSettingsView(settings: localSettings)
                    case .cloud: CloudSettingsView(settings: settings)
                    case .support: SupportDiagnosticsView(support: support, service: serviceSettings,
                        local: localSettings, readiness: readiness, onService: { navigation.section = .service },
                        onLocal: { navigation.section = .local }, onPermission: { navigation.section = .general })
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(DictionaryStyle.paper).foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
            .onAppear { readiness.refresh(); booksScreenSettings.refresh(); extensionSetup.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                readiness.refresh(); booksScreenSettings.refresh(); extensionSetup.refresh()
            }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            DictionaryCard {
                Toggle("Books 屏幕语境（本地识别）",isOn:Binding(
                    get:{ booksScreenSettings.enabled }, set:{ booksScreenSettings.setEnabled($0) }))
                    .accessibilityIdentifier("books-screen-context-enabled")
                Text("Books 无法提供原句时，尝试识别当前窗口鼠标附近的文字。保持鼠标停在选词旁；位置不明确或页面变化时不使用。每次先核对原句，再决定是否交给查词服务。")
                    .font(.system(size:12)).foregroundStyle(DictionaryStyle.secondary)
                Text("图片仅在内存中用于本地识别，不保存或上传。需要 macOS 屏幕录制权限，未授权时保持普通查词。")
                    .font(.system(size:12)).foregroundStyle(DictionaryStyle.secondary)
                HStack {
                    Text(booksScreenSettings.permissionGranted ? "屏幕权限已开启" : "屏幕权限未开启").font(.system(size:12))
                    Button("重新检查") { booksScreenSettings.refresh() }
                    if booksScreenSettings.enabled && !booksScreenSettings.permissionGranted {
                        Button("申请屏幕录制权限") { booksScreenSettings.requestPermission() }
                    }
                }
            }.onAppear { booksScreenSettings.refresh() }
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
                    if settings.status == .unavailable || settings.status == .timedOut {
                        Text("已安装 Ollama 时先打开它，再重新检查；还未安装时，从官方网站下载安装。Dictionary 不会自动安装服务。")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Link("打开 Ollama 官方下载页", destination: URL(string: "https://ollama.com/download/mac")!)
                    }
                    if settings.status == .missingModel {
                        Text("可选择下面已安装的模型。需要准备新模型时，请自行在 Ollama 中下载，完成后重新检查；模型不会随 Dictionary 安装。")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        if LocalModelConfiguration.matches(settings.configuration.model, LocalModelConfiguration.defaultModel) {
                            DisclosureGroup("准备默认本地模型") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("打开 Ollama 后，在终端运行下列命令。模型下载需要数 GB 空间；此处不会执行下载。")
                                    Text("ollama pull qwen2.5:7b").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Link("查看官方模型说明", destination: URL(string: "https://ollama.com/library/qwen2.5:7b")!)
                                    Text("默认模型仍有已知误译，准备完成不等于释义质量通过。")
                                }.font(.system(size: 12)).padding(.top, 6)
                            }
                        } else {
                            Link("查看 Ollama 模型目录", destination: URL(string: "https://ollama.com/library")!)
                        }
                    }
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
                DisclosureGroup("可选的语境对照模型") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(OllamaProvider.evaluatedReadingModel).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("本机小规模合成对照中，搭配、存在句和未知标签有所改善；仍有漏译等问题，不保证每次正确。")
                        Text("需要另行下载约 6.6 GB，运行时还需内存。准备好后检查连接，在已安装列表中选择并保存，重新打开 Dictionary 生效。不会自动下载或更换当前模型。")
                        Text("ollama pull \(OllamaProvider.evaluatedReadingModel)")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Link("查看该模型的官方说明", destination: URL(string: "https://ollama.com/library/qwen3.5:9b-q4_K_M")!)
                    }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }.font(.system(size: 12))
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
                        Text("DeepSeek API").font(.system(size: 14, weight: .medium))
                        Text(settings.isEnabled ? "已开启" : "未开启")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                    Spacer()
                    if settings.isEnabled { Button("关闭") { settings.disable() } }
                    else { Button("启用已存密钥") { Task { await settings.enableSavedKey() } } }
                }
            }
            Text("发起 DeepSeek 查询时，会发送选词、可获取的原句和附近语境，API 可能产生费用。保存密钥后，可在「查词服务」中选择云端查词。")
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
            Text("DeepSeek 将关闭。这不会撤销 DeepSeek 账户中的密钥，也无法撤回已发送的文字。")
        }
        .onDisappear { input.draft = "" }
    }
}

@MainActor
private final class CloudSettingsInput: ObservableObject {
    @Published var draft = ""
    @Published var confirmRemoval = false
}
