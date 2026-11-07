import AppKit
import SwiftUI

@MainActor
final class ReleaseUpdateWindow: NSWindowController, NSWindowDelegate {
    private let updates: ReleaseUpdates
    init(installed: String) {
        updates = ReleaseUpdates(installed: installed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dictionary · 检查更新"
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) { DictionaryMark(); Text("Dictionary").font(.title2) }
            Text("当前版本 \(updates.installed)").font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            Group {
                switch updates.state {
                case .idle: Text("点击下方按钮查询公开发行版本。")
                case .checking: HStack { ProgressView().controlSize(.small); Text("正在检查 GitHub Releases…") }
                case .current: Text("你使用的版本已是最新。")
                case .available(let release):
                    Text("新版本 \(release.version) 已发布。")
                    Link("查看版本并下载", destination: release.url)
                case .noRelease: Text("尚无公开发行版本。请稍后查看下载页面。")
                case .failed: Text("暂时无法检查更新。请检查网络后重试，或打开下载页面。")
                case .unversioned: Text("无法确定当前构建的版本，请打开下载页面核对。")
                }
            }.font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("仅在点击时检查版本；不会自动下载或安装。更新前请退出应用，再替换应用程序中的 Dictionary。")
                .font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新检查") { updates.check() }.disabled(updates.state == .checking)
                Spacer()
                Link("全部版本与下载 ↗", destination: PublicRelease.downloads)
            }.font(.system(size: 12))
        }.padding(24).frame(width: 460, height: 300)
            .background(DictionaryStyle.paper).foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
    }
}
