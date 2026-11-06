import Foundation
import Security
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloudSettingsTests {
    @Test func launchAndRestartDoNotReadCredentialsOrSendRequests() async {
        let store = MemoryCloudCredentials()
        var enabled = false
        var configured = false
        let settings = CloudSettings(store: store, enabled: enabled,
            persistEnabled: { enabled = $0 }, applyProvider: { configured = $0 != nil })
        #expect(!configured)
        #expect(await settings.save("synthetic-only"))
        #expect(enabled && configured)
        let reads = await store.reads
        let restarted = CloudSettings(store: store, enabled: enabled,
            persistEnabled: { enabled = $0 }, applyProvider: { configured = $0 != nil })
        #expect(restarted.isEnabled && configured)
        #expect(await store.reads == reads)
        #expect(!restarted.message.contains("synthetic-only"))
        restarted.disable()
        #expect(!enabled && !configured)
        #expect(await store.value == "synthetic-only")
    }

    @Test(arguments: ["", "bad key", "bad\nkey", "密钥", String(repeating: "x", count: 4097)])
    func malformedKeysNeverReachStorage(key: String) async {
        let store = MemoryCloudCredentials()
        let settings = CloudSettings(store: store, enabled: false, persistEnabled: { _ in }, applyProvider: { _ in })
        #expect(await settings.save(key) == false)
        #expect(await store.writes == 0)
        #expect(!settings.isEnabled)
    }

    @Test func failedReplacementAndFailedRemovalDisableWithoutClaimingDeletion() async {
        let store = MemoryCloudCredentials(value: "old-synthetic")
        var enabled = true
        var configured = false
        let settings = CloudSettings(store: store, enabled: true,
            persistEnabled: { enabled = $0 }, applyProvider: { configured = $0 != nil })
        await store.setFailure(true)
        #expect(await settings.save("new-synthetic") == false)
        #expect(!enabled && !configured)
        #expect(await store.value == "old-synthetic")
        #expect(!settings.message.contains("SECRET_ERROR"))
        await settings.remove()
        #expect(settings.message.contains("未能从钥匙串移除"))
        #expect(await store.value == "old-synthetic")
        #expect(!settings.isEnabled)
    }

    @Test func enableRequiresReadableKeyAndRemovalPersistsOff() async {
        let store = MemoryCloudCredentials()
        var enabled = false
        let settings = CloudSettings(store: store, enabled: false,
            persistEnabled: { enabled = $0 }, applyProvider: { _ in })
        await settings.enableSavedKey()
        #expect(!enabled)
        #expect(await settings.save("synthetic-only"))
        settings.disable()
        await settings.enableSavedKey()
        #expect(enabled)
        await settings.remove()
        #expect(!enabled && !settings.isEnabled)
        #expect(await store.value == nil)
    }

    @Test func configurationChangeCancelsBothChannelsAndRejectsOldButtonsAndLateResults() async throws {
        let local = ControlledProvider(), oldCloud = ControlledProvider(), newCloud = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: oldCloud)
        let request = try LookupRequest.manual(target: "bank", context: "We sat on the bank.")
        let original = coordinator.submit(request, to: .selection)
        let localCall = await local.waitForCall("bank")
        await local.succeed(localCall, meaning: "银行")
        _ = await original.value
        coordinator.manualCloud.prepare(request)
        let manualID = try #require(coordinator.manualCloud.offer?.id)
        let selectionID = try #require(coordinator.selectionCloud.offer?.id)
        let task = try #require(coordinator.selectionCloud.ask(offerID: selectionID))
        let call = await oldCloud.waitForCall("bank")
        coordinator.configureCloudProvider(newCloud)
        #expect(coordinator.manualCloud.ask(offerID: manualID) == nil)
        #expect(coordinator.selectionCloud.ask(offerID: selectionID) == nil)
        await oldCloud.succeed(call, meaning: "obsolete")
        await task.value
        #expect(coordinator.selectionCloud.phase.result == nil)
        #expect(await newCloud.calls.isEmpty)
        #expect(await local.calls.count == 1)
        #expect(coordinator.selection.result?.translation.meaningInContext == "银行")
        coordinator.configureCloudProvider(nil)
        #expect(!coordinator.manualCloud.isConfigured && !coordinator.selectionCloud.isConfigured)
        #expect(coordinator.selection.result?.translation.meaningInContext == "银行")
    }
}

private actor MemoryCloudCredentials: CloudCredentialStore {
    var value: String?
    var reads = 0
    var writes = 0
    var fails = false
    init(value: String? = nil) { self.value = value }
    func setFailure(_ value: Bool) { fails = value }
    func read() throws -> String? {
        reads += 1
        if fails { throw NSError(domain: "SECRET_ERROR", code: 1) }
        return value
    }
    func save(_ key: String) throws {
        writes += 1
        if fails { throw NSError(domain: "SECRET_ERROR", code: 1) }
        value = key
    }
    func remove() throws {
        if fails { throw NSError(domain: "SECRET_ERROR", code: 1) }
        value = nil
    }
}
