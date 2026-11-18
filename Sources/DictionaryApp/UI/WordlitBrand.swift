import AppKit

/// Public identity. Legacy bundle, preference and pairing identifiers intentionally remain stable.
@MainActor
enum WordlitBrand {
    static let name = "Wordlit"
    static let icon: NSImage = {
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ??
            Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
        return url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 36, height: 36))
    }()
}
