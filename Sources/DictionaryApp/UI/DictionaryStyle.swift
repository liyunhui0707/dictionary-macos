import AppKit
import SwiftUI

/// Shared visual vocabulary. System appearance still owns light/dark switching.
enum DictionaryStyle {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let accent = adaptive(0x386751, 0xA5C5A8)
    static let paper = adaptive(0xFCFCFA, 0x242C28)
    static let surface = adaptive(0xF2F3EF, 0x2C3530)
    static let ink = adaptive(0x252D2B, 0xEDF1E9)
    static let secondary = adaptive(0x66716C, 0xA9B6AB)
    static let line = adaptive(0xE2E6DF, 0x3A453D)

    static func wordFont(compact: Bool) -> Font {
        .system(size: compact ? 30 : 42, weight: .regular, design: .serif)
    }
}

struct DictionaryMark: View {
    var body: some View {
        Text("d.").font(.system(size: 27, weight: .medium, design: .serif).italic())
            .foregroundStyle(DictionaryStyle.paper)
            .frame(width: 36, height: 36)
            .background(DictionaryStyle.accent, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

struct DictionaryCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DictionaryStyle.line))
    }
}
