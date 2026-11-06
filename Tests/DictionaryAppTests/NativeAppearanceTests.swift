import AppKit
import SwiftUI
import Testing
@testable import DictionaryApp

/// Hidden, test-owned views only. No AppDelegate, live provider, permission probe or Keychain.
@MainActor
@Suite(.serialized)
struct NativeAppearanceTests {
    @Test func mainWindowFitsSmallDesktopWithoutTwoPermanentLargeEditors() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let state = ManualLookupState(coordinator: coordinator)
        try await host(MainWindowView(state: state, coordinator: coordinator), size: NSSize(width: 640, height: 520)) { view in
            #expect(view.fittingSize.width <= 640 && view.fittingSize.height <= 520)
            #expect(editors(view).count == 1) // context is optional, not a second permanent form
            #expect(editors(view).first?.frame.height ?? 1000 < 80)
        }
        #expect(await provider.calls.isEmpty)
    }

    @Test func existingManualContextRemainsEditableWhenOpeningView() async throws {
        let coordinator = LookupCoordinator(provider: ControlledProvider())
        let state = ManualLookupState(coordinator: coordinator)
        state.target = "bank"
        state.context = "We sat on the bank of the river."
        try await host(MainWindowView(state: state, coordinator: coordinator), size: NSSize(width: 860, height: 680)) { view in
            #expect(editors(view).contains { $0.string == state.context })
        }
    }

    @Test func settingsSectionsFitAndOpeningNeverTouchesCredentialsOrService() async throws {
        let store = AppearanceCredentials()
        let probe = AppearanceModelList()
        let cloud = CloudSettings(store: store, enabled: false, persistEnabled: { _ in }, applyProvider: { _ in })
        let local = LocalModelSettings(configuration: .init(environment: [:], savedModel: nil),
            savedModel: nil, probe: probe, persistModel: { _ in })
        for section in DictionarySettingsSection.allCases {
            try await host(DictionarySettingsView(settings: cloud, localSettings: local, section: section)
                .frame(width: 580, height: 500), size: NSSize(width: 580, height: 500)) { view in
                #expect(view.fittingSize.width <= 580)
                #expect(view.fittingSize.height <= 500)
            }
        }
        #expect(await store.accesses == 0)
        #expect(await probe.calls == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_UI_PREVIEWS"] != nil))
    func nativeScreensForOwnerReview() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let draft = ManualLookupState(coordinator: coordinator)
        let request = try LookupRequest.captured(target: "bank", context: "We sat on the bank of the river.",
            sentence: "We sat on the bank of the river.", source: "合成示例",
            capture: captureMetadata(start: 14, end: 18, sentenceStart: 0, sentenceEnd: 32))
        let phase = LookupPhase.finished(request, .success(LookupResult(request: request, translation:
            Translation(meaningInContext: "河岸", literalGloss: "银行；河岸", partOfSpeech: "noun",
                        exampleTranslation: "我们坐在河岸上。", alternatives: nil))))
        let cloud = CloudSettings(store: AppearanceCredentials(), enabled: false,
            persistEnabled: { _ in }, applyProvider: { _ in })
        let local = LocalModelSettings(configuration: .init(environment: [:], savedModel: nil),
            savedModel: nil, probe: AppearanceModelList(), persistModel: { _ in })
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            try await host(MainWindowView(state: draft, coordinator: coordinator), size: NSSize(width: 860, height: 680),
                           scheme: scheme, preview: "home-\(suffix)") { _ in }
            for section in DictionarySettingsSection.allCases {
                let name = section == .general ? "general" : section == .local ? "local" : "cloud"
                try await host(DictionarySettingsView(settings: cloud, localSettings: local, section: section)
                    .frame(width: 580, height: 580), size: NSSize(width: 580, height: 580), scheme: scheme, preview: "settings-\(name)-\(suffix)") { _ in }
            }
            try await host(ScrollView { LookupResultView(phase: phase).padding(28) }
                .background(DictionaryStyle.paper), size: NSSize(width: 600, height: 640), scheme: scheme,
                           preview: "result-\(suffix)") { _ in }
        }
        draft.target = "bank"
        draft.context = "We sat on the bank of the river."
        let operation = try #require(draft.submit())
        let call = await provider.waitForCall("bank")
        try await host(MainWindowView(state: draft, coordinator: coordinator), size: NSSize(width: 640, height: 520),
                       preview: "main-loading-small") { _ in }
        await provider.succeed(call, meaning: "河岸", example: "我们坐在河岸上。")
        _ = await operation.value
        try await host(MainWindowView(state: draft, coordinator: coordinator), size: NSSize(width: 860, height: 680),
                       preview: "main-result-light") { _ in }
    }

    private func editors(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_UI_PREVIEWS"] != nil))
    func dictionaryReferenceAndMissingMeaningPreview() async throws {
        for target in ["charged", "children"] {
            let reference = EnglishReferenceState()
            reference.expanded = true
            await reference.load(target: target)
            try await host(ScrollView {
                EnglishDictionaryReferenceView(target: target, reference: reference).padding(24)
            }.background(DictionaryStyle.paper), size: NSSize(width: 440, height: 500), preview: "reference-\(target)") { _ in }
        }
        let request = try LookupRequest.manual(target: "zyxqvexample", context: "")
        let translation = Translation(meaningInContext: "zyxqvexample", literalGloss: nil, partOfSpeech: nil,
            exampleTranslation: "REJECTED", alternatives: nil)
        let phase = LookupPhase.finished(request, .success(LookupResult(request: request, translation: translation)))
        try await host(ScrollView { LookupResultView(phase: phase, layout: .popup).padding(24) }.background(DictionaryStyle.paper),
            size: NSSize(width: 440, height: 380), preview: "echoed-meaning") { _ in }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let absent = try decoder.decode(Translation.self, from: Data(#"{"meaning_in_context":null}"#.utf8))
        let absentPhase = LookupPhase.finished(request, .success(LookupResult(request: request, translation: absent)))
        try await host(ScrollView { LookupResultView(phase: absentPhase, layout: .popup).padding(24) }.background(DictionaryStyle.paper),
            size: NSSize(width: 440, height: 380), preview: "null-meaning") { _ in }
        let river = try LookupRequest.manual(target: "river", context: "")
        let repeated = Translation(meaningInContext: "河", literalGloss: " 河 ", partOfSpeech: "noun",
                                   exampleTranslation: nil, alternatives: ["河", " ", "河"])
        let cleanPhase = LookupPhase.finished(river, .success(LookupResult(request: river, translation: repeated)))
        try await host(ScrollView { LookupResultView(phase: cleanPhase, layout: .popup).padding(24) }.background(DictionaryStyle.paper),
            size: NSSize(width: 440, height: 380), preview: "duplicate-meanings") { _ in }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_UI_PREVIEWS"] != nil))
    func permissionSettingsPreview() async throws {
        let cloud = CloudSettings(store: AppearanceCredentials(), enabled: false,
            persistEnabled: { _ in }, applyProvider: { _ in })
        let local = LocalModelSettings(configuration: .init(environment: [:], savedModel: nil),
            savedModel: nil, probe: AppearanceModelList(), persistModel: { _ in })
        for trusted in [false, true] {
            let readiness = AppReadiness(buildID: "synthetic-build", appURL: URL(fileURLWithPath: "/Synthetic/Dictionary.app"),
                checkPermission: { trusted }, openPermissionSettings: { false }, revealApp: { _ in })
            try await host(DictionarySettingsView(settings: cloud, localSettings: local, readiness: readiness)
                .frame(width: 580, height: 580), size: NSSize(width: 580, height: 580),
                preview: trusted ? "permission-granted" : "permission-required") { view in
                    #expect(view.fittingSize.width <= 580 && view.fittingSize.height <= 580)
                    #expect(readiness.permission == (trusted ? .granted : .required))
                }
        }
    }

    private func host<V: View>(_ root: V, size: NSSize, scheme: ColorScheme = .light, preview: String? = nil,
                               check: (NSView) throws -> Void) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = view
        defer { window.close() }
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!window.isVisible)
        try check(view)
        if let preview, let output = ProcessInfo.processInfo.environment["DICTIONARY_UI_PREVIEWS"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try #require(directory.lastPathComponent.hasPrefix("native-design-"))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(preview + ".png"), options: .withoutOverwriting)
        }
    }
}

private actor AppearanceCredentials: CloudCredentialStore {
    var accesses = 0
    func read() -> String? { accesses += 1; return nil }
    func save(_ key: String) { accesses += 1 }
    func remove() { accesses += 1 }
}

private actor AppearanceModelList: OllamaModelListing {
    var calls = 0
    func models() -> [String] { calls += 1; return ["qwen2.5:7b"] }
}
