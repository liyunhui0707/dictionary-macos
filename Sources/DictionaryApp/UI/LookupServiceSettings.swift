import Foundation
import Combine

enum LookupService: String, CaseIterable, Sendable {
    case local, deepSeek
    var label: String { self == .local ? "Ollama 本地" : "DeepSeek 云端" }
}

/// Choosing cloud is separate from merely saving a key for optional assistance.
/// Construction, navigation and persistence never access a key or a service.
@MainActor
final class LookupServiceSettings: ObservableObject {
    static let preference = "Dictionary.Lookup.service"
    @Published private(set) var selected: LookupService?
    @Published private(set) var cloudAvailable = false
    let isManaged: Bool
    private let persist: (String) -> Void
    private let changed: () -> Void

    init(saved: String?, isManaged: Bool = false, persist: @escaping (String) -> Void = { _ in },
         changed: @escaping () -> Void = {}) {
        selected = saved.flatMap(LookupService.init(rawValue:))
        self.isManaged = isManaged; self.persist = persist; self.changed = changed
    }

    var needsSetup: Bool { !isManaged && (selected == nil || selected == .deepSeek && !cloudAvailable) }
    var label: String { isManaged ? "启动指定服务" : selected?.label ?? "尚未选择查词方式" }

    @discardableResult
    func choose(_ service: LookupService, cloudConsent: Bool = false) -> Bool {
        guard !isManaged, service != .deepSeek || cloudAvailable && cloudConsent else { return false }
        selected = service; persist(service.rawValue); changed()
        return true
    }

    func setCloudAvailable(_ available: Bool) {
        cloudAvailable = available
        changed()
    }

    static func preview() -> LookupServiceSettings { .init(saved: LookupService.local.rawValue) }
}

struct UnconfiguredLookupProvider: TranslationProvider {
    let cloudDisabled: Bool
    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> Translation {
        throw LookupServiceSetupError(cloudDisabled: cloudDisabled)
    }
}

struct LookupServiceSetupError: LocalizedError {
    let cloudDisabled: Bool
    var errorDescription: String? {
        cloudDisabled ? "DeepSeek 尚未开启。请在查词服务设置中保存或启用你的 API 密钥。" :
            "请先在查词服务设置中选择 DeepSeek 云端或 Ollama 本地。"
    }
}
