import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct ReleaseUpdatesTests {
    @Test func renamedRepositoryFallbackIsBoundedAndNeverFollowsLocation() async throws {
        let data = try payload(url: "https://github.com/liyunhui0707/wordlit/releases/tag/v0.3.0")
        for code in [301, 308, 404] {
            let source = ReleaseTransport(statuses: [code, 200], data: data)
            let release = try await PublicRelease.fetch(using: { try await source.send($0) })
            #expect(release?.version == "v0.3.0")
            #expect(await source.addresses == [PublicRelease.endpoint, PublicRelease.wordlitEndpoint])
        }
        let unavailable = ReleaseTransport(statuses: [503], data: data)
        await #expect(throws: (any Error).self) {
            try await PublicRelease.fetch(using: { try await unavailable.send($0) })
        }
        #expect(await unavailable.addresses == [PublicRelease.endpoint])
        let absent = ReleaseTransport(statuses: [404, 404], data: data)
        #expect(try await PublicRelease.fetch(using: { try await absent.send($0) }) == nil)
        #expect(await absent.addresses.count == 2)
        let redirectLoop = ReleaseTransport(statuses: [301, 301], data: data)
        await #expect(throws: (any Error).self) {
            try await PublicRelease.fetch(using: { try await redirectLoop.send($0) })
        }
        #expect(await redirectLoop.addresses.count == 2)
    }
    @Test func wordlitMigrationAcceptsNewAndLegacyReleasesWithoutWideningTrust() throws {
        for repository in ["wordlit", "dictionary-macos"] {
            let base = "https://github.com/liyunhui0707/\(repository)/releases"
            let names = ["Wordlit-0.3.0-macOS-arm64.dmg", "Dictionary-0.3.0-macOS-arm64.zip"]
            let assets = names.map { asset($0, url: "\(base)/download/v0.3.0/\($0)") }
            let release = try PublicRelease.decode(payload(url: "\(base)/tag/v0.3.0", assets: assets))
            #expect(release.installer(for: .arm64, format: .dmg)?.name == names[0])
            #expect(release.installer(for: .arm64, format: .zip)?.name == names[1])
        }
        let name = "Wordlit-0.3.0-macOS-arm64.dmg"
        let preferred = try PublicRelease.decode(payload(assets: [asset("Dictionary-0.3.0-macOS-arm64.dmg"), asset(name)]))
        #expect(preferred.installer(for: .arm64, format: .dmg)?.name == name)
        let unrelated = try PublicRelease.decode(payload(assets: [asset(name,
            url: "https://github.com/other/wordlit/releases/download/v0.3.0/\(name)")]))
        #expect(unrelated.installer(for: .arm64, format: .dmg) == nil)
        #expect(throws: (any Error).self) {
            try PublicRelease.decode(payload(url: "https://github.com/liyunhui0707/wordlit-copy/releases/tag/v0.3.0"))
        }
    }
    @Test func hostArchitectureDistinguishesIntelFromRosettaAndUnknown() {
        #expect(ReleaseArchitecture.host(process: .arm64, translationState: nil) == .arm64)
        #expect(ReleaseArchitecture.host(process: .x86_64, translationState: 0) == .x86_64)
        #expect(ReleaseArchitecture.host(process: .x86_64, translationState: 1) == .arm64)
        #expect(ReleaseArchitecture.host(process: .x86_64, translationState: nil) == nil)
    }
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
    @Test func installersRequireExactVersionArchitectureAndCanonicalAssetURL() throws {
        let stem = "Dictionary-0.3.0-macOS-"
        let good = stem + "arm64.dmg"
        let intel = stem + "x86_64.zip"
        let assets: [[String: Any]] = [
            asset(good), asset(intel), asset("SHA256SUMS"),
            asset(stem + "arm64.zip", url: "https://evil.invalid/installer.zip"),
            asset("Dictionary-0.2.0-macOS-arm64.zip"),
            asset("source.zip"),
            asset(stem + "x86_64.dmg", size: 0)
        ]
        let release = try PublicRelease.decode(payload(assets: assets))
        #expect(release.installer(for: .arm64, format: .dmg)?.name == good)
        #expect(release.installer(for: .arm64, format: .zip) == nil)
        #expect(release.installer(for: .x86_64, format: .zip)?.name == intel)
        #expect(release.installer(for: .x86_64, format: .dmg) == nil)
        #expect(release.checksums != nil)
        for url in [
            "http://github.com/liyunhui0707/dictionary-macos/releases/download/v0.3.0/\(good)",
            "https://user@github.com/liyunhui0707/dictionary-macos/releases/download/v0.3.0/\(good)",
            "https://github.com/liyunhui0707/dictionary-macos/releases/download/v0.2.0/\(good)",
            "https://github.com/liyunhui0707/dictionary-macos/releases/download/v0.3.0/\(good)?token=x",
            "https://github.com/other/repo/releases/download/v0.3.0/\(good)"
        ] {
            let rejected = try PublicRelease.decode(payload(assets: [asset(good, url: url)]))
            #expect(rejected.installer(for: .arm64, format: .dmg) == nil)
        }
        let ambiguous = try PublicRelease.decode(payload(assets: [asset(good), asset(good)]))
        #expect(ambiguous.installer(for: .arm64, format: .dmg) == nil)
    }
    @Test func missingAssetsNeverInventDownloadsAndNotesAreBoundedPlainText() throws {
        let original = "[Synthetic note](https://example.invalid)\n" + String(repeating: "x", count: 8_000)
        let release = try PublicRelease.decode(payload(notes: original))
        #expect(release.installer(for: .arm64, format: .dmg) == nil)
        #expect(release.installer(for: .x86_64, format: .zip) == nil)
        #expect(release.checksums == nil)
        #expect(release.notes.hasPrefix("[Synthetic note](https://example.invalid)"))
        #expect(release.notes.count <= 6_001)
        #expect(try PublicRelease.decode(payload(notes: nil)).notes.isEmpty)
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
        let current = ReleaseUpdates(installed: "0.3.0", fetch: { release })
        current.check()
        try await wait { current.state == .current(release) }
        let ahead = ReleaseUpdates(installed: "0.10.0", fetch: { release })
        ahead.check()
        try await wait { ahead.state == .ahead(release) }
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
    @Test func repeatedCheckCannotBeOverwrittenByAnEarlierResponse() async throws {
        let source = UpdateSource()
        let updates = ReleaseUpdates(installed: "0.2.0", fetch: { try await source.fetch() })
        updates.check(); await source.waitForCall(1)
        updates.check(); await source.waitForCall(2)
        let release = try PublicRelease.decode(payload())
        await source.finish(release, call: 2)
        try await wait { updates.state == .available(release) }
        await source.finish(nil, call: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(updates.state == .available(release))
    }
    private func payload(url: String = "https://github.com/liyunhui0707/dictionary-macos/releases/tag/v0.3.0",
                         draft: Bool = false, prerelease: Bool = false,
                         notes: String? = nil, assets: [[String: Any]] = []) throws -> Data {
        var object: [String: Any] = ["tag_name": "v0.3.0", "html_url": url,
            "draft": draft, "prerelease": prerelease, "assets": assets]
        object["body"] = notes
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func asset(_ name: String, url: String? = nil, size: Int = 1234) -> [String: Any] {
        ["name": name, "size": size, "browser_download_url": url ??
            "https://github.com/liyunhui0707/dictionary-macos/releases/download/v0.3.0/\(name)"]
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

private actor ReleaseTransport {
    private var statuses: [Int]
    private let data: Data
    private(set) var addresses: [URL] = []
    init(statuses: [Int], data: Data) { self.statuses = statuses; self.data = data }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let address = try #require(request.url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        addresses.append(address)
        let status = try #require(statuses.first)
        statuses.removeFirst()
        return (data, try #require(HTTPURLResponse(url: address, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Location": "https://untrusted.invalid/release"])))
    }
}

private actor UpdateSource {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<PublicRelease?, Error>] = [:]
    func fetch() async throws -> PublicRelease? {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }
    func waitForCall(_ count: Int) async {
        while calls < count { await Task.yield() }
    }
    func finish(_ release: PublicRelease?, call: Int? = nil) { pending.removeValue(forKey: call ?? calls)?.resume(returning: release) }
    func fail() { pending.removeValue(forKey: calls)?.resume(throwing: URLError(.notConnectedToInternet)) }
}
