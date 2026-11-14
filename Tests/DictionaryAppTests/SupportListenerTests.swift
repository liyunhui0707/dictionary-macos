import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SupportListenerTests {
    @Test func listenerReportsActualReadinessAndAsynchronousPortFailure() async throws {
        func make(port: UInt16, events: ListenerEvents) -> HTTPServer {
            let tokens = TokenStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SupportListener-\(UUID())"))
            return HTTPServer(port: port, handler: TranslateHandler(tokenStore: tokens,
                coordinator: LookupCoordinator(provider: ControlledProvider())), onState: { events.add($0) })
        }
        let firstEvents = ListenerEvents(), secondEvents = ListenerEvents()
        let first = make(port: 0, events: firstEvents)
        try first.start()
        defer { first.stop() }
        for _ in 0..<200 where !firstEvents.values.contains(.listening) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(firstEvents.values.first == .starting && firstEvents.values.contains(.listening))
        let port = try #require(first.boundPort)
        let second = make(port: port, events: secondEvents)
        do { try second.start() } catch { secondEvents.add(.unavailable) }
        defer { second.stop() }
        for _ in 0..<200 where !secondEvents.values.contains(.unavailable) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(secondEvents.values.contains(.unavailable))
        #expect(!secondEvents.values.contains(.listening))
        first.stop()
        for _ in 0..<200 where !firstEvents.values.contains(.stopped) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(firstEvents.values.last == .stopped)
    }
}

private final class ListenerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LocalListenerState] = []
    var values: [LocalListenerState] { lock.withLock { stored } }
    func add(_ state: LocalListenerState) { lock.withLock { stored.append(state) } }
}
