import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct ReleaseUpdatesTests {
    @Test func stableVersionsCompareNumericallyAndRejectAmbiguity() throws {
        #expect(try #require(ReleaseVersion("0.10.0")) > #require(ReleaseVersion("v0.2.9")))
        for value in ["0.2", "0.2.0-beta.1", "0.2.0+build", "01.2.0", "0.-1.0", "0.2.0/path", " 0.2.0", "999999999.0.0"] {
            #expect(ReleaseVersion(value) == nil)
        }
    }
    @Test func releasePayloadOnlyAcceptsThisRepositoryAndStableTag() throws {
        let expected = try PublicRelease.decode(payload())
        #expect(expected.version == "v0.3.0")
        for url in ["https://evil.invalid/v0.3.0", "https://github.com/other/repo/releases/tag/v0.3.0",
                    "https://github.com/liyunhui0707/dictionary-macos/releases/tag/v0.3.0?token=x",
                    "https://user@github.com/liyunhui0707/dictionary-macos/releases/tag/v0.3.0",
                    "http://github.com/liyunhui0707/dictionary-macos/releases/tag/v0.3.0"] {
            #expect(throws: (any Error).self) { try PublicRelease.decode(payload(url: url)) }
        }
        #expect(throws: (any Error).self) { try PublicRelease.decode(payload(draft: true)) }
        #expect(throws: (any Error).self) { try PublicRelease.decode(payload(prerelease: true)) }
        #expect(throws: (any Error).self) { try PublicRelease.decode(Data(repeating: 32, count: 262_145)) }
    }
    @Test func noRequestsOnConstructionAndExplicitCheckHandlesAllOutcomes() async throws {
        let source = UpdateSource()
        let updates = ReleaseUpdates(installed: "0.2.0", fetch: { try await source.fetch() })
        #expect(await source.calls == 0)
        updates.check(); await source.waitForCall(1)
        await source.finish(nil)
        try await wait { updates.state == .noRelease }
        updates.check(); await source.waitForCall(2)
        let release = try PublicRelease.decode(payload())
        await source.finish(release)
        try await wait { updates.state == .available(release) }
        updates.check(); await source.waitForCall(3)
        await source.fail()
        try await wait { updates.state == .failed }
        let current = ReleaseUpdates(installed: "0.10.0", fetch: { release })
        current.check()
        try await wait { current.state == .current }
    }
    @Test func closingWindowRejectsLateCompletionAndCannotStartUnversionedLookup() async throws {
        let source = UpdateSource()
        let updates = ReleaseUpdates(installed: "0.2.0", fetch: { try await source.fetch() })
        updates.check(); await source.waitForCall(1)
        updates.cancel()
        await source.finish(try PublicRelease.decode(payload()))
        try await Task.sleep(for: .milliseconds(30))
        #expect(updates.state == .idle)
        let unversioned = ReleaseUpdates(installed: "source", fetch: { try await source.fetch() })
        unversioned.check()
        #expect(unversioned.state == .unversioned)
        #expect(await source.calls == 1)
    }
    private func payload(url: String = "https://github.com/liyunhui0707/dictionary-macos/releases/tag/v0.3.0",
                         draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": "v0.3.0", "html_url": url,
            "draft": draft, "prerelease": prerelease])
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

private actor UpdateSource {
    private(set) var calls = 0
    private var pending: CheckedContinuation<PublicRelease?, Error>?
    func fetch() async throws -> PublicRelease? {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForCall(_ count: Int) async {
        while calls < count { await Task.yield() }
    }
    func finish(_ release: PublicRelease?) { pending?.resume(returning: release); pending = nil }
    func fail() { pending?.resume(throwing: URLError(.notConnectedToInternet)); pending = nil }
}
