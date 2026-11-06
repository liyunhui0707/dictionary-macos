import Foundation
import Security
import Testing
@testable import DictionaryApp

@Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudCredentialStoreTests {
    @Test func readUpdateAndDeleteUseOnlyTheDedicatedItem() async throws {
        let client = RecordingKeychain()
        client.readData = Data("synthetic-only".utf8)
        let store = KeychainCloudCredentialStore(client: client)
        #expect(try await store.read() == "synthetic-only")
        try await store.save("replacement-synthetic")
        try await store.remove()
        #expect(client.operations == ["read", "update", "delete"])
        for query in client.queries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "com.liyunhui.DictionaryApp.cloud.deepseek")
            #expect(query[kSecAttrAccount as String] as? String == "api-key")
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
            #expect(query[kSecAttrSynchronizable as String] == nil)
            #expect(query[kSecAttrAccess as String] == nil)
            #expect(query[kSecAttrAccessGroup as String] == nil)
        }
        #expect(client.queries[0][kSecReturnData as String] as? Bool == true)
        #expect(client.queries[0][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(Set(client.queries[1].keys) == Set(client.queries[2].keys))
        #expect(Set(client.updated.keys) == [kSecValueData as String])
        #expect(client.updated[kSecValueData as String] as? Data == Data("replacement-synthetic".utf8))
    }

    @Test func onlyMissingItemAllowsAddNeverDeleteBeforeReplace() async throws {
        let client = RecordingKeychain()
        client.updateStatus = errSecItemNotFound
        let store = KeychainCloudCredentialStore(client: client)
        try await store.save("synthetic-only")
        #expect(client.operations == ["update", "add"])
        #expect(client.added[kSecValueData as String] as? Data == Data("synthetic-only".utf8))
        #expect(client.added[kSecAttrService as String] as? String == "com.liyunhui.DictionaryApp.cloud.deepseek")
        #expect(client.added[kSecAttrAccess as String] == nil) // Default Keychain ACL, not all-app access.
        #expect(client.added[kSecAttrSynchronizable as String] == nil)
    }

    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled])
    func deniedReplacementDoesNotAddOrDelete(status: OSStatus) async {
        let client = RecordingKeychain()
        client.updateStatus = status
        let store = KeychainCloudCredentialStore(client: client)
        await #expect(throws: CloudAssistanceError.self) { try await store.save("synthetic-only") }
        #expect(client.operations == ["update"])
    }

    @Test func duplicateAddStopsWithoutRetryAndMissingDeleteSucceeds() async throws {
        let client = RecordingKeychain()
        client.updateStatus = errSecItemNotFound
        client.addStatus = errSecDuplicateItem
        let store = KeychainCloudCredentialStore(client: client)
        await #expect(throws: CloudAssistanceError.self) { try await store.save("synthetic-only") }
        #expect(client.operations == ["update", "add"])
        client.deleteStatus = errSecItemNotFound
        try await store.remove()
    }

    @Test func missingInvalidAndLockedItemsAreDistinctFromUsableKeys() async throws {
        let client = RecordingKeychain()
        let store = KeychainCloudCredentialStore(client: client)
        client.readStatus = errSecItemNotFound
        #expect(try await store.read() == nil)
        client.readStatus = errSecSuccess
        client.readData = Data([0xFF])
        await #expect(throws: CloudAssistanceError.self) { _ = try await store.read() }
        client.readStatus = errSecInteractionNotAllowed
        await #expect(throws: CloudAssistanceError.self) { _ = try await store.read() }
    }

    @Test func missingCredentialCannotStartHTTP() async {
        let client = RecordingKeychain()
        client.readStatus = errSecItemNotFound
        let provider = KeychainDeepSeekProvider(store: KeychainCloudCredentialStore(client: client))
        do {
            _ = try await provider.translate(target: "bank", context: "synthetic", containingSentence: nil, targetLanguage: "中文")
            Issue.record("Expected a credential error before HTTP")
        } catch {
            #expect(error.localizedDescription == CloudAssistanceError.credentialUnavailable.localizedDescription)
        }
        #expect(client.operations == ["read"])
    }
}

/// Each test owns its client; inspection happens after the store actor has finished.
private final class RecordingKeychain: CloudKeychainClient, @unchecked Sendable {
    var operations: [String] = []
    var queries: [[String: Any]] = []
    var updated: [String: Any] = [:]
    var added: [String: Any] = [:]
    var readStatus = errSecSuccess
    var readData: Data?
    var updateStatus = errSecSuccess
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        operations.append("read"); queries.append(query)
        return (readStatus, readData)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        operations.append("update"); queries.append(query); updated = attributes
        return updateStatus
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        operations.append("add"); added = attributes
        return addStatus
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        operations.append("delete"); queries.append(query)
        return deleteStatus
    }
}
