import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct ScreenContextPolicyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_NATIVE_QUALITY_CHECKS"] == "1"))
    func systemSpellingFlagsTheObservedOCRFragmentForReview() {
        #expect(ScreenContextSafety.hasSpellingIssue("Later, the company repaired the bridge after ne storm."))
    }

    @Test func oldPermissionDoesNotAuthorizeAutomaticLocalOrCloudQueries() {
        let settings = BooksScreenSettings(enabled: true)
        #expect(!settings.automaticallyUsesContext(isCloud: false))
        #expect(!settings.automaticallyUsesContext(isCloud: true))
        settings.setAutomaticLocal(true)
        #expect(settings.automaticallyUsesContext(isCloud: false))
        #expect(!settings.automaticallyUsesContext(isCloud: true))
        settings.setAutomaticCloud(true)
        #expect(settings.automaticallyUsesContext(isCloud: true))
        settings.setEnabled(false)
        #expect(!settings.automaticallyUsesContext(isCloud: true))
    }

    @Test func confidenceAloneCannotAuthorizeTextWithPossibleOCRTypos() {
        let line = ScreenTextLine(text: "The company repaired the bridge after ne storm.",
            bounds: CGRect(x: 0, y: 0, width: 600, height: 25), confidence: 0.99, words: [])
        #expect(!ScreenContextSafety.eligible(sentence: line.text, lines: [line], hasSpellingIssue: { _ in true }))
        #expect(ScreenContextSafety.eligible(sentence: line.text, lines: [line], hasSpellingIssue: { _ in false }))
        let low = ScreenTextLine(text: line.text, bounds: line.bounds, confidence: 0.9, words: [])
        #expect(!ScreenContextSafety.eligible(sentence: low.text, lines: [low], hasSpellingIssue: { _ in false }))
        #expect(!ScreenContextSafety.eligible(sentence: line.text, lines: [], hasSpellingIssue: { _ in false }))
    }

    private func request(eligible: Bool) -> LookupRequest {
        LookupRequest(target: "company", context: "The company repaired the bridge after ne storm.",
            containingSentence: "The company repaired the bridge after ne storm.", source: "Synthetic Books",
            capture: .init(reliability: .heuristic, method: .screenOCR), screenContextCanAutoUse: eligible)
    }

    @Test(arguments: [false, true])
    func automaticUseRequiresBothConsentAndCaptureEvidence(consent: Bool) async throws {
        for eligible in [false, true] {
            let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
            let id = coordinator.beginCapture()
            coordinator.finishCapture(id, request: request(eligible: eligible), allowAutomaticScreenContext: consent)
            if consent && eligible {
                guard case .loading(let submitted, _) = coordinator.selection else { Issue.record("Expected automatic query"); return }
                #expect(submitted.capture?.reliability == .heuristic)
                let call = await provider.waitForCall("company")
                await provider.succeed(call)
            } else {
                guard case .reviewingContext = coordinator.selection else { Issue.record("Review required"); return }
                #expect(await provider.calls.isEmpty)
            }
        }
    }

    @Test func editedPreviewValidatesTargetAndCannotSubmitTwiceOrAfterDismissal() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let id = coordinator.beginCapture(); coordinator.finishCapture(id, request: request(eligible: false))
        #expect(!coordinator.confirmScreenContext(id, editedContext: "The bank closed."))
        #expect(!coordinator.confirmScreenContext(id, editedContext: "The company joined another company."))
        #expect(await provider.calls.isEmpty)
        let corrected = "The company repaired the bridge after the storm."
        #expect(coordinator.confirmScreenContext(id, editedContext: corrected))
        let call = await provider.waitForCall("company")
        #expect(call.context.contains(corrected))
        #expect(!coordinator.confirmScreenContext(id, editedContext: corrected))
        await provider.succeed(call)
        let next = coordinator.beginCapture(); coordinator.finishCapture(next, request: request(eligible: false))
        coordinator.dismissSelection()
        #expect(!coordinator.confirmScreenContext(next, editedContext: corrected))
    }

    @Test func wordOnlyChoiceNeverSendsOCRContext() async throws {
        let provider = ControlledProvider(), coordinator = LookupCoordinator(provider: provider)
        let id = coordinator.beginCapture(); coordinator.finishCapture(id, request: request(eligible: false))
        #expect(coordinator.confirmScreenContext(id, editedContext: nil, useContext: false))
        let call = await provider.waitForCall("company")
        #expect(!call.context.contains("storm"))
        await provider.succeed(call)
        #expect(coordinator.selection.result?.request.context == nil)
    }
}
