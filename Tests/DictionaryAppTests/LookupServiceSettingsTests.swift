import Testing
@testable import DictionaryApp

@MainActor
struct LookupServiceSettingsTests {
    @Test func firstUseRequiresChoiceAndCloudRequiresExplicitConsent() {
        var writes: [String] = []
        var changes = 0
        let settings = LookupServiceSettings(saved: nil, persist: { writes.append($0) }, changed: { changes += 1 })
        #expect(settings.needsSetup && writes.isEmpty && changes == 0)
        #expect(!settings.choose(.deepSeek, cloudConsent: true))
        settings.setCloudAvailable(true)
        #expect(settings.selected == nil && writes.isEmpty) // old assistance key is not primary consent
        #expect(!settings.choose(.deepSeek))
        #expect(settings.choose(.deepSeek, cloudConsent: true))
        #expect(!settings.needsSetup && writes == ["deepSeek"])
        settings.setCloudAvailable(false)
        #expect(settings.needsSetup && settings.selected == .deepSeek)
        #expect(settings.choose(.local) && !settings.needsSetup)
        #expect(writes == ["deepSeek", "local"])
    }

    @Test func restoredChoiceAndManagedLaunchNeverPersistOnConstruction() {
        let restored = LookupServiceSettings(saved: "deepSeek", persist: { _ in Issue.record("Unexpected write") })
        #expect(restored.needsSetup)
        restored.setCloudAvailable(true)
        #expect(!restored.needsSetup)
        let managed = LookupServiceSettings(saved: nil, isManaged: true, persist: { _ in Issue.record("Unexpected write") })
        #expect(!managed.needsSetup && !managed.choose(.local))
        #expect(LookupServiceSettings(saved: "unknown").needsSetup)
    }

    @Test func changingPrimaryCancelsBothChannelsAndRejectsLateOldResults() async throws {
        let old = ControlledProvider(), new = ControlledProvider()
        let coordinator = LookupCoordinator(provider: old)
        let manual = coordinator.submit(try .manual(target: "bank", context: "The bank closed."), to: .manual)
        let selection = coordinator.submit(try .manual(target: "seal", context: "The seal swam."), to: .selection)
        await old.waitForCall("bank"); await old.waitForCall("seal")
        let intent = coordinator.selectionIntent
        coordinator.configurePrimaryProvider(new, label: "DeepSeek", isCloud: true)
        #expect(await manual.value.isCancelled)
        #expect(await selection.value.isCancelled)
        #expect(!coordinator.isCurrentCapture(intent))
        let next = coordinator.submit(try .manual(target: "bank", context: "The river bank."), to: .manual)
        await new.waitForCall("bank")
        await old.succeed("bank", meaning: "旧答案"); await old.succeed("seal")
        await manual.providerTask?.value; await selection.providerTask?.value
        #expect(coordinator.manual.isLoading && coordinator.selection.result == nil)
        await new.succeed("bank", meaning: "河岸")
        #expect(await next.value.result?.translation.meaningInContext == "河岸")
        #expect(coordinator.primaryLabel == "DeepSeek" && coordinator.primaryIsCloud)
        coordinator.configurePrimaryProvider(UnconfiguredLookupProvider(cloudDisabled: true), label: "DeepSeek", isCloud: true)
        coordinator.closeManual()
        #expect(coordinator.manual.result == nil && coordinator.lastManualResult == nil)
        let disabled = coordinator.submit(try .manual(target: "bank", context: ""), to: .manual)
        #expect(await disabled.value.result == nil)
        #expect(await new.calls.count == 1)
    }
}
