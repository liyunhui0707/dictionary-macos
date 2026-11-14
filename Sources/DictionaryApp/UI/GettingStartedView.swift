import AppKit
import SwiftUI

struct GettingStartedView: View {
    let onService: () -> Void
    let onLocal: () -> Void
    let onPermission: () -> Void
    let onExample: () -> Void
    @State private var exportMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("完成第一次语境查词").font(.system(size: 18, weight: .medium))
            Text("先确认查词服务，再接入你的阅读软件。各项检查互相独立，不会自动下载模型、调用收费 API 或更改系统权限。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            DictionaryCard {
                Text("1 · 选择查词服务").font(.system(size: 14, weight: .medium))
                Text("DeepSeek 需要自己的密钥和用量额度；Ollama 需要另行安装并启动服务、准备模型。保存设置不代表查询已成功。")
                HStack { Button("选择查词服务", action: onService); Button("检查本地模型", action: onLocal) }
            }
            DictionaryCard {
                Text("2 · 接入阅读软件").font(.system(size: 14, weight: .medium))
                Text("Chrome、Edge、Brave：导出此版本配套的扩展到固定文件夹，在浏览器扩展管理页加载解压缩扩展。更新 App 不会自动更新已加载的扩展。")
                Button("导出配套浏览器扩展…", action: exportExtension).accessibilityIdentifier("export-browser-extension")
                if !exportMessage.isEmpty { Text(exportMessage).textSelection(.enabled) }
                Text("只启用一个 Dictionary Lookup，并只运行一个 Dictionary。菜单栏图标 → Copy extension token；由你将令牌粘贴到扩展，验证保存。不要把令牌分享给他人。")
                Text("扩展面板应显示已连接，并有实际快捷键。未绑定时，在浏览器扩展的键盘快捷方式中设置 ⌥D。内部页面与受保护页面不支持。")
                Divider()
                Text("Books、Readest 等原生软件：需要选词权限；可读取的语境取决于软件和文档。浏览器扩展查词和手动输入不要求此权限。")
                Button("查看选词权限", action: onPermission)
            }
            DictionaryCard {
                Text("3 · 做一次合成样例自测").font(.system(size: 14, weight: .medium))
                Text("先用主窗口样例确认服务可查询，再在阅读软件里选词并按 ⌥D，核对浮窗中的原句。手动查询成功不代表阅读软件接入成功。")
                Button("在主窗口准备样例", action: onExample).accessibilityIdentifier("prepare-lookup-example")
                Text("样例只填入 bank 与河流句子，不自动提交。已有输入或正在查询时不会覆盖。云端查询仍需你主动点击“查词”，并按服务商用量计费。")
            }
            DictionaryCard {
                Text("遇到问题时").font(.system(size: 14, weight: .medium))
                Text("无弹窗：检查扩展快捷键、配对及是否有另一 App 占用端口。\n有弹窗但查询失败：检查查词服务。\n单词正确但原句缺失：属于语境获取问题，可补充原句；不要因此反复重置权限。")
                Link("安装、升级与回退指南", destination: URL(string: "https://github.com/liyunhui0707/dictionary-macos/blob/main/docs/guide.md")!)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
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
