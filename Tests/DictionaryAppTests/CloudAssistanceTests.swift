import Foundation
import SwiftUI
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloudAssistanceTests {
    @Test func echoedAnswerRemainsInspectableAndSourceSwitchDoesNotRewriteIt() async throws {
        let local = ControlledProvider(), provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: provider)
        let request = try LookupRequest.captured(target: "zyxqvexample", context: nil, sentence: nil, source: "Synthetic",
            capture: SelectionLocation(reliability: .targetOnly, method: .clipboard))
        let operation = coordinator.submit(request, to: .selection)
        let call = await local.waitForCall(request.target)
        await local.succeed(call, meaning: request.target, example: "REJECTED")
        _ = await operation.value
        let state = PopupState()
        state.phase = coordinator.selection; state.contentHeight = 900
        let cloud = coordinator.selectionCloud
        let popup = TranslationPopupView(state: state, onClose: {}, cloud: cloud)
        #expect(popup.toolbarTitle == "zyxqvexample · 原始 AI：暂无进一步释义")
        let offer = try #require(cloud.offer)
        let task = try #require(cloud.ask(offerID: offer.id))
        let cloudCall = await provider.waitForCall(request.target)
        await provider.succeed(cloudCall, meaning: "一个合成标记", example: "REJECTED TOO")
        await task.value
        #expect(popup.toolbarTitle == "zyxqvexample · DeepSeek AI：一个合成标记")
        cloud.selectSource(.original)
        #expect(popup.toolbarTitle == "zyxqvexample · 原始 AI：暂无进一步释义")
        #expect(coordinator.selection.result?.translation.meaningInContext == request.target)
        for translation in [try #require(coordinator.selection.result?.translation), try #require(cloud.phase.result?.translation)] {
            let presentation = LookupResultPresentation(request: request, translation: translation)
            #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil)
        }
        #expect(await provider.calls.count == 1)
    }

    @Test func answerSwitchUpdatesBodyAndToolbarWithoutReplacingOriginal() async throws {
        let local = ControlledProvider(), provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: provider)
        let request = try LookupRequest.manual(target: "bank", context: "We sat on the bank.")
        let op = coordinator.submit(request, to: .selection)
        await local.waitForCall("bank")
        await local.succeed("bank", meaning: "银行")
        _ = await op.value
        let cloud = coordinator.selectionCloud
        let state = PopupState()
        state.phase = coordinator.selection
        state.contentHeight = 900
        let popup = TranslationPopupView(state: state, onClose: {}, cloud: cloud)
        let result = LookupResultView(phase: state.phase, layout: .popup, cloud: cloud)
        #expect(result.displayedPhase.result?.translation.meaningInContext == "银行")
        let offer = try #require(cloud.offer)
        let task = try #require(cloud.ask(offerID: offer.id))
        let call = await provider.waitForCall("bank")
        await provider.succeed(call, meaning: "河岸")
        await task.value
        #expect(result.displayedPhase.result?.translation.meaningInContext == "河岸")
        #expect(result.meaningLabel == "AI 释义建议 · DeepSeek")
        #expect(popup.toolbarTitle == "bank · DeepSeek AI：河岸")
        cloud.selectSource(.original)
        #expect(result.displayedPhase.result?.translation.meaningInContext == "银行")
        #expect(popup.toolbarTitle == "bank · 原始 AI：银行")
        cloud.selectSource(.cloud)
        #expect(popup.toolbarTitle == "bank · DeepSeek AI：河岸")
        #expect(coordinator.selection.result?.translation.meaningInContext == "银行")
        #expect(await provider.calls.count == 1)
        cloud.prepare(nil)
        state.phase = .loading(request)
        #expect(popup.toolbarTitle == "Dictionary")
        #expect(cloud.selectedSource == .original)
    }

    @Test func choosingOriginalWhileCloudLoadsIsRespected() async throws {
        let provider = ControlledProvider()
        let cloud = CloudAssistanceState(provider: provider)
        cloud.prepare(try .manual(target: "bank", context: ""))
        let offer = try #require(cloud.offer)
        let task = try #require(cloud.ask(offerID: offer.id))
        let call = await provider.waitForCall("bank")
        cloud.selectSource(.original)
        await provider.succeed(call, meaning: "河岸")
        await task.value
        #expect(cloud.selectedSource == .original)
        #expect(cloud.phase.result != nil)
    }

    @Test func cloudFailureKeepsOriginalVisibleAndResetRejectsUnavailableSource() async throws {
        let provider = ControlledProvider()
        let cloud = CloudAssistanceState(provider: provider)
        let request = try LookupRequest.manual(target: "bank", context: "")
        cloud.prepare(request)
        cloud.selectSource(.cloud)
        #expect(cloud.selectedSource == .original)
        let original = LookupPhase.finished(request, .success(LookupResult(request: request,
            translation: Translation(meaningInContext: "银行", literalGloss: nil, partOfSpeech: nil, exampleTranslation: nil, alternatives: nil))))
        let offer = try #require(cloud.offer)
        let task = try #require(cloud.ask(offerID: offer.id))
        let call = await provider.waitForCall("bank")
        await provider.fail(call)
        await task.value
        #expect(cloud.selectedSource == .original)
        #expect(cloud.displayedPhase(for: original).result?.translation.meaningInContext == "银行")
        cloud.selectSource(.cloud)
        #expect(cloud.selectedSource == .original)
    }

    @Test func fixedCloudControlsLeaveABoundedScrollableResult() {
        let size = PopupContentSize(available: CGSize(width: 420, height: 560), measuredHeight: 1500, controlsHeight: 92)
        #expect(size.contentHeight + 85 + 92 + 12 <= 560)
        #expect(size.contentHeight > 200)
    }

    @Test func explicitClickPreservesOriginalAndRejectsDuplicate() async throws {
        let local = ControlledProvider(), cloud = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: cloud)
        let request = try LookupRequest.manual(target: "bank", context: "We sat on the bank.")
        let original = coordinator.submit(request, to: .selection)
        await local.waitForCall("bank")
        #expect(coordinator.selectionCloud.offer == nil)
        #expect(await cloud.calls.isEmpty)
        await local.succeed("bank", meaning: "银行")
        _ = await original.value
        let offer = try #require(coordinator.selectionCloud.offer)
        #expect(await cloud.calls.isEmpty)
        let task = try #require(coordinator.selectionCloud.ask(offerID: offer.id))
        #expect(coordinator.selectionCloud.ask(offerID: offer.id) == nil)
        let call = await cloud.waitForCall("bank")
        #expect(call.context == request.providerContext)
        #expect(call.sentence == request.containingSentence)
        await cloud.succeed(call, meaning: "河岸")
        await task.value
        #expect(coordinator.selection.result?.translation.meaningInContext == "银行")
        #expect(coordinator.selectionCloud.phase.result?.translation.meaningInContext == "河岸")
        #expect(await cloud.calls.count == 1)
    }

    @Test func localFailureDoesNotSendAndMissingKeyCannotSend() async throws {
        let local = ControlledProvider(), cloud = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: cloud)
        let op = coordinator.submit(try .manual(target: "bank", context: ""), to: .manual)
        await local.waitForCall("bank")
        await local.fail("bank")
        _ = await op.value
        #expect(coordinator.manualCloud.offer != nil)
        #expect(await cloud.calls.isEmpty)
        let unavailable = CloudAssistanceState(provider: nil)
        unavailable.prepare(op.request)
        let offer = try #require(unavailable.offer)
        #expect(!unavailable.isConfigured)
        #expect(unavailable.ask(offerID: offer.id) == nil)
        #expect(!unavailable.phase.isLoading)
    }

    @Test(arguments: ["cancel", "dismiss", "newRequest", "capture", "shutdown"])
    func obsoleteCloudNeverReplacesOrReopens(action: String) async throws {
        let local = ControlledProvider(), cloud = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: cloud)
        let op = coordinator.submit(try .manual(target: "bank", context: "The bank closed."), to: .selection)
        await local.waitForCall("bank")
        await local.succeed("bank")
        _ = await op.value
        let offer = try #require(coordinator.selectionCloud.offer)
        let task = try #require(coordinator.selectionCloud.ask(offerID: offer.id))
        let call = await cloud.waitForCall("bank")
        switch action {
        case "cancel": coordinator.selectionCloud.cancel()
        case "dismiss": coordinator.dismissSelection()
        case "capture": _ = coordinator.beginCapture()
        case "shutdown": coordinator.shutdown()
        default:
            let new = coordinator.submit(try .manual(target: "bank", context: "A different bank."), to: .selection)
            let newCall = await local.waitForCall("bank", occurrence: 2)
            await local.succeed(newCall, meaning: "new answer")
            _ = await new.value
        }
        await cloud.succeed(call, meaning: "obsolete")
        await task.value
        #expect(coordinator.selectionCloud.phase.result == nil)
        #expect(coordinator.selectionCloud.selectedSource == .original)
        #expect(coordinator.selectionCloud.ask(offerID: offer.id) == nil)
        #expect(coordinator.selection.result?.translation.meaningInContext != "obsolete")
        if action == "dismiss" || action == "shutdown" { if case .idle = coordinator.selection {} else { Issue.record("Reopened") } }
    }

    @Test func channelIsolationAndManualClose() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider, cloudProvider: provider)
        let op = coordinator.submit(try .manual(target: "bank", context: ""), to: .manual)
        await provider.waitForCall("bank")
        await provider.succeed("bank")
        _ = await op.value
        let offer = try #require(coordinator.manualCloud.offer)
        let task = try #require(coordinator.manualCloud.ask(offerID: offer.id))
        let call = await provider.waitForCall("bank", occurrence: 2)
        coordinator.dismissSelection()
        #expect(coordinator.manualCloud.phase.isLoading)
        coordinator.closeManual()
        await provider.succeed(call)
        await task.value
        #expect(coordinator.manualCloud.phase.result == nil)
        #expect(coordinator.manual.result != nil)
    }

    @Test func productionViewsShareTheExplicitActionWithoutSendingOnConstruction() async throws {
        let local = ControlledProvider(), cloud = ControlledProvider()
        let coordinator = LookupCoordinator(provider: local, cloudProvider: cloud)
        let op = coordinator.submit(try .manual(target: "bank", context: ""), to: .manual)
        await local.waitForCall("bank")
        await local.succeed("bank")
        _ = await op.value
        for layout in [LookupResultView.Layout.standard, .popup] {
            let view = LookupResultView(phase: coordinator.manual, layout: layout, cloud: coordinator.manualCloud)
            #expect(cloudStates(in: view.body).first === coordinator.manualCloud)
        }
        _ = CloudAssistanceView(state: coordinator.manualCloud).body
        #expect(await cloud.calls.isEmpty)
    }

    private func cloudStates(in value: Any, depth: Int = 0) -> [CloudAssistanceState] {
        if let view = value as? CloudAssistanceView { return [view.state] }
        guard depth < 30 else { return [] }
        return Mirror(reflecting: value).children.flatMap { cloudStates(in: $0.value, depth: depth + 1) }
    }

    @Test func cloudDoesNotRestoreRejectedSentence() async throws {
        let provider = ControlledProvider()
        let state = CloudAssistanceState(provider: provider)
        let request = try LookupRequest.captured(target: "bank", context: "We sat on the bank of the river.", sentence: nil,
            source: "PRIVATE SOURCE NAME", capture: captureMetadata(start: 14, end: 18, reason: .sentenceUnavailable))
        state.prepare(request)
        let offer = try #require(state.offer)
        let task = try #require(state.ask(offerID: offer.id))
        let call = await provider.waitForCall("bank")
        #expect(!call.context.contains(request.source))
        #expect(call.sentence == nil)
        await provider.succeed(call, meaning: "河岸", example: "Invented sentence")
        await task.value
        let result = try #require(state.phase.result)
        let presentation = LookupResultPresentation(request: result.request, translation: result.translation)
        #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil)
    }
}
