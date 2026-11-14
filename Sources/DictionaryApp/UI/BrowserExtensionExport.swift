import Foundation

/// Exports only bundled public code, never the installed browser profile or token.
struct BrowserExtensionExport {
    static let files = ["manifest.json", "content.js", "service-worker.js", "options.html", "options.js",
                        "icons/16.png", "icons/48.png", "icons/128.png"]
    enum Failure: LocalizedError {
        case unavailable, unsafeSource, destinationExists
        var errorDescription: String? {
            switch self {
            case .unavailable: return "当前 App 未包含配套扩展。请使用新版完整安装包。"
            case .unsafeSource: return "配套扩展不完整，未导出。请重新下载完整安装包。"
            case .destinationExists: return "此处已有 Dictionary Browser Extension，未覆盖任何文件。请保留原目录，选择另一个空位置。"
            }
        }
    }
    static func export(source: URL?, parent: URL) throws -> URL {
        guard let source else { throw Failure.unavailable }
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { throw Failure.unavailable }
        func regular(_ url: URL) throws -> Bool {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        for dir in [source, source.appendingPathComponent("icons")] {
            let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unsafeSource }
        }
        var payload: [String: Data] = [:]
        for file in files {
            let url = source.appendingPathComponent(file)
            guard try regular(url) else { throw Failure.unsafeSource }
            payload[file] = try Data(contentsOf: url)
        }
        let destination = parent.appendingPathComponent("Dictionary Browser Extension", isDirectory: true)
        // Including dangling symlinks: never follow or overwrite an existing destination.
        if (try? manager.attributesOfItem(atPath: destination.path)) != nil { throw Failure.destinationExists }
        // Stage on the same volume. A failed export may leave this hidden staging directory,
        // but never a partial extension at the advertised final path or changed user files.
        let staging = parent.appendingPathComponent(".dictionary-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        try manager.createDirectory(at: staging.appendingPathComponent("icons"), withIntermediateDirectories: false)
        for file in files { try payload[file]!.write(to: staging.appendingPathComponent(file), options: .withoutOverwriting) }
        try manager.moveItem(at: staging, to: destination)
        return destination
    }
}
