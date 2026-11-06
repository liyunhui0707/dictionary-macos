import Testing
@testable import DictionaryApp

struct LookupWaitingTests {
    @Test func elapsedTimeAndDelayedNoticeUseTheRequestStart() {
        let start = ContinuousClock.now
        let initial = LookupWaitingPresentation(startedAt: start, now: start)
        #expect(initial.elapsed == "0 秒")
        #expect(initial.title == "正在查词…")
        #expect(initial.notice == nil)
        let early = LookupWaitingPresentation(startedAt: start, now: start.advanced(by: .milliseconds(4999)))
        #expect(early.elapsed == "4 秒" && early.notice == nil)
        let delayed = LookupWaitingPresentation(startedAt: start, now: start.advanced(by: .seconds(5)))
        #expect(delayed.elapsed == "5 秒")
        #expect(delayed.title == "仍在处理中…")
        #expect(delayed.notice == "正在等待翻译服务，你可以随时取消。")
    }

    @Test func elapsedTimeNeverGoesNegativeOrPretendsToBeAnEstimate() {
        let start = ContinuousClock.now
        #expect(LookupWaitingPresentation(startedAt: start, now: start.advanced(by: .seconds(-2))).elapsed == "0 秒")
        let long = LookupWaitingPresentation(startedAt: start, now: start.advanced(by: .seconds(125)))
        #expect(long.elapsed == "125 秒")
        #expect(long.title == "仍在处理中…")
    }

    @MainActor @Test func repeatedRequestResetsTimingAndOldResultCannotRestoreWaiting() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let request = try LookupRequest.manual(target: "bank", context: "")
        let old = coordinator.submit(request, to: .selection)
        let first = await provider.waitForCall("bank")
        guard case .loading(_, let oldStart) = coordinator.selection else { Issue.record("Expected loading"); return }
        let beforeNewRequest = ContinuousClock.now
        let current = coordinator.submit(request, to: .selection)
        let second = await provider.waitForCall("bank", occurrence: 2)
        guard case .loading(_, let newStart) = coordinator.selection else { Issue.record("Expected loading"); return }
        #expect(newStart >= beforeNewRequest && newStart > oldStart)
        #expect(LookupWaitingPresentation(startedAt: newStart, now: newStart).elapsed == "0 秒")
        await provider.succeed(first)
        await old.providerTask?.value
        #expect(coordinator.selection.isLoading)
        coordinator.dismissSelection()
        #expect(await current.value.isCancelled)
        await provider.succeed(second)
        await current.providerTask?.value
        guard case .idle = coordinator.selection else { Issue.record("Cancelled lookup must stay dismissed"); return }
    }

    @MainActor @Test func successAndFailureLeaveLoading() async throws {
        for failure in [false, true] {
            let provider = ControlledProvider()
            let coordinator = LookupCoordinator(provider: provider)
            let operation = coordinator.submit(try .manual(target: "bank", context: ""), to: .manual)
            let call = await provider.waitForCall("bank")
            #expect(coordinator.manual.isLoading)
            if failure { await provider.fail(call) } else { await provider.succeed(call) }
            _ = await operation.value
            #expect(!coordinator.manual.isLoading)
        }
    }
}
