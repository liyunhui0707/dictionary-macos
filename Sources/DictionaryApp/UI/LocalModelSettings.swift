import Foundation
import Combine

/// Immutable launch snapshot shared by the provider factory and Settings.
struct LocalModelConfiguration {
    static let modelPreference = "Dictionary.Ollama.model"
    static let defaultModel = "qwen2.5:7b"
    let isActive: Bool
    let environmentOverride: Bool
    let model: String

    init(environment: [String: String], savedModel: String?) {
        isActive = environment["DICTIONARY_PROVIDER"]?.lowercased() != "claude"
        environmentOverride = environment["DICTIONARY_MODEL"] != nil
        let saved = savedModel.flatMap { Self.validModel($0) ? $0 : nil }
        model = environment["DICTIONARY_MODEL"] ?? (isActive ? saved ?? Self.defaultModel : "claude-haiku-4-5-20251001")
    }

    static func validModel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || "._:/-".unicodeScalars.contains($0)
        }
    }

    static func matches(_ requested: String, _ installed: String) -> Bool {
        func canonical(_ name: String) -> String {
            name.split(separator: "/").last?.contains(":") == true ? name : name + ":latest"
        }
        return canonical(requested) == canonical(installed)
    }
}

@MainActor
final class LocalModelSettings: ObservableObject {
    enum Status { case unchecked, available, missingModel, unavailable, timedOut, invalidResponse }
    let configuration: LocalModelConfiguration
    @Published private(set) var status: Status = .unchecked
    @Published private(set) var isChecking = false
    @Published private(set) var models: [String] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var savedModel: String?
    @Published var selectedModel = ""
    private let probe: any OllamaModelListing
    private let persistModel: (String) -> Void

    init(configuration: LocalModelConfiguration, savedModel: String?, probe: any OllamaModelListing = OllamaModelListClient(),
         persistModel: @escaping (String) -> Void) {
        self.configuration = configuration
        self.savedModel = savedModel.flatMap { LocalModelConfiguration.validModel($0) ? $0 : nil }
        self.probe = probe
        self.persistModel = persistModel
    }

    var canEdit: Bool { configuration.isActive && !configuration.environmentOverride }
    var restartRequired: Bool {
        canEdit && savedModel.map { !LocalModelConfiguration.matches($0, configuration.model) } == true
    }
    var canSave: Bool {
        canEdit && !isChecking && LocalModelConfiguration.validModel(selectedModel) &&
            models.contains(selectedModel) && selectedModel != savedModel
    }
    var statusMessage: String {
        if isChecking { return "正在检查本地 Ollama…" }
        switch status {
        case .unchecked: return "尚未检查。打开设置不会发送请求。"
        case .available: return "已发现当前本地模型，尚未验证翻译效果。"
        case .missingModel: return "已连接 Ollama，但未找到当前本地模型。请选择已安装的模型，或在 Ollama 中安装。"
        case .unavailable: return "无法连接本地 Ollama。请打开 Ollama 后重新检查。"
        case .timedOut: return "Ollama 在 5 秒内未响应。请确认它已运行后重试。"
        case .invalidResponse: return "无法读取模型列表，模型设置未改变。"
        }
    }

    func check() async {
        guard configuration.isActive, !isChecking else { return }
        isChecking = true
        models = []; selectedModel = ""; checkedAt = nil
        defer { isChecking = false }
        do {
            let names = try await probe.models()
            try Task.checkCancellation()
            models = names
            let preferred = savedModel ?? configuration.model
            selectedModel = names.first { LocalModelConfiguration.matches(preferred, $0) } ?? ""
            status = names.contains { LocalModelConfiguration.matches(configuration.model, $0) } ? .available : .missingModel
            checkedAt = .now
        } catch is CancellationError { status = .unchecked }
        catch let error as OllamaServiceError {
            switch error {
            case .unreachable: status = .unavailable
            case .timedOut: status = .timedOut
            case .invalidResponse: status = .invalidResponse
            }
        } catch { status = .unavailable }
    }

    @discardableResult
    func saveSelection() -> Bool {
        guard canSave else { return false }
        persistModel(selectedModel)
        savedModel = selectedModel
        return true
    }
}
