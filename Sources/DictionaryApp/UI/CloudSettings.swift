import Foundation
import Combine

@MainActor
final class CloudSettings: ObservableObject {
    static let enabledPreference = "Dictionary.DeepSeekAssistance.enabled"
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var message: String
    private let store: any CloudCredentialStore
    private let persistEnabled: (Bool) -> Void
    private let applyProvider: (TranslationProvider?) -> Void

    init(store: any CloudCredentialStore, enabled: Bool,
         persistEnabled: @escaping (Bool) -> Void, applyProvider: @escaping (TranslationProvider?) -> Void) {
        self.store = store
        self.isEnabled = enabled
        self.persistEnabled = persistEnabled
        self.applyProvider = applyProvider
        message = enabled ? "已开启。发起 DeepSeek 查询时才会读取已保存的密钥。" : "DeepSeek 未开启。"
        // Only the non-sensitive preference is restored. No Keychain access or network on launch.
        applyProvider(enabled ? KeychainDeepSeekProvider(store: store) : nil)
    }

    @discardableResult
    func save(_ key: String) async -> Bool {
        guard !isBusy else { return false }
        guard DeepSeekProvider.validKey(key) else {
            message = "请输入不含空格或换行的 API 密钥，最长 4,096 个字符。"
            return false
        }
        isBusy = true
        defer { isBusy = false }
        setEnabled(false)
        do {
            try await store.save(key)
            guard try await store.read() == key else { throw CloudAssistanceError.credentialUnavailable }
            setEnabled(true)
            message = "密钥已保存至钥匙串，尚未验证 API。"
            return true
        } catch {
            message = "未能在钥匙串中保存并核验密钥，DeepSeek 已关闭。不会改用明文保存。"
            return false
        }
    }

    func enableSavedKey() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        setEnabled(false)
        do {
            guard let key = try await store.read(), DeepSeekProvider.validKey(key) else {
                message = "未找到可用密钥，请输入你的 DeepSeek API 密钥。"
                return
            }
            setEnabled(true)
            message = "已保存的密钥可读取，尚未验证 API。"
        } catch {
            message = "无法访问钥匙串，DeepSeek 已关闭。再次启用时，请允许钥匙串访问。"
        }
    }

    func disable() {
        guard !isBusy else { return }
        setEnabled(false)
        message = "DeepSeek 已关闭，已保存的密钥仍保留在钥匙串中。"
    }

    func remove() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        setEnabled(false)
        do {
            try await store.remove()
            message = "密钥已移除，DeepSeek 已关闭。"
        } catch {
            message = "DeepSeek 已关闭，但未能从钥匙串移除密钥。"
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        persistEnabled(enabled)
        applyProvider(enabled ? KeychainDeepSeekProvider(store: store) : nil)
    }
}
