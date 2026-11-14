import Foundation
import Combine
import Darwin

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

enum ReleaseArchitecture: String, Sendable {
    case arm64, x86_64
    var label: String { self == .arm64 ? "Apple Silicon" : "Intel" }
    static var current: Self? {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        host(process: .x86_64, translationState: translationState())
        #else
        nil
        #endif
    }
    static func host(process: Self, translationState: Int32?) -> Self? {
        if process == .arm64 { return .arm64 }
        switch translationState { case 0: return .x86_64; case 1: return .arm64; default: return nil }
    }
    // Apple's Rosetta process check avoids treating a translated Intel App as an Intel Mac.
    // https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment
    private static func translationState() -> Int32? {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 { return translated }
        return errno == ENOENT ? 0 : nil
    }
}

enum ReleaseInstallerFormat: String { case dmg, zip }

struct PublicRelease: Equatable, Sendable {
    struct Asset: Equatable, Sendable { let name: String; let url: URL }
    let version: String
    let url: URL
    let notes: String
    private let assets: [Asset]
    static let downloads = URL(string: "https://github.com/liyunhui0707/dictionary-macos/releases")!
    static let endpoint = URL(string: "https://api.github.com/repos/liyunhui0707/dictionary-macos/releases/latest")!

    static func decode(_ data: Data) throws -> PublicRelease {
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64 }
            let tag_name: String; let html_url: String; let draft: Bool; let prerelease: Bool
            let body: String?
            let assets: [Asset]?
        }
        guard data.count <= 262_144 else { throw ReleaseUpdateError.invalid }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease, ReleaseVersion(payload.tag_name) != nil,
              let url = URL(string: payload.html_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/liyunhui0707/dictionary-macos/releases/tag/\(payload.tag_name)" else {
            throw ReleaseUpdateError.invalid
        }
        let number = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let allowedNames = Set(ReleaseArchitecture.allAssetNames(version: number) + ["SHA256SUMS"])
        let candidates = payload.assets ?? []
        let counts = Dictionary(grouping: candidates, by: \.name).mapValues(\.count)
        let assets = candidates.compactMap { asset -> Asset? in
            guard allowedNames.contains(asset.name), counts[asset.name] == 1, asset.size > 0,
                  let address = URL(string: asset.browser_download_url), address.scheme == "https",
                  address.host == "github.com", address.user == nil, address.password == nil,
                  address.port == nil, address.query == nil, address.fragment == nil,
                  address.path == "/liyunhui0707/dictionary-macos/releases/download/\(payload.tag_name)/\(asset.name)" else { return nil }
            return Asset(name: asset.name, url: address)
        }
        let body = (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = String(body.prefix(6_000)) + (body.count > 6_000 ? "…" : "")
        return PublicRelease(version: payload.tag_name, url: url, notes: notes, assets: assets)
    }

    func installer(for architecture: ReleaseArchitecture, format: ReleaseInstallerFormat) -> Asset? {
        let number = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return assets.first { $0.name == "Dictionary-\(number)-macOS-\(architecture.rawValue).\(format.rawValue)" }
    }
    var checksums: URL? { assets.first { $0.name == "SHA256SUMS" }?.url }

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

private extension ReleaseArchitecture {
    static func allAssetNames(version: String) -> [String] {
        [Self.arm64, .x86_64].flatMap { architecture in
            ["dmg", "zip"].map { "Dictionary-\(version)-macOS-\(architecture.rawValue).\($0)" }
        }
    }
}

private enum ReleaseUpdateError: Error { case invalid }

@MainActor
final class ReleaseUpdates: ObservableObject {
    enum State: Equatable { case idle, checking, current(PublicRelease), available(PublicRelease), ahead(PublicRelease), noRelease, failed, unversioned }
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
                    if current < latest { self.state = .available(release) }
                    else if current == latest { self.state = .current(release) }
                    else { self.state = .ahead(release) }
                } else { self.state = .noRelease }
            } catch {
                guard !Task.isCancelled, let self, self.generation == intent else { return }
                self.state = .failed
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; state = .idle }
}
