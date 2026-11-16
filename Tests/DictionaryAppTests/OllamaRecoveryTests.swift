import Foundation
import Testing
@testable import DictionaryApp

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OllamaRecoveryTests {
    private func translate() async throws -> Translation {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryTransport.self]
        return try await OllamaProvider(dictionary: EnglishDictionary(resourceURL: nil), session: URLSession(configuration: config))
            .translate(target: "bank", context: "bank", containingSentence: nil, targetLanguage: "简体中文")
    }

    @Test func unavailableAndTimeoutGiveDifferentRecoveryWithoutRetries() async {
        for code in [URLError.Code.cannotConnectToHost, .timedOut] {
            RecoveryTransport.reset(error: code)
            do { _ = try await translate(); Issue.record("Expected transport failure") }
            catch {
                #expect(error.localizedDescription.contains(code == .timedOut ? "超时" : "打开 Ollama"))
                #expect(!error.localizedDescription.contains("API error -1"))
            }
            #expect(RecoveryTransport.count == 1)
        }
    }

    @Test func cancellationStaysCancellation() async {
        RecoveryTransport.reset(error: .cancelled)
        do { _ = try await translate(); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(RecoveryTransport.count == 1)
    }

    @Test func rejectedOrMalformedReplyIsNotAConnectionFailure() async {
        for status in [404, 500, 200] {
            RecoveryTransport.reset(status: status, body: "unreviewed service diagnostic")
            do { _ = try await translate(); Issue.record("Expected failure") }
            catch {
                #expect(error.localizedDescription.contains(status == 200 ? "响应格式" : status == 404 ? "模型" : "500"))
                #expect(!error.localizedDescription.contains("unreviewed service diagnostic"))
            }
            #expect(RecoveryTransport.count == 1)
        }
    }

    @Test func laterSuccessfulRequestRecoversWithoutRestartOrModelChange() async throws {
        RecoveryTransport.reset(error: .cannotConnectToHost)
        do { _ = try await translate(); Issue.record("Expected failure") } catch {}
        RecoveryTransport.reset(body: #"{"message":{"role":"assistant","content":"{\"meaning_in_context\":\"河岸\"}"}}"#)
        let response = try await translate()
        #expect(response.meaningInContext == "河岸" && RecoveryTransport.count == 1)
    }
}

private final class RecoveryTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var failure: URLError.Code?
    private static var status = 200
    private static var payload = Data()
    private static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func reset(status: Int = 200, body: String = "", error: URLError.Code? = nil) {
        lock.withLock { self.status = status; payload = Data(body.utf8); failure = error; requests = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status, error) = Self.lock.withLock {
            Self.requests += 1
            return (Self.payload, Self.status, Self.failure)
        }
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
