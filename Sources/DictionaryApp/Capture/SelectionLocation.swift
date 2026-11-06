import Foundation

/// Half-open offsets into the unchanged source string's UTF-16 units, never JSON bytes.
struct UTF16Span: Codable, Equatable, Sendable {
    let start: Int
    let end: Int

    func slice(in text: String) -> String? {
        let source = text as NSString
        guard start >= 0, start < end, end <= source.length else { return nil }
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < source.length && (0xD800...0xDBFF).contains(source.character(at: offset - 1)) &&
                (0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        guard !splitsSurrogate(start), !splitsSurrogate(end) else { return nil }
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    func contains(_ other: UTF16Span) -> Bool { start <= other.start && end >= other.end }
    func rebased(by offset: Int) -> UTF16Span { .init(start: start - offset, end: end - offset) }
}

enum CaptureReliability: String, Codable, Sendable { case anchored, heuristic, targetOnly, legacyUnverified }
enum CaptureMethod: String, Codable, Sendable { case domRange, editorRange, axRange, axTreeWalk, clipboard }
enum CaptureReason: String, Codable, Sendable {
    case ambiguousOccurrence, rangeMismatch, unsupportedStructure, incompleteTraversal, sentenceUnavailable
    case budgetExceeded, metadataInvalid, contextUnavailable, sourceChanged
}

struct SelectionLocation: Codable, Equatable, Sendable {
    let version: Int
    let unit: String
    var reliability: CaptureReliability
    let method: CaptureMethod
    var range: UTF16Span?
    var sentenceRange: UTF16Span?
    var reason: CaptureReason?

    init(reliability: CaptureReliability, method: CaptureMethod, range: UTF16Span? = nil,
         sentenceRange: UTF16Span? = nil, reason: CaptureReason? = nil) {
        version = 1; unit = "utf16"
        self.reliability = reliability; self.method = method
        self.range = range; self.sentenceRange = sentenceRange; self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case version, unit, reliability, method, range, sentenceRange, reason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        unit = try c.decode(String.self, forKey: .unit)
        reliability = try c.decode(CaptureReliability.self, forKey: .reliability)
        method = try c.decode(CaptureMethod.self, forKey: .method)
        reason = try c.decodeIfPresent(CaptureReason.self, forKey: .reason)
        range = try c.decodeIfPresent(UTF16Span.self, forKey: .range)
        // Bad sentence evidence must not discard independently valid target evidence.
        sentenceRange = try? c.decode(UTF16Span.self, forKey: .sentenceRange)
        let safe = 9_007_199_254_740_991
        guard version == 1, unit == "utf16",
              (reliability == .anchored) == (range != nil),
              range.map({ $0.start >= 0 && $0.start < $0.end && $0.end <= safe }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid capture metadata"))
        }
        if let s = sentenceRange, s.start < 0 || s.start >= s.end || s.end > safe { sentenceRange = nil }
        if reliability != .anchored { sentenceRange = nil }
    }

    static func sameUnits(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }

    /// captureBoundaryV1; deliberately separate from legacy/manual Foundation trimming.
    private static let boundary = CharacterSet(charactersIn:
        "\u{9}\u{a}\u{b}\u{c}\u{d} \u{85}\u{a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    static func trimmedSpan(_ text: String) -> UTF16Span {
        let units = Array(text.utf16)
        func edge(_ u: UInt16) -> Bool { UnicodeScalar(u).map { boundary.contains($0) } ?? false }
        var start = 0, end = units.count
        while start < end && edge(units[start]) { start += 1 }
        while end > start && edge(units[end - 1]) { end -= 1 }
        return .init(start: start, end: end)
    }
    static func trim(_ text: String) -> String { trimmedSpan(text).slice(in: text) ?? "" }

    struct Window: Equatable {
        let context: String
        let range: UTF16Span
        let sentenceRange: UTF16Span?
        let sourceStart: Int
        let cutLeft: Bool
        let cutRight: Bool
    }

    static func window(text: String, target: UTF16Span, sentence: UTF16Span?, limit: Int = 2000) -> Window? {
        guard target.slice(in: text) != nil else { return nil }
        let required = sentence ?? target
        guard required.contains(target), required.slice(in: text) != nil, required.end - required.start <= limit else { return nil }
        let length = text.utf16.count
        var start = max(0, min(required.start, required.end - limit / 2 - (required.end - required.start) / 2))
        start = min(start, max(0, length - limit))
        var end = min(length, start + limit)
        // Move only context edges, inward to composed-character boundaries.
        let ns = text as NSString
        if start > 0 {
            let cluster = ns.rangeOfComposedCharacterSequence(at: start)
            if cluster.location < start { start = NSMaxRange(cluster) }
        }
        if end < length {
            let cluster = ns.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { end = cluster.location }
        }
        guard start <= required.start, end >= required.end,
              let raw = UTF16Span(start: start, end: end).slice(in: text) else { return nil }
        let cutLeft = start > 0, cutRight = end < length
        let trim = trimmedSpan(raw)
        start += trim.start
        end = start + (trim.end - trim.start)
        guard start <= required.start, end >= required.end, let context = trim.slice(in: raw) else { return nil }
        return Window(context: context, range: target.rebased(by: start),
                      sentenceRange: sentence?.rebased(by: start), sourceStart: start,
                      cutLeft: cutLeft, cutRight: cutRight)
    }
}
