import AppKit
import SwiftUI

enum ReadingSetupRoute: String, CaseIterable {
    case browser = "浏览器", books = "Books", native = "其他阅读软件"
}

struct GettingStartedView: View {
    @ObservedObject var service: LookupServiceSettings
    @ObservedObject var local: LocalModelSettings
    @ObservedObject var readiness: AppReadiness
    @ObservedObject var progress: FirstLookupProgress
    @ObservedObject var extensionSetup: BrowserExtensionSetup
    @ObservedObject var booksScreenSettings: BooksScreenSettings
    @Binding var readingRoute: ReadingSetupRoute
    let onService: () -> Void
    let onLocal: () -> Void
    let onPermission: () -> Void
    let onExample: () -> Void
    let onCopyExtensionToken: () -> Bool
    @State private var pathCopied = false
    @State private var tokenCopied: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("开始使用").font(.system(size: 18, weight: .semibold))
            Text("选中英文，按 ⌥D。单词查看语境释义，句段查看完整译文。")
                .font(.system(size: 13))
            HStack {
                Label(service.needsSetup ? "先配置翻译服务" : service.label,
                      systemImage: service.needsSetup ? "exclamationmark.circle" : "checkmark.circle")
                Spacer()
                Button(service.needsSetup ? "设置服务" : "更改", action: onService)
            }
            if service.selected == .local && !service.isManaged {
                HStack {
                    Text(local.statusMessage).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    Spacer()
                    Button("检查连接") { Task { await local.check() } }.disabled(local.isChecking)
                }
                if local.restartRequired { Text("模型已更改，正常重开 Dictionary 后生效。").font(.caption) }
            }
            Divider()
            Picker("阅读软件", selection: $readingRoute) {
                ForEach(ReadingSetupRoute.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("reading-setup-route")
            if readingRoute == .browser {
                browserInstructions
            } else {
                nativePreparationStatus
                Text("选中正文中的单词、短语或句段，按 ⌥D。无法取得语境时仍可查看普通释义，或在主窗口补充原文。")
            }
            Divider()
            DisclosureGroup("试用合成样例 · 可选") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("在主窗口准备样例", action: onExample).accessibilityIdentifier("prepare-lookup-example")
                    Text("仅填入样例，不自动提交或覆盖已有输入。")
                    Link("打开浏览器样例", destination: FirstLookupProgress.readingSampleURL)
                }.font(.system(size: 12)).padding(.top, 8)
            }
            Text("AI 结果可能有误。遇到问题可到“帮助”查看诊断或反馈，无需重复完成样例。")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }

    private var nativePreparationStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(readiness.permissionLabel).accessibilityIdentifier("reading-selection-permission")
            if readingRoute == .books {
                Text(!booksScreenSettings.enabled ? "Books 屏幕语境未开启，当前只使用普通选词路径。" :
                    booksScreenSettings.permissionGranted ? "Books 屏幕语境已开启；自动使用策略可在阅读与权限中调整。" :
                    "Books 屏幕语境已开启，但屏幕录制权限尚未开启。")
                    .accessibilityIdentifier("books-preparation-status")
                Button("查看选词与 Books 屏幕语境设置", action: onPermission)
            } else {
                Button("查看选词权限", action: onPermission)
            }
            Text("权限开启后，语境是否可读取仍取决于阅读软件与文档。")
                .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
        }
    }

    private var browserInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chrome / Edge / Brave").font(.system(size: 13, weight: .medium))
            HStack {
                Button("准备浏览器扩展") { extensionSetup.prepare(); pathCopied = false }
                    .accessibilityIdentifier("prepare-browser-extension")
                Menu("更多") { Button("选择其他位置…", action: exportExtension) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Text(extensionSetup.message).font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                .accessibilityIdentifier("browser-extension-preparation-status")
            if extensionSetup.prepared != nil {
                Text("1. 在浏览器扩展管理页开启开发者模式，加载这个文件夹。")
                HStack {
                    Button("显示文件夹", action: revealExtension)
                    Button(pathCopied ? "已复制路径" : "复制路径") {
                        extensionSetup.refresh()
                        if let current = extensionSetup.prepared {
                            NSPasteboard.general.clearContents()
                            pathCopied = NSPasteboard.general.setString(current.directory.path, forType: .string)
                        }
                    }.accessibilityIdentifier("copy-browser-extension-path")
                }
                Text("2. 打开 Dictionary Lookup，粘贴配对令牌并验证保存。")
                Button("复制配对令牌") { tokenCopied = onCopyExtensionToken() }
                    .accessibilityIdentifier("copy-extension-pairing-token")
                if let tokenCopied { Text(tokenCopied ? "已复制，请亲自粘贴到扩展。" : "未能复制，请重试。") }
                Text("3. 在浏览器扩展快捷方式中设置 ⌥D，确认扩展显示已连接。")
            }
            DisclosureGroup("安装与隐私说明") {
                Text("扩展需手动加载和配对，浏览器限制使应用无法代装。文件夹路径可在浏览器的选择窗口中按 ⇧⌘G 后粘贴。只启用一个 Dictionary Lookup，并只运行一个 Dictionary；不要分享令牌。浏览器扩展不需要系统选词权限，部分站点会限制扩展。更新 App 后需手动更新已加载扩展，旧目录可保留用于回退。")
                    .padding(.top, 6)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private func revealExtension() {
        extensionSetup.refresh()
        if let current = extensionSetup.prepared { NSWorkspace.shared.activateFileViewerSelecting([current.directory]) }
    }

    private func exportExtension() {
        let panel = NSOpenPanel()
        panel.title = "选择扩展的固定存放位置"
        panel.message = "App 会在所选位置里面创建按扩展版本命名的文件夹。同版本内容一致时直接复用；不会覆盖已有文件或安装浏览器扩展。请勿在加载后移动它。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        extensionSetup.prepare(in: parent)
        pathCopied = false
    }
}
