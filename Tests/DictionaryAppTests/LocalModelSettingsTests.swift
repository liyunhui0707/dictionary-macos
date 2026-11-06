import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalModelSettingsTests {
    @Test func configurationPreservesExplicitLaunchOverridesAndIgnoresInvalidSavedNames() {
        #expect(LocalModelConfiguration(environment: [:], savedModel: nil).model == "qwen2.5:7b")
        #expect(LocalModelConfiguration(environment: [:], savedModel: "other:small").model == "other:small")
        let override = LocalModelConfiguration(environment: ["DICTIONARY_MODEL": "launch:model"], savedModel: "saved:model")
        #expect(override.model == "launch:model" && override.environmentOverride)
        #expect(LocalModelConfiguration(environment: [:], savedModel: "bad\nname").model == "qwen2.5:7b")
        let legacy = LocalModelConfiguration(environment: ["DICTIONARY_PROVIDER": "CLAUDE"], savedModel: "local:model")
        #expect(!legacy.isActive)
        #expect(legacy.model == "claude-haiku-4-5-20251001")
        #expect(LocalModelConfiguration(environment: ["DICTIONARY_PROVIDER": "unknown"], savedModel: nil).isActive)
    }

    @Test func openingSettingsDoesNotCheckOrPersistAndSavingOnlyAffectsNextLaunch() async {
        let probe = ModelProbeFixture()
        var saved: String?
        let settings = LocalModelSettings(configuration: .init(environment: [:], savedModel: nil),
            savedModel: nil, probe: probe, persistModel: { saved = $0 })
        #expect(await probe.calls == 0)
        #expect(settings.status == .unchecked && saved == nil)
        #expect(!settings.saveSelection())
        await settings.check()
        #expect(settings.status == .available)
        #expect(await probe.calls == 1 && saved == nil)
        settings.selectedModel = "other:small"
        #expect(settings.saveSelection())
        #expect(saved == "other:small")
        #expect(settings.configuration.model == "qwen2.5:7b")
        #expect(settings.restartRequired)
        #expect(LocalModelConfiguration(environment: [:], savedModel: saved).model == "other:small")
        #expect(await probe.calls == 1) // Saving does not probe, load or translate.
        settings.selectedModel = "invented:not-installed"
        #expect(!settings.saveSelection())
        #expect(saved == "other:small")
    }

    @Test func missingModelAndUnavailableServiceAreDifferentAndFailedRefreshClearsChoices() async {
        let probe = ModelProbeFixture(names: ["other:small"])
        let settings = LocalModelSettings(configuration: .init(environment: [:], savedModel: nil),
            savedModel: nil, probe: probe, persistModel: { _ in })
        await settings.check()
        #expect(settings.status == .missingModel)
        #expect(settings.selectedModel.isEmpty)
        await probe.fail(.unreachable)
        await settings.check()
        #expect(settings.status == .unavailable)
        #expect(settings.models.isEmpty && !settings.saveSelection())
        await probe.fail(.timedOut)
        await settings.check()
        #expect(settings.status == .timedOut)
        await probe.fail(.invalidResponse)
        await settings.check()
        #expect(settings.status == .invalidResponse)
    }

    @Test func explicitModelOverrideCannotBeSilentlyChangedAndLegacyDoesNotProbeOllama() async {
        let probe = ModelProbeFixture()
        var writes = 0
        let settings = LocalModelSettings(configuration: .init(environment: ["DICTIONARY_MODEL": "qwen2.5:7b"], savedModel: nil),
            savedModel: nil, probe: probe, persistModel: { _ in writes += 1 })
        await settings.check()
        settings.selectedModel = "other:small"
        #expect(!settings.canEdit && !settings.saveSelection() && writes == 0)
        let legacy = LocalModelSettings(configuration: .init(environment: ["DICTIONARY_PROVIDER": "claude"], savedModel: nil),
            savedModel: nil, probe: probe, persistModel: { _ in writes += 1 })
        await legacy.check()
        #expect(await probe.calls == 1)
        #expect(!legacy.canEdit && writes == 0)
    }

    @Test func defaultTagMatchesLatestButNeverAnUnrelatedModel() {
        #expect(LocalModelConfiguration.matches("example", "example:latest"))
        #expect(!LocalModelConfiguration.matches("example", "example:small"))
        #expect(!LocalModelConfiguration.matches("example", "other/example:latest"))
    }

    @Test func concurrentChecksCoalesceWithoutAutomaticRetry() async {
        let probe = ModelProbeFixture(paused: true)
        let settings = LocalModelSettings(configuration: .init(environment: [:], savedModel: nil),
            savedModel: nil, probe: probe, persistModel: { _ in })
        let first = Task { await settings.check() }
        await probe.waitForRead()
        await settings.check()
        #expect(settings.isChecking && settings.models.isEmpty)
        #expect(await probe.calls == 1)
        await probe.resume()
        await first.value
        #expect(!settings.isChecking && settings.status == .available)
    }
}

private actor ModelProbeFixture: OllamaModelListing {
    var calls = 0
    let names: [String]
    let paused: Bool
    var failure: OllamaServiceError?
    var reader: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    init(names: [String] = ["qwen2.5:7b", "other:small"], paused: Bool = false) {
        self.names = names; self.paused = paused
    }
    func models() async throws -> [String] {
        calls += 1
        if paused { await withCheckedContinuation { reader = $0; observer?.resume(); observer = nil } }
        if let failure { throw failure }
        return names
    }
    func fail(_ error: OllamaServiceError) { failure = error }
    func waitForRead() async {
        if reader == nil { await withCheckedContinuation { observer = $0 } }
    }
    func resume() { reader?.resume(); reader = nil }
}
