import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FirstLookupProgressTests {
    private let sentence = "They walked along the bank of the river."

    private func complete(_ coordinator: LookupCoordinator, _ provider: ControlledProvider,
                          channel: LookupChannel, context: Bool = true, meaning: String = "河岸") async throws {
        let request = channel == .manual
            ? try LookupRequest.manual(target: "bank", context: context ? sentence : "")
            : try LookupRequest.captured(target: "bank", context: context ? sentence : nil,
                sentence: context ? sentence : nil, source: "Synthetic Reader",
                capture: .init(reliability: context ? .heuristic : .targetOnly, method: .axTreeWalk))
        let callCount = await provider.calls.count
        let operation = coordinator.submit(request, to: channel)
        let call = await provider.waitForCall("bank", occurrence: callCount + 1)
        await provider.succeed(call, meaning: meaning)
        _ = await operation.value
    }

    @Test func openingOrConfiguringNeverClaimsAQueryOrCallsAProvider() async {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: ControlledProvider())
        let progress = FirstLookupProgress(coordinator: coordinator)
        coordinator.configurePrimaryProvider(provider, label: "Ollama", isCloud: false)
        #expect(progress.manual == .notStarted && progress.reading == .notStarted)
        #expect(!progress.isComplete && !progress.confirmReading())
        #expect(await provider.calls.isEmpty)
    }

    @Test func responseDoesNotProveMeaningAndReadingRequiresExplicitConfirmation() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let progress = FirstLookupProgress(coordinator: coordinator)
        // Deliberately wrong meaning: JSON/transport success must not auto-pass semantics.
        try await complete(coordinator, provider, channel: .manual, meaning: "银行")
        try await complete(coordinator, provider, channel: .selection, meaning: "银行")
        #expect(progress.manual == .responseReceived && progress.reading == .responseReceived)
        #expect(!progress.isComplete && progress.canConfirmReading)
        coordinator.dismissSelection()
        #expect(progress.canConfirmReading)
        #expect(progress.confirmReading() && progress.isComplete)
        coordinator.closeManual()
        #expect(progress.isComplete) // Merely closing a window is not another query.
        progress.rejectReading()
        #expect(progress.reading == .needsReview && !progress.isComplete && !progress.canConfirmReading)
    }

    @Test func switchingReadingRouteKeepsManualEvidenceButRequiresANewReadingCheck() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let time = Date(timeIntervalSince1970: 30)
        let progress = FirstLookupProgress(coordinator: coordinator, now: { time })
        try await complete(coordinator, provider, channel: .manual)
        try await complete(coordinator, provider, channel: .selection)
        #expect(progress.lastResponseAt == time && progress.confirmReading())
        let count = await provider.calls.count
        progress.resetReading()
        #expect(progress.manual == .responseReceived && progress.reading == .notStarted)
        #expect(!progress.isComplete && !progress.confirmReading())
        #expect(await provider.calls.count == count)
        coordinator.configurePrimaryProvider(provider, label: "Synthetic", isCloud: false)
        #expect(progress.lastResponseAt == nil)
    }

    @Test func closingCancelledManualQueryCannotReuseAnOlderSuccessAsNewEvidence() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let progress = FirstLookupProgress(coordinator: coordinator)
        try await complete(coordinator, provider, channel: .manual)
        let count = await provider.calls.count
        let operation = coordinator.submit(try .manual(target: "bank", context: sentence), to: .manual)
        let call = await provider.waitForCall("bank", occurrence: count + 1)
        coordinator.cancel(.manual)
        coordinator.closeManual() // Existing UI restores lastManualResult.
        #expect(progress.manual == .cancelled)
        await provider.succeed(call)
        _ = await operation.value
        #expect(progress.manual == .cancelled && !progress.isComplete)
    }

    @Test func wordOnlyAndAbsentMeaningsNeverEnableReadingConfirmation() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let progress = FirstLookupProgress(coordinator: coordinator)
        try await complete(coordinator, provider, channel: .manual, context: false)
        #expect(progress.manual == .needsContext)
        try await complete(coordinator, provider, channel: .selection)
        #expect(!progress.confirmReading())
        try await complete(coordinator, provider, channel: .manual)
        try await complete(coordinator, provider, channel: .selection, context: false)
        #expect(progress.reading == .needsContext && !progress.confirmReading())
        try await complete(coordinator, provider, channel: .selection, meaning: "null")
        #expect(progress.reading == .noMeaning && !progress.confirmReading())
        try await complete(coordinator, provider, channel: .selection, meaning: " BANK ")
        #expect(progress.reading == .noMeaning && !progress.confirmReading())
    }

    @Test func newAttemptCancellationAndConfigurationInvalidateOldConfirmation() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let progress = FirstLookupProgress(coordinator: coordinator)
        try await complete(coordinator, provider, channel: .manual)
        try await complete(coordinator, provider, channel: .selection)
        #expect(progress.confirmReading())
        let request = try LookupRequest.manual(target: "bank", context: sentence)
        let callCount = await provider.calls.count
        let operation = coordinator.submit(request, to: .selection)
        let pending = await provider.waitForCall("bank", occurrence: callCount + 1)
        #expect(!progress.isComplete && progress.reading == .querying)
        coordinator.cancel(.selection)
        #expect(progress.reading == .cancelled && !progress.confirmReading())
        coordinator.configurePrimaryProvider(provider, label: "DeepSeek", isCloud: true)
        await provider.succeed(pending)
        _ = await operation.value
        #expect(progress.manual == .notStarted && progress.reading == .notStarted)
        #expect(!progress.isComplete)
    }
}
