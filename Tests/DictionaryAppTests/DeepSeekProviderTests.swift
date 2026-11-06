import Foundation
import Testing
@testable import DictionaryApp

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DeepSeekProviderTests {
    @Test func savedCredentialIsReadOnlyForExplicitRequestAndUsesExistingTransport() async throws {
        let store = ProviderCredentialFixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudProtocol.self]
        CloudProtocol.reset(status: 200, body: Self.answer())
        let provider = KeychainDeepSeekProvider(store: store, configuration: config)
        #expect(await store.reads == 0)
        let result = try await provider.translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "中文")
        #expect(result.meaningInContext == "河岸")
        #expect(await store.reads == 1)
        #expect(CloudProtocol.requests.count == 1)
        #expect(CloudProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-saved-key")
    }

    @Test func cancelledWhileReadingKeyNeverSendsHTTP() async throws {
        let store = ProviderCredentialFixture(pauseRead: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudProtocol.self]
        CloudProtocol.reset(status: 200, body: Self.answer())
        let provider = KeychainDeepSeekProvider(store: store, configuration: config)
        let task = Task { try await provider.translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "中文") }
        await store.waitForRead()
        task.cancel()
        await store.finishRead()
        do { _ = try await task.value; Issue.record("Cancellation expected") }
        catch { #expect(error is CancellationError) }
        #expect(CloudProtocol.requests.isEmpty)
    }

    private func provider() -> DeepSeekProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudProtocol.self]
        return DeepSeekProvider(apiKey: "synthetic-key-not-real", configuration: config)
    }

    @Test func configurationRequiresDedicatedExplicitKey() {
        #expect(DeepSeekProvider.configured(environment: [:]) == nil)
        #expect(DeepSeekProvider.configured(environment: ["ANTHROPIC_API_KEY": "synthetic"]) == nil)
        #expect(DeepSeekProvider.configured(environment: ["DICTIONARY_CLOUD_API_KEY": " \n"]) == nil)
        #expect(DeepSeekProvider.configured(environment: ["DICTIONARY_CLOUD_API_KEY": "synthetic"]) != nil)
    }

    @Test(arguments: ["synthetic\r\nInjected: value", "synthetic key", "合成密钥"])
    func malformedCredentialCannotBeConfigured(key: String) {
        #expect(DeepSeekProvider.configured(environment: ["DICTIONARY_CLOUD_API_KEY": key]) == nil)
    }

    @Test func frozenProtocolPreservesVerifiedPositionAndExcludesSource() async throws {
        CloudProtocol.reset(status: 200, body: Self.answer())
        let text = "I called the bank while sitting on the bank of the river."
        let request = try LookupRequest.captured(target: "bank", context: text, sentence: text,
            source: "PRIVATE_DOCUMENT_NAME", capture: captureMetadata(start: 39, end: 43, sentenceStart: 0, sentenceEnd: text.utf16.count))
        let result = try await provider().translate(target: request.target, context: request.providerContext,
            containingSentence: request.containingSentence, targetLanguage: "简体中文")
        #expect(result.meaningInContext == "河岸")
        let sent = try #require(CloudProtocol.requests.first)
        #expect(CloudProtocol.requests.count == 1)
        #expect(sent.url?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key-not-real")
        #expect(sent.timeoutInterval == 30)
        let body = try #require(try JSONSerialization.jsonObject(with: CloudProtocol.body(sent)) as? [String: Any])
        #expect(Set(body.keys) == ["model", "max_tokens", "stream", "thinking", "system", "messages"])
        #expect(body["model"] as? String == "deepseek-flash")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["stream"] as? Bool == false)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        let prompt = PromptBuilder.build(target: request.target, context: request.providerContext,
            containingSentence: request.containingSentence, targetLanguage: "简体中文")
        #expect(body["system"] as? String == prompt.system)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": prompt.userInstruction]])
        #expect(!messages[0]["content"]!.contains(request.source))
        let document = try providerDocument(request.providerContext)
        let selection = try #require(document["selection"] as? [String: Any])
        #expect(selection["start"] as? Int == 39)
    }

    @Test(arguments: [401, 429, 500, 302])
    func httpErrorsAreSafeAndNeverRetried(status: Int) async {
        CloudProtocol.reset(status: status, body: Data("private body synthetic-key-not-real".utf8))
        do {
            _ = try await provider().translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "简体中文")
            Issue.record("Expected failure")
        } catch {
            #expect(error.localizedDescription.contains("HTTP \(status)"))
            #expect(!error.localizedDescription.contains("private body"))
            #expect(!error.localizedDescription.contains("synthetic-key"))
        }
        #expect(CloudProtocol.requests.count == 1)
    }

    @Test(arguments: ["malformed", "truncated", "tool", "extraBlock"])
    func invalidAnswersNeverBecomeSuggestions(kind: String) async {
        var body = Self.answer(stop: kind == "truncated" ? "max_tokens" : "end_turn",
                               type: kind == "tool" ? "tool_use" : "text", extra: kind == "extraBlock")
        if kind == "malformed" { body = Data("sensitive invalid reply".utf8) }
        CloudProtocol.reset(status: 200, body: body)
        do {
            _ = try await provider().translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "简体中文")
            Issue.record("Expected failure")
        } catch { #expect(error.localizedDescription == CloudAssistanceError.invalidResponse.localizedDescription) }
        #expect(CloudProtocol.requests.count == 1)
    }

    @Test(arguments: [#"{"meaning_in_context":null}"#, #"{"meaning_in_context":" "}"#])
    func absentMeaningIsAnAbstentionNotAProtocolError(_ text: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn",
            "content": [["type": "text", "text": text]]])
        CloudProtocol.reset(status: 200, body: body)
        do {
            _ = try await provider().translate(target: "vqxtralen", context: "synthetic", containingSentence: nil, targetLanguage: "简体中文")
            Issue.record("No cloud suggestion expected")
        } catch {
            #expect(error.localizedDescription == CloudAssistanceError.noMeaning.localizedDescription)
        }
        #expect(CloudProtocol.requests.count == 1)
    }

    @Test(arguments: [URLError.Code.timedOut, .notConnectedToInternet])
    func transportFailureIsSanitizedAndNotRetried(code: URLError.Code) async {
        CloudProtocol.reset(status: 200, body: Data(), error: code)
        do {
            _ = try await provider().translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "简体中文")
            Issue.record("Expected transport failure")
        } catch {
            let expected: CloudAssistanceError = code == .timedOut ? .timeout : .network
            #expect(error.localizedDescription == expected.localizedDescription)
        }
        #expect(CloudProtocol.requests.count == 1)
    }

    @Test func cancellationPropagatesToTransport() async throws {
        CloudProtocol.reset(status: 200, body: Self.answer(), hold: true)
        let p = provider()
        let task = Task { try await p.translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "简体中文") }
        defer { task.cancel() }
        // URLSession starts on another queue; a yield count is not a time bound.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while CloudProtocol.requests.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(CloudProtocol.requests.count == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation expected") }
        catch { #expect(error is CancellationError) }
    }

    @Test func redirectDelegateRefusesNewDestination() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!) // Never resumed.
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let redirected: URLRequest? = await withCheckedContinuation { continuation in
            CloudRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { continuation.resume(returning: $0) }
        }
        #expect(redirected == nil)
    }

    private static func answer(meaning: String = "河岸", stop: String = "end_turn", type: String = "text", extra: Bool = false) -> Data {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["meaning_in_context": meaning]), as: UTF8.self)
        let block = ["type": type, "text": text]
        return try! JSONSerialization.data(withJSONObject: ["stop_reason": stop, "content": extra ? [block, block] : [block]])
    }
}

private actor ProviderCredentialFixture: CloudCredentialStore {
    private(set) var reads = 0
    let pauseRead: Bool
    private var reader: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(pauseRead: Bool = false) { self.pauseRead = pauseRead }
    func read() async -> String? {
        reads += 1
        if pauseRead {
            await withCheckedContinuation { reader = $0; observer?.resume(); observer = nil }
        }
        return "synthetic-saved-key"
    }
    func waitForRead() async {
        if reader == nil { await withCheckedContinuation { observer = $0 } }
    }
    func finishRead() { reader?.resume(); reader = nil }
    func save(_ key: String) throws { throw CloudAssistanceError.credentialUnavailable }
    func remove() throws { throw CloudAssistanceError.credentialUnavailable }
}

/// Intercepts every scheme; no network or real credentials are used by this suite.
private final class CloudProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var status = 200
    private static var payload = Data()
    private static var hold = false
    private static var failure: URLError.Code?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int, body: Data, hold: Bool = false, error: URLError.Code? = nil) {
        lock.withLock { recorded = []; self.status = status; payload = body; self.hold = hold; failure = error }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, hold, error) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.status, Self.payload, Self.hold, Self.failure)
        }
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        if hold { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
