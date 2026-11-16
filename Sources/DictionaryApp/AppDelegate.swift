import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let selectionReader = SelectionReader()
    private let safariContextExtractor = SafariContextExtractor()
    private let diagnostics = QADiagnostics.forCurrentProcess()
    private let support = SupportDiagnostics()
    private lazy var popupController = PopupController(coordinator: coordinator, diagnostics: diagnostics)
    private let hotkey = GlobalHotkey()
    private let provider: TranslationProvider
    private let localConfiguration: LocalModelConfiguration
    private let cloudCredentialStore: KeychainCloudCredentialStore
    private let preferences: UserDefaults
    private let extensionDirectory: URL
    private lazy var extensionSetup = BrowserExtensionSetup(managedParent: extensionDirectory,
        savedDirectory: preferences.string(forKey: BrowserExtensionSetup.preference).flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        }, persist: { [weak self] in self?.preferences.set($0.path, forKey: BrowserExtensionSetup.preference) })
    private lazy var booksScreenSettings = BooksScreenSettings(
        enabled: preferences.bool(forKey: BooksScreenSettings.preference),
        persist: { [weak self] in self?.preferences.set($0,forKey:BooksScreenSettings.preference) })
    private var configuredCloudProvider: TranslationProvider?
    private var appliedPrimaryConfiguration: String?
    private lazy var serviceSettings = LookupServiceSettings(
        saved: preferences.string(forKey: LookupServiceSettings.preference),
        isManaged: !localConfiguration.isActive,
        persist: { [weak self] in self?.preferences.set($0, forKey: LookupServiceSettings.preference) },
        changed: { [weak self] in self?.applyLookupConfiguration() })
    private lazy var localSettings = LocalModelSettings(configuration: localConfiguration,
        savedModel: preferences.string(forKey: LocalModelConfiguration.modelPreference),
        persistModel: { [weak self] in self?.preferences.set($0, forKey: LocalModelConfiguration.modelPreference) })
    private lazy var coordinator = LookupCoordinator(provider: UnconfiguredLookupProvider(cloudDisabled: false), targetLanguage: targetLanguage,
        support: support)
    private lazy var firstLookupProgress = FirstLookupProgress(coordinator: coordinator)
    private lazy var cloudSettings = CloudSettings(store: cloudCredentialStore,
        enabled: preferences.bool(forKey: CloudSettings.enabledPreference),
        persistEnabled: { [weak self] in self?.preferences.set($0, forKey: CloudSettings.enabledPreference) },
        applyProvider: { [weak self] provider in
            self?.configuredCloudProvider = provider
            self?.serviceSettings.setCloudAvailable(provider != nil)
        })
    private lazy var readiness = AppReadiness.live(diagnostics: diagnostics)
    private lazy var updateWindow = ReleaseUpdateWindow(installed:
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "源码构建")
    private lazy var cloudSettingsWindow = CloudSettingsWindowController(settings: cloudSettings, localSettings: localSettings,
        readiness: readiness, serviceSettings: serviceSettings, progress: firstLookupProgress, support: support,
        booksScreenSettings: booksScreenSettings, extensionSetup: extensionSetup,
        onCopyExtensionToken: { [weak self] in self?.copyExtensionToken() ?? false },
        onExample: { [weak self] in self?.prepareExample() })
    private lazy var mainWindowController = MainWindowController(coordinator: coordinator, readiness: readiness,
        serviceSettings: serviceSettings, onSettings: { [weak self] in self?.openSettings() },
        onSetup: { [weak self] in self?.cloudSettingsWindow.open(section: .service) },
        onGettingStarted: { [weak self] in self?.openGettingStarted() })
    private lazy var captureController = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
    private let targetLanguage = "简体中文"
    private let tokenStore: TokenStore
    private var httpServer: HTTPServer?
    private static let httpPort: UInt16 = 49152

    /// Safari exposes selection through AX but not the surrounding text
    /// range, so we route these bundles to SafariContextExtractor instead.
    private static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    /// Apps that bind their own ⌥D via `chrome.commands`. When one of these is
    /// frontmost we *unregister* the Mac app's Carbon hotkey so the browser's
    /// extension receives the keystroke instead. The trade-off: a tiny race
    /// window during focus switches where neither binding is live.
    private static let chromiumBrowserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.operasoftware.OperaNext",
        "company.thebrowser.Browser" // Arc
    ]

    /// Electron apps that ship their own ⌥D handler (a plugin that POSTs to the
    /// local HTTP server, mirroring the browser extension). Like the browsers
    /// above, we unregister the Carbon hotkey while one is frontmost so the
    /// keystroke reaches the app instead of being swallowed system-wide.
    private static let pluginHandledBundleIDs: Set<String> = [
        "md.obsidian"
    ]

    init(firstUse: FirstUseIsolation? = nil) throws {
        let preferences: UserDefaults
        if let firstUse {
            guard let isolated = UserDefaults(suiteName: firstUse.preferencesDomain) else {
                throw FirstUseIsolation.Failure.unavailablePreferences
            }
            preferences = isolated
        } else { preferences = .standard }
        self.preferences = preferences
        self.extensionDirectory = firstUse?.tokenDirectory.appendingPathComponent("BrowserExtensions", isDirectory: true)
            ?? BrowserExtensionSetup.defaultParent
        self.cloudCredentialStore = KeychainCloudCredentialStore(isolationID: firstUse?.id)
        self.tokenStore = TokenStore(directory: firstUse?.tokenDirectory)
        let environment = ProcessInfo.processInfo.environment
        let configuration = LocalModelConfiguration(environment: environment,
            savedModel: preferences.string(forKey: LocalModelConfiguration.modelPreference))
        self.localConfiguration = configuration
        self.provider = Self.makeProvider(environment: environment, configuration: configuration)
        super.init()
    }

    private static func makeProvider(environment env: [String: String], configuration: LocalModelConfiguration) -> TranslationProvider {
        let name = env["DICTIONARY_PROVIDER"]?.lowercased() ?? "ollama"
        switch name {
        case "claude":
            let key = env["ANTHROPIC_API_KEY"] ?? ""
            return ClaudeProvider(apiKey: key, model: configuration.model)
        default:
            let keepAlive = env["OLLAMA_KEEP_ALIVE"] ?? "30m"
            return OllamaProvider(model: configuration.model, keepAlive: keepAlive)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostics?.record(QAEvent(kind: .processStarted, trusted: AXIsProcessTrusted()))
        _ = cloudSettings
        applyLookupConfiguration()
        _ = firstLookupProgress
        setupApplicationMenu()
        setupStatusItem()
        _ = popupController
        ensureAccessibilityPermission()
        installFocusObserver()
        // Bind the hotkey based on whichever app is currently frontmost.
        refreshHotkeyForFrontmostApp()
        startHTTPServer()
        mainWindowController.open()
    }

    private func applyLookupConfiguration() {
        let managed = !localConfiguration.isActive
        let selected = serviceSettings.selected
        let cloud = !managed && selected == .deepSeek
        let ready = managed || !serviceSettings.needsSetup
        let identity = "\(managed)/\(selected?.rawValue ?? "unconfigured")/\(ready)"
        if identity != appliedPrimaryConfiguration {
            let primary: TranslationProvider
            if !ready { primary = UnconfiguredLookupProvider(cloudDisabled: cloud) }
            else if cloud { primary = KeychainDeepSeekProvider(store: cloudCredentialStore, purpose: .lookup) }
            else { primary = provider }
            coordinator.configurePrimaryProvider(primary,
                label: managed ? "Claude" : cloud ? "DeepSeek" : "Ollama", isCloud: cloud)
            appliedPrimaryConfiguration = identity
        }
        coordinator.configureCloudProvider(cloud ? nil : configuredCloudProvider)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
        httpServer?.stop()
        httpServer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Focus-aware hotkey toggle

    private func installFocusObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeAppChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        applyHotkeyState(forBundleID: app?.bundleIdentifier ?? "")
    }

    private func refreshHotkeyForFrontmostApp() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        applyHotkeyState(forBundleID: bundleID)
    }

    private func applyHotkeyState(forBundleID bundleID: String) {
        if bundleID == Bundle.main.bundleIdentifier || Self.chromiumBrowserBundleIDs.contains(bundleID)
            || Self.pluginHandledBundleIDs.contains(bundleID) {
            hotkey.unregister()
        } else {
            let status = hotkey.register { [weak self] in
                Task { @MainActor in self?.performLookup() }
            }
            diagnostics?.record(QAEvent(kind: .hotkeyRegistration, statusCode: status))
            support.hotkeyRegistered(status == 0)
        }
    }

    private func startHTTPServer() {
        // Eagerly materialize the token file so users can verify the install
        // invariant (~/Library/Application Support/DictionaryApp/token exists,
        // mode 0600) immediately after launch.
        _ = tokenStore.token

        let handler = TranslateHandler(
            tokenStore: tokenStore,
            coordinator: coordinator, support: support
        )
        let server = HTTPServer(port: Self.httpPort, handler: handler) { [weak support] state in
            DispatchQueue.main.async { support?.listenerChanged(state) }
        }
        do {
            try server.start()
            httpServer = server
        } catch {
            DispatchQueue.main.async { [weak support] in support?.listenerChanged(.unavailable) }
            NSLog("Dictionary HTTP server failed to start on port \(Self.httpPort): \(error)")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Dictionary")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 Dictionary", action: #selector(openDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "开始使用…", action: #selector(openGettingStarted), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "诊断与反馈…", action: #selector(openSupport), keyEquivalent: ""))
        if QABuildIdentity.current != nil {
            menu.addItem(NSMenuItem(title: "QA Build & Diagnostics…", action: #selector(showQADiagnostics), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Lookup Selection (⌥D)", action: #selector(performLookup), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy extension token", action: #selector(copyTokenToClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Regenerate extension token", action: #selector(regenerateToken), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showAboutDictionary() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未打包构建"
        let build = QABuildIdentity.current?.buildID ??
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "源码运行")
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationVersion: version,
            .version: build,
            .credits: NSAttributedString(string: "根据语境理解英文。\nAI 释义请结合原句与词典参考核对。")
        ])
    }

    @objc private func openReleaseDownloads() {
        NSWorkspace.shared.open(PublicRelease.downloads)
    }

    @objc private func checkForUpdates() { updateWindow.open() }

    @objc private func openDictionary() { mainWindowController.open() }
    @objc private func openSettings() { cloudSettingsWindow.open() }
    private func prepareExample() {
        _ = mainWindowController.lookupState.prepareExample()
        mainWindowController.open()
    }
    @objc private func openGettingStarted() { cloudSettingsWindow.open(section: .started) }
    @objc private func openSupport() { cloudSettingsWindow.open(section: .support) }

    @objc private func showQADiagnostics() {
        let alert = NSAlert()
        alert.messageText = "QA build identity"
        let build = QABuildIdentity.current
        let logState = diagnostics == nil ? "Not enabled; launch with scripts/qa-app.mjs." :
            diagnostics?.writeFailed == true ? "Log write failed; evidence incomplete." :
            diagnostics?.limitReached == true ? "Log limit reached; start a new QA run." : "Recording metadata only."
        alert.informativeText = "Build: \(build?.buildID ?? "unknown")\nSource: \(build?.sourceFingerprint ?? "unknown")\nPID: \(ProcessInfo.processInfo.processIdentifier)\nAccessibility trusted now: \(AXIsProcessTrusted())\n\(logState)\n\(diagnostics?.logURL?.path ?? "")"
        alert.addButton(withTitle: "OK")
        if diagnostics?.logURL != nil { alert.addButton(withTitle: "Reveal diagnostics") }
        if alert.runModal() == .alertSecondButtonReturn, let url = diagnostics?.logURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func setupApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu()
        application.addItem(NSMenuItem(title: "关于 Dictionary", action: #selector(showAboutDictionary), keyEquivalent: ""))
        application.addItem(NSMenuItem(title: "开始使用…", action: #selector(openGettingStarted), keyEquivalent: ""))
        application.addItem(NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ","))
        application.addItem(NSMenuItem(title: "诊断与反馈…", action: #selector(openSupport), keyEquivalent: ""))
        application.addItem(NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: ""))
        application.addItem(NSMenuItem(title: "查看更新与下载…", action: #selector(openReleaseDownloads), keyEquivalent: ""))
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "隐藏 Dictionary", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        application.addItem(NSMenuItem(title: "退出 Dictionary", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = application
        main.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                     ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        let window = NSMenu(title: "窗口")
        window.addItem(NSMenuItem(title: "打开 Dictionary", action: #selector(openDictionary), keyEquivalent: "0"))
        window.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func copyTokenToClipboard() {
        _ = copyExtensionToken()
    }

    private func copyExtensionToken() -> Bool {
        let token = tokenStore.token
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(token, forType: .string)
    }

    @objc private func regenerateToken() {
        _ = tokenStore.regenerate()
        // Also copy the new token for convenience.
        copyTokenToClipboard()
    }

    private func ensureAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // QA records the exact process's trust without requesting a permission change.
        let trusted = diagnostics == nil ? AXIsProcessTrustedWithOptions([key: true] as CFDictionary) : AXIsProcessTrusted()
        diagnostics?.record(QAEvent(kind: .accessibilityChecked, trusted: trusted))
    }

    @objc private func performLookup() {
        guard let source = NSWorkspace.shared.frontmostApplication,
              source.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        captureController.start(source: source.localizedName ?? "Selection", sourcePID: source.processIdentifier,
                                sourceBundleID: source.bundleIdentifier, isSourceCurrent: {
            !source.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier
        }) { [self] in try await captureTargetAndContext(source: source) }
    }

    /// Capture strategy, in order:
    /// 1. **Safari special case** — when Safari is frontmost, ask it via
    ///    AppleScript to run a small JS snippet that reads the DOM paragraph.
    ///    The generic AX path can fetch Safari's selection but not its
    ///    surrounding text range (Safari uses AXTextMarker for web content).
    /// 2. **Generic AX** — works in Notes, Mail, TextEdit, iTerm2, Xcode,
    ///    and most native Cocoa text views.
    /// 3. **Pasteboard fallback** — simulated ⌘C for apps that expose
    ///    neither AX text nor JavaScript (Electron apps, some PDFs).
    private func captureTargetAndContext(source: NSRunningApplication) async throws -> CapturedContext {
        let extractor = ContextExtractor(sourceApplication: AXUIElementCreateApplication(source.processIdentifier))
        let isBooks = source.bundleIdentifier == "com.apple.iBooksX"
        let screenEnabled = isBooks && booksScreenSettings.enabled
        var firstReport = screenEnabled ? extractor.extractReport() : nil
        let hasSentence = firstReport?.captured?.containingSentence != nil
        let isCurrent = { !source.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier }
        let pipeline = NativeCapturePipeline(isTrusted: { AXIsProcessTrusted() },
            safari: { [self] in safariContextExtractor.extract() }, ax: {
                if let report=firstReport { firstReport=nil; return report }
                return extractor.extractReport()
            },
            clipboard: { [self] in try await selectionReader.readSelectionResult() },
            isSourceCurrent: { !source.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier })
        let bundleID = source.bundleIdentifier ?? ""
        var screenStatus: ScreenContextStatus?
        var captured = try await BooksScreenFallback.capture(enabled:screenEnabled,isBooks:isBooks,
            permission:screenEnabled && CGPreflightScreenCaptureAccess(),nativeHasSentence:hasSentence,
            isCurrent:isCurrent, snapshot:{ await BooksScreenCapture.snapshot(source:source,isCurrent:isCurrent,failed:{screenStatus=$0}) },
            native:{ try await pipeline.capture(isSafari:Self.safariBundleIDs.contains(bundleID),isBooks:isBooks) },
            recognize:{ await ScreenTextRecognition.recognize(snapshot:$0,target:$1,timeout:$2) })
        if captured.containingSentence == nil, let screenStatus { captured.diagnostics.screenContext=screenStatus }
        return captured
    }
}
