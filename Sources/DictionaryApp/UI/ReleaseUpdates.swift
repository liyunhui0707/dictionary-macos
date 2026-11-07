import Foundation
import Combine

/// Public stable releases only. No credentials, automatic polling or installation.
struct ReleaseVersion: Equatable, Comparable, Sendable {
    let major: Int; let minor: Int; let patch: Int
    init?(_ text: String) {
        let raw = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 8 &&
            $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || $0.first != "0") }),
            let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }
        major = a; minor = b; patch = c
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct PublicRelease: Equatable, Sendable {
    let version: String
    let url: URL
    static let downloads = URL(string: "https://github.com/liyunhui0707/dictionary-macos/releases")!
    static let endpoint = URL(string: "https://api.github.com/repos/liyunhui0707/dictionary-macos/releases/latest")!

    static func decode(_ data: Data) throws -> PublicRelease {
        struct Payload: Decodable {
            let tag_name: String; let html_url: String; let draft: Bool; let prerelease: Bool
        }
        guard data.count <= 262_144 else { throw ReleaseUpdateError.invalid }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease, ReleaseVersion(payload.tag_name) != nil,
              let url = URL(string: payload.html_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/liyunhui0707/dictionary-macos/releases/tag/\(payload.tag_name)" else {
            throw ReleaseUpdateError.invalid
        }
        return PublicRelease(version: payload.tag_name, url: url)
    }

    static func fetch() async throws -> PublicRelease? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: CloudRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Dictionary-macOS", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReleaseUpdateError.invalid }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200, response.expectedContentLength <= 262_144 else { throw ReleaseUpdateError.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262_144 else { throw ReleaseUpdateError.invalid }
            data.append(byte)
        }
        return try decode(data)
    }
}

private enum ReleaseUpdateError: Error { case invalid }

@MainActor
final class ReleaseUpdates: ObservableObject {
    enum State: Equatable { case idle, checking, current, available(PublicRelease), noRelease, failed, unversioned }
    @Published private(set) var state: State = .idle
    let installed: String
    private let fetch: @Sendable () async throws -> PublicRelease?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(installed: String, fetch: @escaping @Sendable () async throws -> PublicRelease? = { try await PublicRelease.fetch() }) {
        self.installed = installed; self.fetch = fetch
    }
    func check() {
        cancel()
        guard let current = ReleaseVersion(installed) else { state = .unversioned; return }
        let intent = generation
        state = .checking
        task = Task { [weak self, fetch] in
            do {
                let release = try await fetch()
                guard !Task.isCancelled, let self, self.generation == intent else { return }
                if let release, let latest = ReleaseVersion(release.version) {
                    self.state = current < latest ? .available(release) : .current
                } else { self.state = .noRelease }
            } catch {
                guard !Task.isCancelled, let self, self.generation == intent else { return }
                self.state = .failed
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; state = .idle }
}
