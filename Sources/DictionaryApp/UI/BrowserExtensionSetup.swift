import Foundation
import Combine

/// Preparation is a file state, not browser pairing or successful lookup evidence.
/// Only the last folder is persisted; it is revalidated against this App's bundle.
@MainActor
final class BrowserExtensionSetup: ObservableObject {
    static let preference = "Dictionary.BrowserExtension.preparedDirectory"
    static var defaultParent: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DictionaryApp/BrowserExtensions", isDirectory: true)
    }
    @Published private(set) var prepared: BrowserExtensionExport.Prepared?
    @Published private(set) var version: String?
    @Published private(set) var message = "尚未准备浏览器扩展。"
    private let source: URL?
    private let managedParent: URL
    private var savedDirectory: URL?
    private let persist: (URL) -> Void

    init(source: URL? = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
         managedParent: URL? = nil, savedDirectory: URL? = nil,
         persist: @escaping (URL) -> Void = { _ in }) {
        self.source = source; self.managedParent = managedParent ?? Self.defaultParent
        self.savedDirectory = savedDirectory; self.persist = persist
    }

    func refresh() {
        prepared = nil
        do { version = try BrowserExtensionExport.bundledVersion(source: source) }
        catch { version = nil; message = error.localizedDescription; return }
        guard let savedDirectory else { message = "尚未准备配套扩展 \(version!)。"; return }
        do {
            prepared = try BrowserExtensionExport.verify(source: source, directory: savedDirectory)
            message = "配套扩展 \(version!) 的文件已核对。浏览器连接与快捷键仍需在扩展面板检查。"
        } catch {
            message = "上次准备的文件已移动或内容与当前版本不一致，请重新准备；旧文件未被更改。"
        }
    }

    func prepare(in parent: URL? = nil) {
        prepared = nil
        do {
            let result: BrowserExtensionExport.Prepared
            if parent == nil, let savedDirectory,
               let existing = try? BrowserExtensionExport.verify(source: source, directory: savedDirectory) {
                result = existing
            } else {
                result = try BrowserExtensionExport.prepare(source: source, parent: parent ?? managedParent)
            }
            savedDirectory = result.directory; persist(result.directory)
            prepared = result; version = result.version
            message = result.reused ? "已核对并复用配套扩展 \(result.version)。尚未确认浏览器连接。" :
                "配套扩展 \(result.version) 已准备。下一步在浏览器加载此文件夹。"
        } catch { message = error.localizedDescription }
    }
}
