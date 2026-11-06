import AppKit
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QADiagnosticsTests {
    @Test func captureSubmissionProviderFailureAndPopupFailureHaveSeparateStagesWithoutPayloads() async throws {
        let secret = "PRIVATE_SELECTION_CONTEXT_TOKEN_MODEL_BODY"
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let diagnostics = QADiagnostics()
        let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
        captures.start(source: secret, isSourceCurrent: { true }) {
            CapturedContext(target: secret, context: secret + " context", containingSentence: secret + " sentence")
        }
        let call = await provider.waitForCall(secret)
        await captures.task?.value
        let id = try #require(diagnostics.latestAttempt)
        diagnostics.presentation(intent: id, visible: false, expectedVisible: true, frontmostPID: 123)
        await provider.fail(call)
        // Wait on a terminal-phase event, not wall-clock delay.
        while !diagnostics.events.contains(where: { $0.kind == .providerFailed }) { await Task.yield() }
        let kinds = diagnostics.events.map(\.kind)
        #expect(kinds.contains(.captureSucceeded) && kinds.contains(.lookupSubmitted))
        #expect(kinds.contains(.providerFailed) && kinds.contains(.popupNotVisible))
        #expect(!String(decoding: try diagnostics.encodedEvents(), as: UTF8.self).contains(secret))
        coordinator.dismissSelection()
    }

    @Test func rawProviderErrorAndResponseNeverEnterRecorder() async throws {
        let secret = "PRIVATE_PROVIDER_RESPONSE_TOKEN"
        let provider = DiagnosticFailingProvider(body: secret)
        let coordinator = LookupCoordinator(provider: provider)
        let diagnostics = QADiagnostics()
        let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            CapturedContext(target: "bank", context: "bank", containingSentence: nil)
        }
        await captures.task?.value
        while !diagnostics.events.contains(where: { $0.kind == .providerFailed }) { await Task.yield() }
        #expect(!String(decoding: try diagnostics.encodedEvents(), as: UTF8.self).contains(secret))
    }

    @Test func sameTargetSupersessionHasOneTerminalPerIntentAndDoesNotCancelManual() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let diagnostics = QADiagnostics()
        let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
        let manual = coordinator.submit(try .manual(target: "bank", context: "manual"), to: .manual)
        let manualCall = await provider.waitForCall("bank")
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            CapturedContext(target: "bank", context: "river", containingSentence: nil)
        }
        let oldCall = await provider.waitForCall("bank", occurrence: 2)
        let old = try #require(diagnostics.latestAttempt)
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            CapturedContext(target: "bank", context: "loan", containingSentence: nil)
        }
        let newCall = await provider.waitForCall("bank", occurrence: 3)
        let new = try #require(diagnostics.latestAttempt)
        #expect(oldCall.id != newCall.id && newCall.id != manualCall.id)
        #expect(coordinator.manual.isLoading)
        coordinator.dismissSelection()
        await provider.fail(oldCall)
        await provider.succeed(newCall)
        await provider.succeed(manualCall)
        #expect(await manual.value.result != nil)
        let terminals: Set<QAEventKind> = [.lookupSuperseded, .lookupCancelled, .providerSucceeded, .providerFailed]
        #expect(diagnostics.events.filter { $0.attemptID == old && terminals.contains($0.kind) }.map(\.kind) == [.lookupSuperseded])
        #expect(diagnostics.events.filter { $0.attemptID == new && terminals.contains($0.kind) }.map(\.kind) == [.lookupCancelled])
    }

    @Test func newLogUsesPrivatePermissionsAndOnlyEncodedMetadata() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-log-\(UUID()).jsonl")
        let diagnostics = QADiagnostics(logURL: file, buildID: "fixture-build", runID: "fixture-run")
        diagnostics.record(QAEvent(kind: .captureFailed, details: CaptureDetails(issues: [CaptureIssue(code: .accessibilityNotTrusted)])))
        let data = try Data(contentsOf: file)
        let event = try JSONDecoder().decode(QAEvent.self, from: data)
        #expect(event.kind == .captureFailed && event.buildID == "fixture-build")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!diagnostics.writeFailed)
    }

    @Test func lateCaptureCannotReplaceLatestAttemptOrPublishSuccess() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let diagnostics = QADiagnostics()
        let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
        var continuation: CheckedContinuation<CapturedContext, Never>?
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            await withCheckedContinuation { continuation = $0 }
        }
        while continuation == nil { await Task.yield() }
        let old = try #require(diagnostics.latestAttempt)
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            CapturedContext(target: "bank", context: "bank", containingSentence: nil)
        }
        let new = try #require(diagnostics.latestAttempt)
        continuation?.resume(returning: CapturedContext(target: "stale private", context: "private", containingSentence: nil))
        let call = await provider.waitForCall("bank")
        await captures.task?.value
        #expect(diagnostics.latestAttempt == new && old != new)
        #expect(diagnostics.events.contains { $0.attemptID == old && $0.kind == .staleCaptureDiscarded })
        #expect(!diagnostics.events.contains { $0.attemptID == old && $0.kind == .captureSucceeded })
        coordinator.dismissSelection()
        await provider.succeed(call)
    }

    @Test func sourceChangeAndSubmissionRejectionAreNotProviderFailures() async {
        for sourceCurrent in [false, true] {
            let coordinator = LookupCoordinator(provider: ControlledProvider())
            let diagnostics = QADiagnostics()
            let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
            captures.start(source: "TextEdit", isSourceCurrent: { sourceCurrent }) {
                CapturedContext(target: " ", context: "", containingSentence: nil)
            }
            await captures.task?.value
            #expect(diagnostics.events.contains { $0.kind == (sourceCurrent ? .submissionRejected : .sourceChanged) })
            #expect(!diagnostics.events.contains { $0.kind == .providerFailed })
        }
    }

    @Test func failedLogCreationDoesNotBlockLookupAndExistingFileIsPreserved() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-existing-log-\(UUID()).jsonl")
        try Data("keep".utf8).write(to: file, options: .withoutOverwriting)
        let diagnostics = QADiagnostics(logURL: file)
        #expect(diagnostics.writeFailed)
        let coordinator = LookupCoordinator(provider: DiagnosticFailingProvider(body: "private"))
        let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            CapturedContext(target: "bank", context: "bank", containingSentence: nil)
        }
        await captures.task?.value
        #expect(diagnostics.events.contains { $0.kind == .lookupSubmitted })
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    }

    @Test func actualPopupReportsPresentationAndDismissalForSameIntent() async throws {
        _ = NSApplication.shared
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let diagnostics = QADiagnostics()
        let captures = SelectionCaptureController(coordinator: coordinator, diagnostics: diagnostics)
        let popup = PopupController(coordinator: coordinator, diagnostics: diagnostics)
        defer { popup.close() }
        captures.start(source: "TextEdit", isSourceCurrent: { true }) {
            CapturedContext(target: "bank", context: "bank", containingSentence: nil)
        }
        let call = await provider.waitForCall("bank")
        let id = try #require(diagnostics.latestAttempt)
        #expect(diagnostics.events.contains { $0.attemptID == id && $0.kind == .popupPresented })
        popup.close()
        #expect(diagnostics.events.contains { $0.attemptID == id && $0.kind == .popupDismissed })
        await provider.succeed(call)
    }
}

private struct DiagnosticFailingProvider: TranslationProvider {
    let body: String
    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> DictionaryApp.Translation {
        throw TranslationError.apiError(status: 500, body: body)
    }
}
