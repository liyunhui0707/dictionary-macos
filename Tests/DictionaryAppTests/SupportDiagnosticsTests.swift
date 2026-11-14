import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SupportDiagnosticsTests {
    private func report(_ support: SupportDiagnostics, version: String = "0.4.0") throws -> String {
        let local = LocalModelSettings(configuration: .init(environment: [:], savedModel: "private-fixture-model:latest"),
            savedModel: nil, probe: NoSupportProbe(), persistModel: { _ in Issue.record("No settings write") })
        let readiness = AppReadiness(buildID: "PRIVATE_BUILD_SENTINEL", appURL: URL(fileURLWithPath: "/Synthetic/PRIVATE_PATH"),
            checkPermission: { Issue.record("No permission probe during report"); return false },
            openPermissionSettings: { Issue.record("No permission change"); return false }, revealApp: { _ in Issue.record("No reveal") })
        return try support.report(version: version, service: .init(saved: "local"), local: local, readiness: readiness).text()
    }

    @Test func reportIsAllowlistedAndCannotExportQueryOutputErrorsOrIdentity() async throws {
        let support = SupportDiagnostics(), provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider, support: support)
        let secret = "PRIVATE_TEXT_AND_CREDENTIAL_SENTINEL"
        let request = try LookupRequest.captured(target: "bank", context: "They walked along the bank of the river.",
            sentence: "They walked along the bank of the river.", source: secret,
            capture: .init(reliability: .heuristic, method: .axTreeWalk))
        let operation = coordinator.submit(request, to: .selection)
        await provider.succeed(await provider.waitForCall("bank"), meaning: secret)
        _ = await operation.value
        let text = try report(support)
        #expect(support.selection.state == .responseReceived)
        for forbidden in [secret, "They walked", "bank", "private-fixture-model", "PRIVATE_BUILD", "PRIVATE_PATH"] {
            #expect(!text.contains(forbidden))
        }
        let json = try #require(text.range(of: "{"))
        let fields = try #require(JSONSerialization.jsonObject(with: Data(text[json.lowerBound...].utf8)) as? [String: Any])
        #expect(Set(fields.keys) == ["schema", "appVersion", "service", "permission", "localModelCheck", "modelRestartRequired", "listener", "authenticatedCheckSeen", "extensionLookupSeen", "nativeHotkeyRegistration", "manual", "reading"])
        #expect(!text.contains("source") && !text.contains("timestamp"))
        let invalid = try report(support, version: "0.4.0\nPRIVATE_VERSION_SENTINEL")
        #expect(invalid.contains("unknown") && !invalid.contains("PRIVATE_VERSION"))
        #expect(try report(support, version: "0.4.0\n").contains("unknown"))
    }

    @Test func typedFailuresIgnoreRawDescriptionsAndSeparateRecoveryCategories() {
        let secret = "PRIVATE_ERROR_SENTINEL"
        let cases: [(Error, SupportIssue)] = [
            (LookupServiceSetupError(cloudDisabled: false), .setupRequired),
            (TranslationError.apiError(status: -1, body: secret), .connectionFailed),
            (TranslationError.apiError(status: 404, body: secret), .modelOrEndpointUnavailable),
            (TranslationError.unparseableJSON(rawOutput: secret), .invalidResponse),
            (CloudAssistanceError.credentialUnavailable, .credentialsUnavailable),
            (CloudAssistanceError.http(401), .authenticationRejected),
            (CloudAssistanceError.http(403), .serviceRejected),
            (CloudAssistanceError.http(429), .accountOrRateLimit),
            (URLError(.timedOut), .timedOut),
            (NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]), .unknown),
            (CaptureFailure(details: .init(issues: [.init(code: .accessibilityNotTrusted)])), .permissionRequired),
            (CaptureFailure(details: .init(reason: .sourceChanged)), .sourceChanged)
        ]
        for (error, expected) in cases {
            let issue = SupportIssue.classify(error)
            #expect(issue == expected && !issue.guidance.contains(secret))
        }
    }

    @Test func realCoordinatorFailureExportsOnlyItsCategory() async throws {
        let support = SupportDiagnostics()
        let coordinator = LookupCoordinator(provider: SupportFailingProvider(), support: support)
        let operation = coordinator.submit(try .manual(target: "bank", context: ""), to: .manual)
        _ = await operation.value
        #expect(support.manual.state == .failed && support.manual.issue == .authenticationRejected)
        #expect(!((try report(support)).contains("PRIVATE_PROVIDER_BODY")))
    }

    @Test func cancellationReplayLateResultsAndServiceChangesDoNotLeaveFalseSuccess() async throws {
        let support = SupportDiagnostics(), provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider, support: support)
        let request = try LookupRequest.manual(target: "bank", context: "They walked along the bank of the river.")
        let first = coordinator.submit(request, to: .manual)
        await provider.succeed(await provider.waitForCall("bank"), meaning: "河岸")
        _ = await first.value
        let second = coordinator.submit(request, to: .manual)
        let call = await provider.waitForCall("bank", occurrence: 2)
        coordinator.cancel(.manual); coordinator.closeManual()
        #expect(support.manual.state == .cancelled)
        await provider.succeed(call)
        _ = await second.value
        #expect(support.manual.state == .cancelled)
        let intent = coordinator.beginCapture()
        #expect(support.selection.state == .capturing)
        coordinator.dismissSelection()
        coordinator.failCapture(intent, message: "PRIVATE_SENTINEL")
        #expect(support.selection.state == .cancelled)
        coordinator.configurePrimaryProvider(provider, label: "PRIVATE_LABEL", isCloud: false)
        #expect(support.manual.state == .notRun && support.selection.state == .notRun)
    }

    @Test func missingContextEchoAndCaptureFailureAreDistinct() async throws {
        let support = SupportDiagnostics(), provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider, support: support)
        let request = try LookupRequest.manual(target: "bank", context: "")
        let first = coordinator.submit(request, to: .manual)
        await provider.succeed(await provider.waitForCall("bank"), meaning: "银行")
        _ = await first.value
        #expect(support.manual.state == .missingContext)
        let second = coordinator.submit(request, to: .manual)
        await provider.succeed(await provider.waitForCall("bank", occurrence: 2), meaning: " BANK ")
        _ = await second.value
        #expect(support.manual.state == .noMeaning)
        coordinator.failCapture(coordinator.beginCapture(), message: "PRIVATE_ERROR", issue: .permissionRequired)
        #expect(support.selection.issue == .permissionRequired)
        #expect(!((try report(support)).contains("PRIVATE_ERROR")))
    }

    @Test func authenticatedChecksAreHistoricalNotProofOfCurrentConnectionOrModelQuality() async throws {
        let support = SupportDiagnostics(), provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider, support: support)
        let tokens = TokenStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Support-\(UUID())"))
        let handler = TranslateHandler(tokenStore: tokens, coordinator: coordinator, support: support)
        let token = tokens.token
        support.listenerChanged(.listening)
        let bad = HTTPRequest(method: "GET", path: "/v1/status", headers: ["authorization": "Bearer wrong"], body: Data())
        #expect(await handler.handle(bad).status == 401)
        #expect(!support.authenticatedCheckSeen)
        let status = HTTPRequest(method: "GET", path: "/v1/status", headers: ["authorization": "Bearer \(token)"], body: Data())
        #expect(await handler.handle(status).status == 200)
        #expect(support.authenticatedCheckSeen && support.manual.state == .notRun && support.selection.state == .notRun)
        let invalid = HTTPRequest(method: "POST", path: "/v1/translate", headers: status.headers, body: Data("{".utf8))
        #expect(await handler.handle(invalid).status == 400 && !support.extensionLookupSeen)
        #expect(await provider.calls.isEmpty)
        #expect(!((try report(support)).contains(token)))
        let valid = HTTPRequest(method: "POST", path: "/v1/translate", headers: status.headers,
            body: Data(#"{"target":"bank"}"#.utf8))
        let response = Task { await handler.handle(valid) }
        let call = await provider.waitForCall("bank")
        #expect(support.extensionLookupSeen && support.selection.state == .querying)
        coordinator.dismissSelection()
        #expect(await response.value.status == 204)
        await provider.succeed(call)
        #expect(support.selection.state == .cancelled)
        support.listenerChanged(.unavailable)
        #expect(!support.authenticatedCheckSeen && !support.extensionLookupSeen)
        support.hotkeyRegistered(false)
        #expect(support.nativeHotkeyRegistration == .failed)
        support.hotkeyRegistered(true)
        #expect(support.nativeHotkeyRegistration == .registered)
    }
}

private struct SupportFailingProvider: TranslationProvider {
    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> Translation {
        throw TranslationError.apiError(status: 401, body: "PRIVATE_PROVIDER_BODY")
    }
}

private actor NoSupportProbe: OllamaModelListing {
    func models() -> [String] { Issue.record("Report must not probe a service"); return [] }
}
