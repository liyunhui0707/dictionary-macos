import Foundation

/// Exports bundled public files only. An existing version is reused only after
/// exact comparison; it is never repaired or overwritten in place.
struct BrowserExtensionExport {
    static let files = ["manifest.json", "content.js", "service-worker.js", "options.html", "options.js",
                        "icons/16.png", "icons/48.png", "icons/128.png"]
    struct Prepared {
        let directory: URL
        let version: String
        let reused: Bool
    }
    enum Failure: LocalizedError {
        case unavailable, unsafeSource, destinationExists
        var errorDescription: String? {
            switch self {
            case .unavailable: return "当前 App 未包含配套扩展。请使用完整安装包。"
            case .unsafeSource: return "配套扩展不完整，未准备文件。请重新下载完整安装包。"
            case .destinationExists: return "此版本的文件夹与配套扩展不一致，未更改任何文件。请导出到其他位置，保留旧目录以便回退。"
            }
        }
    }

    static func bundledVersion(source: URL?) throws -> String { try payload(source).version }

    static func verify(source: URL?, directory: URL) throws -> Prepared {
        let contents = try payload(source)
        guard matches(directory, contents: contents.files) else { throw Failure.destinationExists }
        return Prepared(directory: directory, version: contents.version, reused: true)
    }

    static func prepare(source: URL?, parent: URL) throws -> Prepared {
        let contents = try payload(source)
        let destination = parent.appendingPathComponent("Wordlit Browser Extension \(contents.version)", isDirectory: true)
        let manager = FileManager.default
        // Includes dangling links. Reuse means no writes, renames or browser reload.
        if (try? manager.attributesOfItem(atPath: destination.path)) != nil {
            guard matches(destination, contents: contents.files) else { throw Failure.destinationExists }
            return Prepared(directory: destination, version: contents.version, reused: true)
        }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".dictionary-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        try manager.createDirectory(at: staging.appendingPathComponent("icons"), withIntermediateDirectories: false)
        for file in files { try contents.files[file]!.write(to: staging.appendingPathComponent(file), options: .withoutOverwriting) }
        // A failed operation can leave hidden staging, but never changes an old export.
        try manager.moveItem(at: staging, to: destination)
        return Prepared(directory: destination, version: contents.version, reused: false)
    }

    private static func directoryIsSafe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func data(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 2_000_000 else { throw Failure.unsafeSource }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 2_000_000 else { throw Failure.unsafeSource }
        return bytes
    }

    private static func payload(_ source: URL?) throws -> (version: String, files: [String: Data]) {
        guard let source else { throw Failure.unavailable }
        guard directoryIsSafe(source), directoryIsSafe(source.appendingPathComponent("icons")) else { throw Failure.unsafeSource }
        var bytes: [String: Data] = [:]
        do { for file in files { bytes[file] = try data(source.appendingPathComponent(file)) } }
        catch { throw Failure.unsafeSource }
        guard let manifest = try? JSONSerialization.jsonObject(with: bytes["manifest.json"]!) as? [String: Any],
              let version = manifest["version"] as? String else { throw Failure.unsafeSource }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.count <= 5 && part.utf8.allSatisfy { (48...57).contains($0) } &&
            (part.count == 1 || part.first != "0") && Int(part).map { $0 <= 65535 } == true
        }) else { throw Failure.unsafeSource }
        return (version, bytes)
    }

    private static func matches(_ directory: URL, contents: [String: Data]) -> Bool {
        guard directoryIsSafe(directory), directoryIsSafe(directory.appendingPathComponent("icons")) else { return false }
        let manager = FileManager.default
        func names(_ url: URL) -> Set<String>? {
            guard let entries = try? manager.contentsOfDirectory(atPath: url.path) else { return nil }
            // Finder can add this after revealing a directory. Never read or copy it.
            return Set(entries.filter { $0 != ".DS_Store" })
        }
        guard names(directory) == Set(files.filter { !$0.contains("/") } + ["icons"]),
              names(directory.appendingPathComponent("icons")) == Set(["16.png", "48.png", "128.png"]) else { return false }
        return files.allSatisfy { (try? data(directory.appendingPathComponent($0))) == contents[$0] }
    }
}
