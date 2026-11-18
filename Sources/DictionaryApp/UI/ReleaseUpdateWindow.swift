import AppKit
import SwiftUI

@MainActor
final class ReleaseUpdateWindow: NSWindowController, NSWindowDelegate {
    private let updates: ReleaseUpdates
    init(installed: String) {
        updates = ReleaseUpdates(installed: installed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Wordlit · 检查更新"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ReleaseUpdateView(updates: updates))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func open() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        updates.check()
    }
    func windowWillClose(_ notification: Notification) { updates.cancel() }
}

struct ReleaseUpdateView: View {
    @ObservedObject var updates: ReleaseUpdates
    let architecture: ReleaseArchitecture?
    init(updates: ReleaseUpdates, architecture: ReleaseArchitecture? = .current) {
        self.updates = updates; self.architecture = architecture
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) { DictionaryMark(); Text("Wordlit").font(.title2) }
            Text("当前版本 \(updates.installed) · \(architecture?.label ?? "芯片未识别")")
                .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    status
                    ManualUpdateGuide()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("仅在打开此窗口或点击检查时查询公开版本。下载由你在浏览器中发起，App 不会自动下载或安装。")
                .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新检查") { updates.check() }.disabled(updates.state == .checking)
                Spacer()
                Link("全部版本与回退下载 ↗", destination: PublicRelease.downloads)
            }.font(.system(size: 12))
        }.padding(24).frame(width: 560, height: 560)
            .background(DictionaryStyle.paper).foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
    }

    @ViewBuilder private var status: some View {
        switch updates.state {
        case .idle: Text("点击下方按钮查询公开发行版本。")
        case .checking: HStack { ProgressView().controlSize(.small); Text("正在检查 GitHub Releases…") }
        case .current(let release):
            Text("你使用的版本与当前公开稳定版一致。")
            releaseDetails(release, offerDownload: true)
        case .available(let release):
            Text("新版本 \(release.version) 已发布。")
            releaseDetails(release, offerDownload: true)
        case .ahead(let release):
            Text("当前版本高于公开稳定版 \(release.version)。如需回退，请先阅读兼容说明并保留当前安装包。")
            releaseDetails(release, offerDownload: false)
        case .noRelease: Text("尚无公开稳定版本。请稍后查看下载页面。")
        case .failed: Text("暂时无法检查更新。请检查网络后重试，或打开全部版本页面。")
        case .unversioned: Text("无法确定当前构建的版本，请打开全部版本页面核对。")
        }
    }

    private func releaseDetails(_ release: PublicRelease, offerDownload: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if offerDownload {
                if let architecture {
                    let dmg = release.installer(for: architecture, format: .dmg)
                    let zip = release.installer(for: architecture, format: .zip)
                    if dmg != nil || zip != nil {
                        Text("此版本的 \(architecture.label) 安装包")
                        HStack {
                            if let dmg { Link("下载 DMG ↗", destination: dmg.url) }
                            if let zip { Link("下载 ZIP ↗", destination: zip.url) }
                            if let checksums = release.checksums { Link("下载校验值 ↗", destination: checksums) }
                        }
                        Text("安装前请阅读该版本的系统要求及签名、公证说明。校验值用于核对文件完整性，不是开发者身份认证。")
                            .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary)
                    } else {
                        Text("此版本未提供可确认的 \(architecture.label) 安装包，请到全部版本页面核对；不要安装另一种芯片的包。")
                            .font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    }
                } else {
                    Text("无法识别此电脑的芯片，请在发行页自行核对安装包。")
                }
            }
            if !release.notes.isEmpty {
                DisclosureGroup("版本说明") {
                    // Release prose is text, never interpreted as HTML or actionable Markdown.
                    Text(verbatim: release.notes).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Link("查看完整版本说明 ↗", destination: release.url)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ManualUpdateGuide: View {
    var body: some View {
        DictionaryCard {
            Text("更新与回退").fontWeight(.medium)
            Text("1 · 更新前记下当前版本与查词方式，保留旧安装包和已加载的扩展目录。")
            Text("2 · 下载适合芯片的新版，退出 Wordlit 后替换“应用程序”中的 App，再从那里启动。保持一个日常入口。")
            Text("3 · 打开“开始使用”核对原句和释义。App 与浏览器扩展分别更新；扩展有变化时，保留旧目录并按指南导出、加载新版。")
            Text("4 · 新版出现问题时，先查看“诊断与反馈”。需要回退则退出新版，从全部版本下载适合芯片的旧包，按相同方式替换；先阅读该版本的兼容说明。")
            Text("不要为升级清空设置、钥匙串密钥、模型或系统权限。临时签名的公开安装包更新后可能需要正常重新授权。")
                .foregroundStyle(DictionaryStyle.secondary)
            Link("查看更新与回退指南 ↗", destination: URL(string: "https://github.com/liyunhui0707/dictionary-macos/blob/main/docs/guide.md#更新与回退")!)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}
