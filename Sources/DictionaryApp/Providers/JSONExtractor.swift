import Foundation

/// Extracts a JSON object from arbitrary model output. Small local models
/// often wrap valid JSON in chatter, markdown fences, or trailing commas;
/// this finds the first balanced `{ ... }` slice and cleans common defects.
enum JSONExtractor {
    static func extract(_ text: String) -> String {
        let stripped = stripCodeFences(text)
        guard let open = stripped.firstIndex(of: "{") else { return stripped }
        var depth = 0
        var close: String.Index?
        var i = open
        while i < stripped.endIndex {
            switch stripped[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { close = i }
            default: break
            }
            if close != nil { break }
            i = stripped.index(after: i)
        }
        guard let end = close else { return stripped }
        return removeTrailingCommas(String(stripped[open...end]))
    }

    private static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if let lastFence = t.range(of: "```", options: .backwards) {
                t = String(t[..<lastFence.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeTrailingCommas(_ s: String) -> String {
        s.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }
}
