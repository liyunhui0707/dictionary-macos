import Foundation
import Network
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTTPServerConnectionTests {
    // Real sockets, but only an OS-assigned ephemeral port in the test process.
    // Never use the installed App's port or token store.
    private func setup() throws -> (HTTPServer, ControlledProvider, LookupCoordinator, String) {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryWireTests-\(UUID())")
        let tokens = TokenStore(directory: directory)
        let server = HTTPServer(port: 0, handler: TranslateHandler(tokenStore: tokens, coordinator: coordinator))
        try server.start()
        return (server, provider, coordinator, tokens.token)
    }

    private func readyPort(_ server: HTTPServer) async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = server.boundPort, port != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try #require(server.boundPort)
    }

    private func call(_ provider: ControlledProvider, _ target: String) async throws -> ControlledProvider.Call {
        for _ in 0..<300 {
            if let call = await provider.calls.first(where: { $0.target == target }) { return call }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try #require(await provider.calls.first(where: { $0.target == target }))
    }

    private func request(_ token: String, target: String) -> String {
        let body = "{\"target\":\"\(target)\"}"
        return "POST /v1/translate HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    nonisolated private static func exchange(_ bytes: String, port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "DictionaryWireTest-\(UUID())")
            let deadline = DispatchWorkItem { connection.cancel() }
            func finish(_ result: Result<String, Error>) {
                deadline.cancel()
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive(_ previous: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { finish(.failure(error)); return }
                    var result = previous
                    if let data { result.append(data) }
                    if complete { finish(.success(String(decoding: result, as: UTF8.self))) }
                    else { receive(result) }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    connection.send(content: Data(bytes.utf8), completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) }
                        else { receive(Data()) }
                    })
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        }
    }

    @Test func invalidUnauthenticatedFramingReturns400AndServerStillHandles401And200() async throws {
        let (server, provider, _, token) = try setup()
        defer { server.stop() }
        let port = try await readyPort(server)
        for headers in ["Content-Length: -1", "Content-Length: abc", "Content-Length: 999999999999999999999999",
                        "Content-Length: 0\r\nContent-Length: 1", "Transfer-Encoding: chunked"] {
            let response = try await Self.exchange("POST /v1/translate HTTP/1.1\r\n\(headers)\r\n\r\nPRIVATE_BODY_SENTINEL", port: port)
            #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            #expect(response.hasSuffix("\r\n\r\n"))
            #expect(!response.contains("PRIVATE_BODY_SENTINEL"))
        }
        let unauthorized = try await Self.exchange(request("wrong-test-token", target: "bank"), port: port)
        #expect(unauthorized.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(await provider.calls.isEmpty)
        let response = Task { try await Self.exchange(request(token, target: "bank"), port: port) }
        let pending = try await call(provider, "bank")
        await provider.succeed(pending, meaning: "河岸")
        let success = try await response.value
        #expect(success.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(success.contains("meaning_in_context"))
    }

    @Test func validWireRequestsRetainImmediate204AndProvider503() async throws {
        let (server, provider, coordinator, token) = try setup()
        defer { server.stop() }
        let port = try await readyPort(server)
        let old = Task { try await Self.exchange(request(token, target: "old"), port: port) }
        let oldCall = try await call(provider, "old")
        coordinator.dismissSelection()
        let cancelled = try await old.value
        #expect(cancelled.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(cancelled.hasSuffix("\r\n\r\n"))
        #expect(!cancelled.lowercased().contains("content-length"))
        await provider.succeed(oldCall)
        #expect(coordinator.selection.result == nil)
        let failing = Task { try await Self.exchange(request(token, target: "fail"), port: port) }
        let failedCall = try await call(provider, "fail")
        await provider.fail(failedCall)
        #expect(try await failing.value.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
    }
}
