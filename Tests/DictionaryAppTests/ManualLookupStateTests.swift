import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualLookupStateTests {
    @Test func draftEditsAndEmptySubmissionDoNotChangeActiveSnapshot() async {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let state = ManualLookupState(coordinator: coordinator)
        state.target = "bank"
        state.context = "We sat on the bank."
        let operation = state.submit()
        await provider.waitForCall("bank")
        state.target = "  "
        state.context = "edited"
        #expect(state.submit() == nil)
        #expect(coordinator.manual.isLoading)
        state.target = "river"
        await provider.succeed("bank")
        #expect(await operation?.value.result?.request.target == "bank")
        #expect(coordinator.manual.result?.request.context == "We sat on the bank.")
        #expect(state.target == "river")
    }

    @Test func closePreservesDraftAndLastCompletedResult() async {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let state = ManualLookupState(coordinator: coordinator)
        state.target = "done"
        let done = state.submit()
        await provider.waitForCall("done")
        await provider.succeed("done")
        _ = await done?.value
        state.target = "pending"
        let pending = state.submit()
        await provider.waitForCall("pending")
        state.close()
        #expect(await pending?.value.isCancelled == true)
        #expect(state.target == "pending")
        #expect(coordinator.manual.result?.request.target == "done")
        await provider.succeed("pending")
        await pending?.providerTask?.value
        #expect(coordinator.manual.result?.request.target == "done")
    }

    @Test func failurePreservesDraftAndAllowsRetry() async {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let state = ManualLookupState(coordinator: coordinator)
        state.target = "first"
        let first = state.submit()
        await provider.waitForCall("first")
        await provider.fail("first")
        _ = await first?.value
        #expect(state.target == "first")
        #expect(!coordinator.manual.isLoading)
        state.target = "retry"
        let retry = state.submit()
        await provider.waitForCall("retry")
        await provider.succeed("retry")
        #expect(await retry?.value.result?.request.target == "retry")
    }
}
