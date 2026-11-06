import Foundation
import Testing
@testable import DictionaryApp

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OllamaModelListingTests {
    private func client() -> OllamaModelListClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelListProtocol.self]
        return OllamaModelListClient(configuration: config)
    }

    @Test func explicitCheckOnlyListsLocalModelsWithoutTextOrCredentials() async throws {
        ModelListProtocol.reset(body: #"{"models":[{"name":"other:small"},{"name":"qwen2.5:7b"},{"name":"other:small"}]}"#)
        let client = client()
        #expect(ModelListProtocol.requests.isEmpty)
        #expect(try await client.models() == ["other:small", "qwen2.5:7b"])
        let request = try #require(ModelListProtocol.requests.first)
        #expect(ModelListProtocol.requests.count == 1)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/tags")
        #expect(request.httpMethod == "GET" && request.timeoutInterval == 5)
        #expect(request.httpBody == nil && request.httpBodyStream == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func emptyInstalledListIsValid() async throws {
        ModelListProtocol.reset(body: #"{"models":[]}"#)
        #expect(try await client().models().isEmpty)
    }

    @Test func remoteReferencesAreNotOfferedAsLocalModels() async throws {
        ModelListProtocol.reset(body: #"{"models":[{"name":"local:small"},{"name":"remote:large","remote_host":"https://example.invalid"},{"name":"alias:latest","remote_model":"remote-model"}]}"#)
        #expect(try await client().models() == ["local:small"])
        #expect(ModelListProtocol.requests.count == 1)
    }

    @Test(arguments: ["malformed", "missingName", "invalidName", "missingList", "oversize"])
    func malformedAndOversizeRepliesAreNotAvailabilityEvidence(kind: String) async {
        let body: String
        switch kind {
        case "missingName": body = #"{"models":[{}]}"#
        case "invalidName": body = #"{"models":[{"name":"bad\nname"}]}"#
        case "missingList": body = #"{}"#
        case "oversize": body = String(repeating: "x", count: 1_048_577)
        default: body = "invalid"
        }
        ModelListProtocol.reset(body: body)
        do { _ = try await client().models(); Issue.record("Expected invalid response") }
        catch { #expect(error as? OllamaServiceError == .invalidResponse) }
        #expect(ModelListProtocol.requests.count == 1)
    }

    @Test(arguments: [302, 404, 500])
    func httpFailuresAreNotRetriedOrReturnedAsRawText(status: Int) async {
        ModelListProtocol.reset(body: "unreviewed diagnostic text", status: status)
        do { _ = try await client().models(); Issue.record("Expected HTTP failure") }
        catch { #expect(error as? OllamaServiceError == .invalidResponse) }
        #expect(ModelListProtocol.requests.count == 1)
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut, .cancelled])
    func transportErrorsAreClassifiedWithoutRetry(code: URLError.Code) async {
        ModelListProtocol.reset(body: "", error: code)
        do { _ = try await client().models(); Issue.record("Expected transport failure") }
        catch {
            if code == .cancelled { #expect(error is CancellationError) }
            else { #expect(error as? OllamaServiceError == (code == .timedOut ? .timedOut : .unreachable)) }
        }
        #expect(ModelListProtocol.requests.count == 1)
    }

    @Test func redirectsCannotLeaveTheLocalService() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://localhost:11434/api/tags")!) // Never resumed.
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let destination: URLRequest? = await withCheckedContinuation { continuation in
            LocalModelRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { continuation.resume(returning: $0) }
        }
        #expect(destination == nil)
    }
}

/// All requests are intercepted; these tests never contact the real local service.
private final class ModelListProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var payload = Data()
    private static var status = 200
    private static var failure: URLError.Code?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(body: String, status: Int = 200, error: URLError.Code? = nil) {
        lock.withLock { recorded = []; payload = Data(body.utf8); self.status = status; failure = error }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status, error) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.payload, Self.status, Self.failure)
        }
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
