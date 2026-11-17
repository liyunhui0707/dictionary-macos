import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SupportDiagnosticsView: View {
    @ObservedObject var support: SupportDiagnostics
    @ObservedObject var service: LookupServiceSettings
    @ObservedObject var local: LocalModelSettings
    @ObservedObject var readiness: AppReadiness
    let onService: () -> Void
    let onLocal: () -> Void
    let onPermission: () -> Void
    private struct ReportSnapshot: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var preview: ReportSnapshot?
    @State private var preparationFailed = false
    static let feedbackURL = URL(string: "https://github.com/liyunhui0707/dictionary-macos/issues/new?template=bug_report.yml")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("查清原因，再继续阅读").font(.system(size: 18, weight: .medium))
            Text("这里只记录本次打开后的状态。打开页面不会访问密钥、检查网络、发起查词或上传信息。")
                .foregroundStyle(DictionaryStyle.secondary)
            DictionaryCard {
                Text("查词服务").font(.system(size: 14, weight: .medium))
                Text("当前：\(service.label)")
                if service.selected == .local && !service.isManaged {
                    Text("上次检查：\(local.statusMessage)")
                    if local.restartRequired { Text("模型选择需重新打开 App 后生效。") }
                    HStack {
                        Button("检查本地服务与模型") { Task { await local.check() } }.disabled(local.isChecking)
                        Button("本地模型设置", action: onLocal)
                    }
                }
                Button("查词服务设置", action: onService)
            }
            DictionaryCard {
                Text("阅读软件接入").font(.system(size: 14, weight: .medium))
                Text(readiness.permissionLabel)
                Text("原生选词使用此权限；手动输入和浏览器扩展不要求它。")
                    .foregroundStyle(DictionaryStyle.secondary)
                Button("查看选词权限", action: onPermission)
                Text(hotkeyMessage)
                Text("注册记录不代表按键已触发。Dictionary 在前台时暂停原生快捷键；浏览器与配套插件使用各自的查词入口。")
                    .foregroundStyle(DictionaryStyle.secondary)
                Divider()
                Text(listenerMessage).accessibilityIdentifier("support-listener-status")
                Text(support.authenticatedCheckSeen ? "本次曾收到通过认证的连接检查。" : "本次尚未收到通过认证的连接检查。")
                    .accessibilityIdentifier("support-connection-status")
                Text(support.extensionLookupSeen ? "本次曾收到有效的扩展查询请求。" : "本次尚未收到有效的扩展查询请求。")
                Text("这些是到达 App 的历史记录，不代表扩展当前仍连接，也不能判断是否已安装、绑定快捷键或获准访问当前网页。请在扩展面板检查实际快捷键和连接；不要反复重置系统权限。")
                    .foregroundStyle(DictionaryStyle.secondary)
            }
            DictionaryCard {
                Text("最近一次主查词").font(.system(size: 14, weight: .medium))
                lookup("主窗口", support.manual)
                Divider()
                lookup("阅读选词", support.selection)
                Text("这里只显示主查词与选词尝试；单独“询问 DeepSeek”的辅助结果请回原查询窗口查看。")
                    .foregroundStyle(DictionaryStyle.secondary)
                Text("原句不对应或缺失属于捕获问题；原句正确而词义不符时，才考虑解释服务或模型能力。此页不自动判断词义质量。")
                    .foregroundStyle(DictionaryStyle.secondary)
            }
            DictionaryCard {
                Text("诊断与反馈").font(.system(size: 14, weight: .medium))
                Text("先预览再保存。报告只含版本、服务类别、权限和固定状态码，不包含选词、正文、回答、密钥、令牌、个人路径或机器信息。不会自动提交 GitHub 问题。")
                Button("预览诊断报告…") {
                    do {
                        let text = try support.report(version: readiness.version, service: service, local: local, readiness: readiness).text()
                        preparationFailed = false
                        preview = ReportSnapshot(text: text)
                    } catch { preparationFailed = true }
                }.accessibilityIdentifier("preview-support-report")
                if preparationFailed { Text("暂时无法生成报告，请稍后重试。") }
                Link("到 GitHub 反馈", destination: Self.feedbackURL)
                Text("日常反馈记下“哪个软件、选了什么、哪里不对”即可，能用合成例句复现更好。无需先重复验收；版本和诊断报告可稍后补充。分享截图前遮住私人内容，不要提交密钥、完整书籍或聊天记录。")
                    .foregroundStyle(DictionaryStyle.secondary)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .sheet(item: $preview) { report in SupportReportPreview(text: report.text) }
    }

    private func lookup(_ title: String, _ value: SupportLookup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            Text(value.summary)
            if let issue = value.issue { Text(issue.guidance).foregroundStyle(DictionaryStyle.secondary) }
        }
    }
    private var listenerMessage: String {
        switch support.listener {
        case .starting: "本机扩展连接服务正在启动，尚未确认就绪。"
        case .listening: "本机扩展连接服务已就绪。"
        case .unavailable: "本机扩展连接服务不可用。确认只运行一个 Dictionary；端口占用或服务启动失败会阻止扩展连接。"
        case .stopped: "本机扩展连接服务尚未启动或已停止。"
        }
    }
    private var hotkeyMessage: String {
        switch support.nativeHotkeyRegistration {
        case .unchecked: "本次尚无原生快捷键注册记录。"
        case .registered: "最近一次原生快捷键注册成功。"
        case .failed: "最近一次原生快捷键注册失败。检查快捷键冲突，并确认只运行一个 Dictionary。"
        }
    }
}

struct SupportReportPreview: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var saveMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("预览诊断报告").font(.headline)
            Text("保存到你选择的位置；分享与提交由你决定。报告是此刻的快照。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(minHeight: 120, maxHeight: 270).background(DictionaryStyle.surface)
                .accessibilityIdentifier("support-report-preview")
            if !saveMessage.isEmpty { Text(saveMessage).font(.system(size: 12)) }
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                Button("保存文本…", action: save).accessibilityIdentifier("save-support-report")
            }
        }.padding(24).frame(width: 480).background(DictionaryStyle.paper)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "保存诊断报告"
        panel.nameFieldStringValue = "Dictionary-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saveMessage = "诊断报告已保存。分享前请自行检查。"
        } catch { saveMessage = "未能保存报告，请选择可写的位置重试。" }
    }
}
