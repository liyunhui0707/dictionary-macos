import Foundation
import Security

protocol CloudCredentialStore: Sendable {
    func read() async throws -> String?
    func save(_ key: String) async throws
    func remove() async throws
}

/// Injectable Security boundary. Tests never access the user's keychain.
protocol CloudKeychainClient: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemCloudKeychainClient: CloudKeychainClient {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Uses the macOS file-based Keychain (compatible with the current ad-hoc app).
/// No synchronizable attributes, custom ACL, shared access group or plaintext fallback.
/// Access is initiated by Save / Enable / Remove or a user cloud query, never by launch or view rendering.
actor KeychainCloudCredentialStore: CloudCredentialStore {
    private let client: any CloudKeychainClient
    init(client: any CloudKeychainClient = SystemCloudKeychainClient()) { self.client = client }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.liyunhui.DictionaryApp.cloud.deepseek",
         kSecAttrAccount as String: "api-key",
         kSecUseDataProtectionKeychain as String: false]
    }

    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = client.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, let key = String(data: data, encoding: .utf8),
              DeepSeekProvider.validKey(key) else { throw CloudAssistanceError.credentialUnavailable }
        return key
    }

    func save(_ key: String) throws {
        guard DeepSeekProvider.validKey(key) else { throw CloudAssistanceError.credentialUnavailable }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = client.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Dictionary · DeepSeek API Key"
            guard client.add(item) == errSecSuccess else { throw CloudAssistanceError.credentialUnavailable }
        } else if status != errSecSuccess {
            // Never delete the previous credential to make a failed replacement succeed.
            throw CloudAssistanceError.credentialUnavailable
        }
    }

    func remove() throws {
        let status = client.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudAssistanceError.credentialUnavailable
        }
    }
}

/// Retrieves a credential only for a user-selected cloud lookup or explicit Ask action.
/// The credential is not kept in settings state or injected into a subprocess environment.
struct KeychainDeepSeekProvider: TranslationProvider {
    let store: any CloudCredentialStore
    var configuration: URLSessionConfiguration = .ephemeral
    var purpose: DeepSeekProvider.Purpose = .assistance

    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> Translation {
        let key: String
        do {
            try Task.checkCancellation()
            guard let saved = try await store.read(), DeepSeekProvider.validKey(saved) else {
                throw CloudAssistanceError.credentialUnavailable
            }
            key = saved
        } catch is CancellationError { throw CancellationError() }
        catch { throw CloudAssistanceError.credentialUnavailable }
        // A settings change or dismissal while Keychain is prompting must not send a request.
        try Task.checkCancellation()
        return try await DeepSeekProvider(apiKey: key, configuration: configuration, purpose: purpose).translate(target: target, context: context,
            containingSentence: containingSentence, targetLanguage: targetLanguage)
    }
}
