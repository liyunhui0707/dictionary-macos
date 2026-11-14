import AppKit
import SwiftUI

struct GettingStartedView: View {
    @ObservedObject var service: LookupServiceSettings
    @ObservedObject var local: LocalModelSettings
    @ObservedObject var readiness: AppReadiness
    @ObservedObject var progress: FirstLookupProgress
    let onService: () -> Void
    let onLocal: () -> Void
    let onPermission: () -> Void
    let onExample: () -> Void
    @State private var exportMessage = ""
    @State private var browserReading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完成第一次语境查词").font(.system(size: 18, weight: .medium))
            Text("选择服务 → 主窗口查询 → 阅读软件选词。进度仅记录本次打开后的实际操作，不会自动查询或发送文字。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            Text(nextStep).foregroundStyle(DictionaryStyle.accent)
            if progress.isComplete {
                Label("本次首查自测已完成", systemImage: "checkmark.circle")
                    .foregroundStyle(DictionaryStyle.accent).accessibilityIdentifier("first-lookup-complete")
                Text("你已核对一项阅读场景。其他软件和文档仍需分别核对，AI 释义不保证每次正确。")
            }
            DictionaryCard {
                Text("1 · 选择查词服务").font(.system(size: 14, weight: .medium))
                Text(service.needsSetup ? "尚未选择可用的查词方式。" : "当前：\(service.label)；实际查询仍需下面的自测。")
                    .accessibilityIdentifier("first-lookup-service")
                if service.needsSetup {
                    Text("DeepSeek 需要自己的密钥、网络和用量额度；Ollama 将文字留在本机，需要另行安装服务和模型。")
                }
                Button(service.needsSetup ? "选择查词服务" : "更改查词服务", action: onService)
                if service.selected == .local && !service.isManaged {
                    Text("上次检查：\(local.statusMessage)").accessibilityIdentifier("first-lookup-local-status")
                    HStack {
                        Button("检查本地服务与模型") { Task { await local.check() } }.disabled(local.isChecking)
                        Button("准备或更换模型", action: onLocal)
                    }
                    if local.restartRequired { Text("模型选择已更改，重新打开 Dictionary 后生效。") }
                    if LocalModelConfiguration.matches(local.configuration.model, LocalModelConfiguration.defaultModel) {
                        DisclosureGroup("默认本地模型有已知误译") {
                            Text("部分搭配和语法词仍可能误译。请核对词义；质量优先时可自行选择 DeepSeek，云端会发送语境并产生费用。")
                                .foregroundStyle(DictionaryStyle.secondary).padding(.top, 6)
                        }
                    }
                }
            }
            DictionaryCard {
                Text("2 · 在主窗口完成一次语境查询").font(.system(size: 14, weight: .medium))
                Text(checkMessage(progress.manual)).accessibilityIdentifier("first-lookup-manual-status")
                Button("在主窗口准备样例", action: onExample).accessibilityIdentifier("prepare-lookup-example")
                Text("只填入 bank 与河流句子，不自动提交或覆盖已有输入。点击“查词”后，应得到“河岸”；请自行核对。云端查询按服务商用量计费。")
                if progress.manual == .failed || progress.manual == .noMeaning {
                    Button("检查查词服务", action: onService)
                }
            }
            DictionaryCard {
                Text("3 · 在阅读软件核对选词和原句").font(.system(size: 14, weight: .medium))
                Text(progress.readingConfirmed ? "已由你确认本次选词、原句和词义对应。" : checkMessage(progress.reading))
                    .accessibilityIdentifier("first-lookup-reading-status")
                Toggle("我主要在 Chrome、Edge 或 Brave 中阅读", isOn: $browserReading).toggleStyle(.checkbox)
                if browserReading { browserInstructions }
                else {
                    Text("Books、Readest、Markdown 等：选中正文英文，按 ⌥D。\(readiness.permissionLabel)；语境是否可读取还取决于软件和文档。")
                    Button("查看选词权限", action: onPermission)
                }
                Link("打开浏览器查词样例", destination: FirstLookupProgress.readingSampleURL)
                Text("主窗口查询成功不代表阅读软件已接通。浮窗里的选词、原句和词义都对应时，再确认；网页内的说明不算查词结果。")
                HStack {
                    Button("我已核对，原句和词义正确") { progress.confirmReading() }
                        .disabled(!progress.canConfirmReading).accessibilityIdentifier("confirm-first-reading")
                    if progress.reading == .responseReceived {
                        Button("原句或词义不符") { progress.rejectReading() }
                    }
                }
            }
            DictionaryCard {
                Text("遇到问题时").font(.system(size: 14, weight: .medium))
                Text("无弹窗：检查实际快捷键、扩展配对及站点是否允许扩展。\n有弹窗但查询失败：检查查词服务、模型或云端额度。\n单词正确但原句缺失：补充原句或换一段正文；不要反复重置权限。")
                Link("安装、升级与回退指南", destination: URL(string: "https://github.com/liyunhui0707/dictionary-macos/blob/main/docs/guide.md")!)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private var nextStep: String {
        if service.needsSetup { return "下一步：选择查词服务。" }
        if service.selected == .local && local.restartRequired { return "下一步：重新打开 Dictionary，让已选模型生效。" }
        if progress.isComplete { return "可以开始阅读；换一个软件时，再核对一次原句。" }
        if progress.manual != .responseReceived && service.selected == .local && [.missingModel, .unavailable, .timedOut].contains(local.status) {
            return "下一步：准备本地服务与模型，再重新检查。"
        }
        if progress.manual != .responseReceived { return "下一步：在主窗口准备样例，并主动点击查词。" }
        return progress.reading == .responseReceived ? "下一步：核对最近一次浮窗的原句和词义，再确认。" : "下一步：在阅读软件中选词并按 ⌥D。"
    }

    private var browserInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出配套扩展到固定文件夹。在浏览器扩展管理页开启开发者模式，选择“加载已解压的扩展”，打开导出的文件夹。")
            Button("导出配套浏览器扩展…", action: exportExtension).accessibilityIdentifier("export-browser-extension")
            if !exportMessage.isEmpty { Text(exportMessage).textSelection(.enabled) }
            Text("只启用一个 Dictionary Lookup，并只运行一个 Dictionary。菜单栏图标 → Copy extension token；亲自粘贴到扩展并验证保存。不要分享令牌。")
            Text("扩展面板应显示“已连接”和实际快捷键；未绑定时，在浏览器的扩展键盘快捷方式中设置 ⌥D。")
            Text("浏览器扩展查词不要求系统选词权限。若此站点禁止扩展，在浏览器扩展菜单确认站点设置。App 更新不会自动更新已加载的扩展。")
        }
    }

    private func checkMessage(_ check: FirstLookupProgress.Check) -> String {
        switch check {
        case .notStarted: "尚未完成实际查询。"
        case .querying: "正在查询，等待服务响应…"
        case .responseReceived: "已收到包含原句的释义。仍需核对原句与词义，服务响应不代表 AI 判断正确。"
        case .needsContext: "尚未取得对应原句。请补充完整语境，或在可读取的正文中重新选词；若结果不对应，请勿确认完成。"
        case .needsReview: "尚未通过你的核对。原句不符时重新选词或补充语境；原句正确但词义错误时，可更换查词服务，不要因此重置选词权限。"
        case .noMeaning: "没有可用释义。请检查服务或更换查词方式后重试。"
        case .failed: "本次查询未完成。请查看查询结果中的错误，检查连接、模型或云端额度后重试。"
        case .cancelled: "本次查询已取消，可以重新准备样例或选词。"
        }
    }

    private func exportExtension() {
        let panel = NSOpenPanel()
        panel.title = "选择扩展的固定存放位置"
        panel.message = "将创建 Dictionary Browser Extension 文件夹。不会覆盖已有目录或安装浏览器扩展。请勿在加载后移动它。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let destination = try BrowserExtensionExport.export(source: Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"), parent: parent)
            exportMessage = "已导出：\(destination.path)\n在浏览器加载此文件夹；更新前保留旧目录以便回退。"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { exportMessage = error.localizedDescription }
    }
}
