import Foundation

/// A read-only decision. Rendering guidance must never perform setup or a query.
struct FirstLookupGuidance {
    struct State {
        var needsService = false
        var local = true
        var restartRequired = false
        var status: LocalModelSettings.Status = .unchecked
        var checking = false
        var checkedAt: Date?
        var responseAt: Date?
        var manual: FirstLookupProgress.Check = .notStarted
        var reading: FirstLookupProgress.Check = .notStarted
        var complete = false
        var route: ReadingSetupRoute = .browser
        var extensionPrepared = false
        var permission: AppReadiness.Permission = .unchecked
        var booksScreenEnabled = false
        var screenPermission = false
    }

    enum Action: Equatable {
        case service, checkLocal, localModel, example, permissions, prepareExtension, browserSample

        var label: String {
            switch self {
            case .service: "查看查词服务"
            case .checkLocal: "检查本地服务与模型"
            case .localModel: "查看本地模型设置"
            case .example: "在主窗口准备样例"
            case .permissions: "查看选词与屏幕语境设置"
            case .prepareExtension: "准备浏览器扩展"
            case .browserSample: "打开浏览器查词样例"
            }
        }
    }
    let message: String
    let action: Action?

    static func message(_ state: State) -> String { resolve(state).message }

    static func resolve(_ s: State) -> FirstLookupGuidance {
        func step(_ message: String, _ action: Action? = nil) -> FirstLookupGuidance {
            FirstLookupGuidance(message: message, action: action)
        }
        if s.needsService { return step("下一步：选择查词服务。", .service) }
        if s.local && s.restartRequired {
            return step("下一步：重新打开 Wordlit，让已选模型生效；当前仍使用启动时的模型。", .localModel)
        }
        if s.checking || s.manual == .querying || s.reading == .querying {
            return step("正在处理，请等待当前检查或查询完成。")
        }
        // A later real response can recover an old failed probe. A newer explicit
        // failed probe must not be hidden by an earlier successful self-test.
        let probeIsCurrent = s.checkedAt.map { $0 >= (s.responseAt ?? .distantPast) } ?? (s.responseAt == nil)
        if s.local && probeIsCurrent {
            switch s.status {
            case .missingModel:
                return step("已连接 Ollama，但缺少当前模型。下一步：选择已安装模型，或自行在 Ollama 中准备模型。", .localModel)
            case .unavailable:
                return step("无法连接本地服务。下一步：打开 Ollama，再检查服务与模型。", .checkLocal)
            case .timedOut:
                return step("本地服务检查超时。下一步：确认 Ollama 已运行，再检查一次。", .checkLocal)
            case .invalidResponse:
                return step("无法读取 Ollama 模型列表。下一步：检查服务地址与 Ollama 状态；模型选择未改变。", .localModel)
            case .unchecked:
                if s.manual == .notStarted { return step("下一步：检查本地服务与模型；此检查不会查词或下载模型。", .checkLocal) }
            case .available: break
            }
        }
        if s.complete { return step("可以开始阅读；换一个软件时，再核对一次原句。") }
        if s.manual != .responseReceived {
            switch s.manual {
            case .noMeaning:
                return step("模型已响应，但没有可用释义。下一步：核对输入，或更换模型／查词服务；无需调整选词权限。", s.local ? .localModel : .service)
            case .failed:
                return step("本次查询失败。下一步：查看结果中的错误，再检查服务、模型或云端额度。", s.local ? .checkLocal : .service)
            case .needsContext:
                return step("查询缺少完整原句。下一步：在主窗口补充语境后主动查词。", .example)
            default:
                return step("下一步：在主窗口准备样例，并主动点击查词。", .example)
            }
        }
        switch s.reading {
        case .responseReceived: return step("下一步：核对最近一次浮窗的原句和词义，再确认。")
        case .noMeaning:
            return step("模型已响应，但没有可用释义。原句正确时可更换模型／服务，无需重置选词权限。", s.local ? .localModel : .service)
        case .needsContext:
            return step("选词已取得，但原句缺失。请补充原句；Books 可在设置中开启屏幕语境并核对预览。", s.route == .books ? .permissions : .example)
        case .needsReview:
            return step("原句不符时重新选词或补充语境；原句正确而词义错误时更换模型／服务，不要重置权限。", .service)
        case .failed:
            return step("本次阅读查询失败。请先查看浮窗错误，区分选词失败和服务错误，再按对应提示处理。")
        default: break
        }
        if s.route == .browser {
            return s.extensionPrepared
                ? step("下一步：在扩展面板核对加载、配对与实际快捷键，再用浏览器样例查词；文件已准备不代表已连接。", .browserSample)
                : step("下一步：准备浏览器扩展，再在浏览器加载、配对并检查快捷键。", .prepareExtension)
        }
        if s.permission != .granted {
            return step("下一步：在通用设置检查选词权限，按系统提示正常授权。", .permissions)
        }
        if s.route == .books && s.booksScreenEnabled && !s.screenPermission {
            return step("Books 屏幕语境已开启，但屏幕权限尚未开启。请在设置中检查，或关闭此可选路径。", .permissions)
        }
        return step("下一步：在阅读软件中选词并按 ⌥D，核对取得的原句。")
    }
}
