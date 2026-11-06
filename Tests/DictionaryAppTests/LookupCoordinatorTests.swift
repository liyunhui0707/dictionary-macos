import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LookupCoordinatorTests {
    @Test(arguments: [false,true])
    func latestCaptureOwnsItsRangeAndUnavailableSentence(lateFailure: Bool) async throws {
        let provider=ControlledProvider()
        let active=LookupCoordinator(provider:provider)
        let old=active.submit(try .captured(target:"bank",context:"We sat on the bank of the river.",
            sentence:"We sat on the bank of the river.",source:"Chromium",capture:captureMetadata(start:14,end:18,sentenceStart:0,sentenceEnd:32)),to:.selection)
        let oldCall=await provider.waitForCall("bank")
        let new=active.submit(try .captured(target:"bank",context:"The bank closed.\nWe sat on the bank of the river.",
            sentence:nil,source:"Chromium",capture:captureMetadata(start:31,end:35,reason:.sentenceUnavailable)),to:.selection)
        let newCall=await provider.waitForCall("bank",occurrence:2)
        #expect(oldCall.id != newCall.id && oldCall.context != newCall.context)
        #expect(await old.value.isCancelled)
        await provider.succeed(newCall,example:"Unsolicited model sentence")
        #expect(await new.value.result?.request.capture?.range == UTF16Span(start:31,end:35))
        if lateFailure { await provider.fail(oldCall) } else { await provider.succeed(oldCall,example:"Old sentence") }
        await old.providerTask?.value
        let result=try #require(active.selection.result)
        #expect(result.request.capture?.range == UTF16Span(start:31,end:35))
        #expect(result.request.capture?.reason == .sentenceUnavailable)
        let presentation=LookupResultPresentation(request:result.request,translation:result.translation)
        #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil)
    }

    @Test(arguments: [false, true])
    func sameTargetSupersessionRejectsOldContextAndOutcome(lateFailure: Bool) async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let old = coordinator.submit(try .manual(target: "bank", context: "The bank closed."), to: .manual)
        let oldCall = await provider.waitForCall("bank")
        let new = coordinator.submit(try .manual(target: "bank", context: "We sat on the bank."), to: .manual)
        let newCall = await provider.waitForCall("bank", occurrence: 2)
        #expect(oldCall.id != newCall.id)
        #expect(await old.value.isCancelled)
        await provider.succeed(newCall, meaning: "河岸")
        #expect(await new.value.result?.translation.meaningInContext == "河岸")
        if lateFailure { await provider.fail(oldCall) } else { await provider.succeed(oldCall, meaning: "银行") }
        await old.providerTask?.value
        #expect(await old.value.isCancelled)
        #expect(coordinator.manual.result?.request.context == "We sat on the bank.")
        #expect(coordinator.manual.result?.translation.meaningInContext == "河岸")
    }

    @Test(arguments: [false, true])
    func sameTargetChannelsRemainIndependent(cancelSelection: Bool) async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let manual = coordinator.submit(try .manual(target: "bank", context: "The bank closed."), to: .manual)
        let manualCall = await provider.waitForCall("bank")
        let selection = coordinator.submit(try .manual(target: "bank", context: "We sat on the bank."), to: .selection)
        let selectionCall = await provider.waitForCall("bank", occurrence: 2)
        #expect(manualCall.id != selectionCall.id)
        #expect(try providerDocument(manualCall.context)["context_text"] as? String == "The bank closed.")
        #expect(try providerDocument(manualCall.context)["selection"] is NSNull)
        #expect(try providerDocument(selectionCall.context)["context_text"] as? String == "We sat on the bank.")
        #expect(try providerDocument(selectionCall.context)["selection"] is NSNull)
        if cancelSelection {
            coordinator.cancel(.selection)
            #expect(await selection.value.isCancelled)
        } else {
            await provider.succeed(selectionCall, meaning: "河岸")
            #expect(await selection.value.result?.translation.meaningInContext == "河岸")
        }
        #expect(coordinator.manual.isLoading)
        await provider.succeed(manualCall, meaning: "银行")
        #expect(await manual.value.result?.translation.meaningInContext == "银行")
        if cancelSelection {
            await provider.succeed(selectionCall, meaning: "河岸")
            await selection.providerTask?.value
            #expect(coordinator.selection.isCancelled)
        } else {
            #expect(coordinator.selection.result?.translation.meaningInContext == "河岸")
        }
        #expect(coordinator.manual.result?.request.context == "The bank closed.")
    }

    @Test(arguments: [false, true])
    func latestWinsEvenWhenOldProviderIgnoresCancellation(lateFailure: Bool) async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let a = coordinator.submit(try .manual(target: "A", context: ""), to: .selection)
        await provider.waitForCall("A")
        let b = coordinator.submit(try .manual(target: "B", context: ""), to: .selection)
        await provider.waitForCall("B")
        #expect(await a.value.isCancelled)
        await provider.succeed("B", meaning: "新的")
        #expect(await b.value.result?.translation.meaningInContext == "新的")
        if lateFailure { await provider.fail("A") } else { await provider.succeed("A") }
        await a.providerTask?.value
        #expect(coordinator.selection.result?.request.target == "B")
        #expect(await a.value.isCancelled)
    }

    @Test func cancelResolvesAllWaitersBeforeProviderFinishes() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let operation = coordinator.submit(try .manual(target: "A", context: ""), to: .manual)
        await provider.waitForCall("A")
        coordinator.cancel(.manual)
        #expect(!coordinator.manual.isLoading)
        #expect(await operation.value.isCancelled)
        #expect(await operation.value.isCancelled)
        coordinator.cancel(.manual)
        await provider.fail("A")
        await operation.providerTask?.value
        #expect(coordinator.manual.isCancelled)
    }

    @Test func channelsAreIndependentAndForwardArguments() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let manual = coordinator.submit(try .manual(target: "bank", context: "We sat on the bank."), to: .manual)
        let selection = coordinator.submit(try .manual(target: "river", context: ""), to: .selection)
        await provider.waitForCall("bank")
        await provider.waitForCall("river")
        coordinator.cancel(.selection)
        #expect(coordinator.manual.isLoading)
        #expect(await selection.value.isCancelled)
        await provider.succeed("bank")
        #expect(await manual.value.result?.request.target == "bank")
        let calls = await provider.calls
        let call = try #require(calls.first { $0.target == "bank" })
        #expect(try providerDocument(call.context)["context_text"] as? String == "We sat on the bank.")
        #expect(try providerDocument(call.context)["selection"] is NSNull)
        #expect(call.sentence == "We sat on the bank.")
        #expect(call.language == "简体中文")
        await provider.succeed("river")
        await selection.providerTask?.value
    }

    @Test func completedOperationStaysSuccessfulAfterCancel() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let operation = coordinator.submit(try .manual(target: "A", context: ""), to: .manual)
        await provider.waitForCall("A")
        await provider.succeed("A")
        #expect(await operation.value.result != nil)
        coordinator.cancel(.manual)
        #expect(await operation.value.result != nil)
    }

    @Test func nativeSupersessionDoesNotDismissPresentationWhileCapturing() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let old = coordinator.submit(try .manual(target: "old", context: ""), to: .selection)
        await provider.waitForCall("old")
        let intent = coordinator.beginCapture()
        #expect(await old.value.isCancelled)
        // Keep the existing panel in place (including its pin) until capture completes.
        #expect(!coordinator.selection.isCancelled)
        #expect(coordinator.isCurrentCapture(intent))
        coordinator.dismissSelection()
        await provider.succeed("old")
        await old.providerTask?.value
    }

    @Test func multiplePendingWaitersReceiveOneCancellation() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let operation = coordinator.submit(try .manual(target: "A", context: ""), to: .manual)
        await provider.waitForCall("A")
        var first: Task<LookupOutcome, Never>!
        var second: Task<LookupOutcome, Never>!
        await withCheckedContinuation { started in
            first = Task { started.resume(); return await operation.value }
        }
        await withCheckedContinuation { started in
            second = Task { started.resume(); return await operation.value }
        }
        coordinator.cancel(.manual)
        #expect(await first.value.isCancelled)
        #expect(await second.value.isCancelled)
        await provider.succeed("A")
        await operation.providerTask?.value
        #expect(await operation.value.isCancelled)
    }
}
