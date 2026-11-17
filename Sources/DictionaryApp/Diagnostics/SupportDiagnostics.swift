import Combine
import Foundation

enum LocalListenerState: String, Codable, Sendable { case starting, listening, unavailable, stopped }

/// Fixed categories only. Never retain an Error, its message, a request, or provider output.
enum SupportIssue: String, Codable {
    case setupRequired, credentialsUnavailable, connectionFailed, timedOut, authenticationRejected
    case accountOrRateLimit, modelOrEndpointUnavailable, serviceRejected, invalidResponse
    case noMeaning, captureUnavailable, permissionRequired, sourceChanged, clipboardRestoreFailed, unknown

    static func classify(_ error: Error) -> Self {
        if error is LookupServiceSetupError { return .setupRequired }
        if let error = error as? CloudAssistanceError {
            switch error {
            case .notConfigured: return .setupRequired
            case .credentialUnavailable: return .credentialsUnavailable
            case .network: return .connectionFailed
            case .timeout: return .timedOut
            case .invalidResponse: return .invalidResponse
            case .noMeaning: return .noMeaning
            case .http(let status): return http(status)
            }
        }
        if let error = error as? TranslationError {
            switch error {
            case .missingAPIKey: return .credentialsUnavailable
            case .apiError(let status, _): return http(status)
            case .emptyResponse, .unparseableJSON: return .invalidResponse
            }
        }
        if let error = error as? OllamaLookupError {
            switch error {
            case .unavailable: return .connectionFailed
            case .timedOut: return .timedOut
            case .rejected(let status): return http(status)
            case .invalidResponse: return .invalidResponse
            }
        }
        if let error = error as? URLError { return error.code == .timedOut ? .timedOut : .connectionFailed }
        if let failure = error as? CaptureFailure {
            if failure.details.issues.contains(where: { $0.clipboardReason == .restorationFailed }) { return .clipboardRestoreFailed }
            if failure.details.reason == .sourceChanged { return .sourceChanged }
            if failure.details.issues.contains(where: { $0.code == .accessibilityNotTrusted }) { return .permissionRequired }
            return .captureUnavailable
        }
        return .unknown
    }

    private static func http(_ status: Int) -> Self {
        switch status {
        case -1: .connectionFailed
        case 401: .authenticationRejected
        case 402, 429: .accountOrRateLimit
        case 404: .modelOrEndpointUnavailable
        case 408, 504: .timedOut
        default: .serviceRejected
        }
    }

    var guidance: String {
        switch self {
        case .setupRequired: "先在查词服务中选择并配置服务。"
        case .credentialsUnavailable: "到查词服务设置检查密钥配置；不要把密钥放进反馈。"
        case .connectionFailed: "本地模式先打开 Ollama；云端模式检查网络。恢复后主动重试。"
        case .timedOut: "服务未及时响应。稍后重试；本地模型首次加载可能较慢。"
        case .authenticationRejected: "服务拒绝认证，请在服务设置检查账户和密钥。"
        case .accountOrRateLimit: "服务报告账户、额度或限流问题，请到服务商处确认。"
        case .modelOrEndpointUnavailable: "服务未找到模型或接口。本地模式检查已安装模型；云端模式检查服务配置。"
        case .serviceRejected: "服务未接受查询。检查服务状态后再试，不会自动切换另一服务。"
        case .invalidResponse: "服务已响应，但内容格式无效。检查服务配置；反复调整选词权限不能修复响应格式。"
        case .noMeaning: "模型已响应，但没有可用释义。核对输入或更换模型／服务；原句正确不代表词义正确。"
        case .captureUnavailable: "未取得可用选词。重新选中正文；仍失败时可手动输入单词和原句。"
        case .permissionRequired: "原生选词缺少权限。查看当前 App 的选词权限；手动输入和浏览器扩展不要求此权限。"
        case .sourceChanged: "查词期间来源发生变化。回到阅读软件重新选词。"
        case .clipboardRestoreFailed: "复制回退未能恢复剪贴板。先检查并重新复制需要保留的内容，再查词。"
        case .unknown: "原因尚未确定。可导出这份状态报告，并自行描述复现步骤。"
        }
    }
}

struct SupportLookup: Codable, Equatable {
    enum State: String, Codable { case notRun, capturing, querying, responseReceived, missingContext, noMeaning, cancelled, failed }
    var state: State = .notRun
    var issue: SupportIssue? = nil

    var summary: String {
        switch state {
        case .notRun: "本次打开后尚未查询。"
        case .capturing: "正在获取选词。"
        case .querying: "正在等待查词服务。"
        case .responseReceived: "已收到含原句的释义；仍需自行核对词义。"
        case .missingContext: "已收到响应，但没有对应原句。可补充语境；更换模型不能补回未捕获的原文。"
        case .noMeaning: "没有可用释义，或模型只返回了原词。"
        case .cancelled: "本次查询已取消。"
        case .failed: "本次操作未完成。"
        }
    }
}

/// Session-only support state, independent from opt-in QA logs. No automatic I/O.
@MainActor
final class SupportDiagnostics: ObservableObject {
    enum HotkeyRegistration: String, Codable { case unchecked, registered, failed }
    @Published private(set) var manual = SupportLookup()
    @Published private(set) var selection = SupportLookup()
    @Published private(set) var listener: LocalListenerState = .stopped
    @Published private(set) var authenticatedCheckSeen = false
    @Published private(set) var extensionLookupSeen = false
    @Published private(set) var nativeHotkeyRegistration: HotkeyRegistration = .unchecked

    func hotkeyRegistered(_ success: Bool) { nativeHotkeyRegistration = success ? .registered : .failed }

    func listenerChanged(_ state: LocalListenerState) {
        listener = state
        if state != .listening { authenticatedCheckSeen = false; extensionLookupSeen = false }
    }
    func authenticatedCheck() { authenticatedCheckSeen = true }
    func extensionLookup() { extensionLookupSeen = true }
    func resetLookups() { manual = .init(); selection = .init() }
    func begin(_ channel: LookupChannel, capturing: Bool = false) {
        set(.init(state: capturing ? .capturing : .querying), channel)
    }
    func cancelled(_ channel: LookupChannel) { set(.init(state: .cancelled), channel) }
    func cancelCapture() { if selection.state == .capturing { cancelled(.selection) } }
    func captureFailed(_ issue: SupportIssue) { set(.init(state: .failed, issue: issue), .selection) }
    func finished(_ request: LookupRequest, outcome: LookupOutcome, issue: SupportIssue?, channel: LookupChannel) {
        switch outcome {
        case .cancelled: cancelled(channel)
        case .failure: set(.init(state: .failed, issue: issue ?? .unknown), channel)
        case .success(let result):
            if AIMeaningPresentation(target: request.target, answer: result.translation.meaningInContext).notice != nil {
                set(.init(state: .noMeaning, issue: .noMeaning), channel)
            } else {
                set(.init(state: LookupResultPresentation(request: request).sentence == nil ? .missingContext : .responseReceived), channel)
            }
        }
    }
    private func set(_ value: SupportLookup, _ channel: LookupChannel) {
        if channel == .manual { manual = value } else { selection = value }
    }

    struct Report: Encodable {
        enum Service: String, Encodable { case unconfigured, local, cloud, managed }
        enum Permission: String, Encodable { case unchecked, required, granted }
        enum ModelCheck: String, Encodable { case unchecked, available, missingModel, unavailable, timedOut, invalidResponse, notApplicable }
        let schema = 1
        let appVersion: String
        let service: Service
        let permission: Permission
        let localModelCheck: ModelCheck
        let modelRestartRequired: Bool
        let listener: LocalListenerState
        let authenticatedCheckSeen: Bool
        let extensionLookupSeen: Bool
        let nativeHotkeyRegistration: HotkeyRegistration
        let manual: SupportLookup
        let reading: SupportLookup

        func text() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return "Dictionary 诊断报告\n仅为本次 App 会话的固定状态，不证明词义准确或所有软件支持。\n不含选词、正文、模型回答、密钥、令牌、个人路径或机器信息。\n认证检查只表示本次曾收到有效请求，不代表扩展当前仍连接。\n本地模型项是最近一次主动检查的结果，不是持续健康监测。\n\n" + String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
        }
    }

    func report(version: String?, service: LookupServiceSettings, local: LocalModelSettings, readiness: AppReadiness) -> Report {
        let validVersion = version.flatMap { $0.range(of: "^[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        let permission: Report.Permission
        switch readiness.permission { case .unchecked: permission = .unchecked; case .required: permission = .required; case .granted: permission = .granted }
        let provider: Report.Service = service.isManaged ? .managed : service.needsSetup ? .unconfigured : service.selected == .local ? .local : .cloud
        let model: Report.ModelCheck
        if provider != .local { model = .notApplicable }
        else {
            switch local.status {
            case .unchecked: model = .unchecked
            case .available: model = .available
            case .missingModel: model = .missingModel
            case .unavailable: model = .unavailable
            case .timedOut: model = .timedOut
            case .invalidResponse: model = .invalidResponse
            }
        }
        return Report(appVersion: validVersion, service: provider, permission: permission, localModelCheck: model,
            modelRestartRequired: provider == .local && local.restartRequired, listener: listener,
            authenticatedCheckSeen: authenticatedCheckSeen, extensionLookupSeen: extensionLookupSeen,
            nativeHotkeyRegistration: nativeHotkeyRegistration, manual: manual, reading: selection)
    }
}
