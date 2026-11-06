import Foundation
import Security

/// Persists a single Bearer token in the user's Application Support
/// directory with mode 0600. The token is generated on first access and
/// reused thereafter. `regenerate()` replaces it.
final class TokenStore {
    private let directory: URL
    private let fileName = "token"

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    var token: String {
        if let existing = readToken(), !existing.isEmpty {
            return existing
        }
        let fresh = Self.generateToken()
        writeToken(fresh)
        return fresh
    }

    @discardableResult
    func regenerate() -> String {
        let fresh = Self.generateToken()
        writeToken(fresh)
        return fresh
    }

    // MARK: - File I/O

    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    private func readToken() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeToken(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = token.data(using: .utf8) ?? Data()
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            NSLog("TokenStore: failed to write token: \(error)")
        }
    }

    // MARK: - Statics

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("DictionaryApp", isDirectory: true)
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fall back to a less-secure but functional source.
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    /// Base64-URL encoding without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
