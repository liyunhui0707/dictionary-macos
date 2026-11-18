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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
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
                    onCopyExtensionToken: onCopyExtensionToken, onExample: onExample).frame(width: 680, height: height))
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
    case started = "开始使用", general = "通用", service = "翻译与发音", local = "本地模型", cloud = "DeepSeek", support = "帮助", reading = "阅读与权限"
    static let categories: [Self] = [.general, .service, .reading, .support]
    var category: Self {
        switch self { case .local, .cloud: return .service; case .started: return .support; default: return self }
    }
    var symbol: String {
        switch category { case .general: return "slider.horizontal.3"; case .service: return "character.bubble"; case .reading: return "book"; default: return "questionmark.circle" }
    }
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dictionary").font(.system(size: 15, weight: .semibold)).padding(.bottom, 16)
                ForEach(DictionarySettingsSection.categories, id: \.self) { category in
                    Button { navigation.section = category } label: {
                        Label(category.rawValue, systemImage: category.symbol)
                            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(navigation.section.category == category ? DictionaryStyle.accent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(14).frame(width: 145).background(DictionaryStyle.surface)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.section.category.rawValue).font(.system(size: 20, weight: .semibold)).padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch navigation.section {
                        case .general: general
                        case .reading: reading
                        case .service, .local, .cloud: service
                        case .started: gettingStarted
                        case .support:
                            Button("开始使用指南") { navigation.section = .started }
                            SupportDiagnosticsView(support: support, service: serviceSettings,
                                local: localSettings, readiness: readiness, onService: { navigation.section = .service },
                                onLocal: { navigation.section = .local }, onPermission: { navigation.section = .reading })
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.background(DictionaryStyle.paper).foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
            .onAppear { readiness.refresh(); booksScreenSettings.refresh(); extensionSetup.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                readiness.refresh(); booksScreenSettings.refresh(); extensionSetup.refresh()
            }
    }

    private var gettingStarted: some View {
        GettingStartedView(service: serviceSettings, local: localSettings,
            readiness: readiness, progress: progress, extensionSetup: extensionSetup,
            booksScreenSettings: booksScreenSettings, readingRoute: $navigation.readingRoute,
            onService: { navigation.section = .service }, onLocal: { navigation.section = .local },
            onPermission: { navigation.section = .reading }, onExample: onExample,
            onCopyExtensionToken: onCopyExtensionToken)
    }

    private var service: some View {
        VStack(alignment: .leading, spacing: 20) {
            LookupServiceSettingsView(settings: serviceSettings, cloud: settings)
            DisclosureGroup("Ollama 配置", isExpanded: Binding(get: { navigation.section == .local },
                set: { navigation.section = $0 ? .local : .service })) { LocalModelSettingsView(settings: localSettings).padding(.top, 12) }
            DisclosureGroup("DeepSeek 配置", isExpanded: Binding(get: { navigation.section == .cloud },
                set: { navigation.section = $0 ? .cloud : .service })) { CloudSettingsView(settings: settings).padding(.top, 12) }
            Divider()
            SpeechSettingsView()
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(readiness.permissionLabel, systemImage: readiness.permission == .granted ? "checkmark.circle" : "hand.raised")
                Spacer()
                Button("重新检查") { readiness.refresh() }.controlSize(.small)
            }.font(.system(size: 13))
            if readiness.permission != .granted {
                Text("在系统设置中为当前 Dictionary 开启辅助功能，才能从其他 App 选词。未授权时仍可手动输入。")
                Button("打开权限设置") { readiness.openSettings() }
                if readiness.settingsOpenFailed { Text("系统设置 → 隐私与安全 → 辅助功能").font(.caption) }
            }
            Divider()
            Toggle("Books 屏幕语境", isOn: Binding(get: { booksScreenSettings.enabled }, set: { booksScreenSettings.setEnabled($0) }))
                .accessibilityIdentifier("books-screen-context-enabled")
            Text("无法取得原句时，在本地识别 Books 选词附近的文字。图片不保存或上传。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            if booksScreenSettings.enabled {
                HStack {
                    Text(booksScreenSettings.permissionGranted ? "屏幕权限已开启" : "需要屏幕录制权限")
                    Spacer()
                    Button("重新检查") { booksScreenSettings.refresh() }.controlSize(.small)
                }
                if !booksScreenSettings.permissionGranted {
                    Button("申请屏幕录制权限") { booksScreenSettings.requestPermission() }
                }
                Toggle("可靠语境自动交给本地服务", isOn: Binding(get: { booksScreenSettings.automaticLocal }, set: { booksScreenSettings.setAutomaticLocal($0) }))
                    .accessibilityIdentifier("screen-context-auto-local")
                Toggle("可靠语境自动发送至所选云端服务", isOn: Binding(get: { booksScreenSettings.automaticCloud }, set: { booksScreenSettings.setAutomaticCloud($0) }))
                    .accessibilityIdentifier("screen-context-auto-cloud")
                Text("两项默认关闭。开启后，识别文字会直接交给对应服务，云端查询可能收费。检测到位置、页面或文字异常时仍需核对；自动筛选不保证识别准确。")
                    .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            }
            DisclosureGroup("使用与隐私说明") {
                Text("按快捷键时让鼠标停在选词旁。只读取当前 Books 窗口的局部画面，不在后台持续捕获。可在查询前修改识别错字；无需原句时可仅查单词。授权不代表所有阅读 App 都支持语境。")
                    .font(.system(size: 12)).padding(.top, 6)
            }
            Divider()
            HStack {
                Text("浏览器与其他阅读软件")
                Spacer()
                Button("接入指南") { navigation.section = .started }
            }
        }.font(.system(size: 13))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            preference("选词与翻译", value: "⌥ D")
            preference("手动提交", value: "⌘ Return")
            preference("关闭浮窗", value: "Esc")
            Text("选中单词查词，选中句段翻译；可在结果中切换。需要保留结果时点击固定。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            Divider()
            preference("外观", value: "跟随 macOS 系统")
            preference("当前翻译方向", value: "英语 → 简体中文")
            Text("以上为当前支持范围。").font(.caption).foregroundStyle(DictionaryStyle.secondary)
            Divider()
            Text("当前版本").font(.system(size: 13, weight: .medium))
            Text(readiness.buildLabel).font(.system(size: 11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("在 Finder 中显示当前 App") { readiness.reveal() }.font(.system(size: 12))
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
