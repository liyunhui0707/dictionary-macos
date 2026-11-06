import Foundation

enum LookupChannel: Hashable { case manual, selection }

/// An immutable input snapshot, separate from both the editable draft and model JSON.
struct LookupRequest: Sendable {
    let target: String
    let context: String?
    let containingSentence: String?
    let source: String

    let capture: SelectionLocation?
    let isManual: Bool

    init(target: String, context: String?, containingSentence: String?, source: String,
         capture: SelectionLocation? = nil, isManual: Bool = false) {
        self.target = target; self.context = context; self.containingSentence = containingSentence
        self.source = source; self.capture = capture; self.isManual = isManual
    }

    var providerContext: String {
        let text = context ?? target
        var selection: Any = NSNull()
        if capture?.reliability == .anchored, let range = capture?.range,
           let selected = range.slice(in: text), SelectionLocation.sameUnits(selected, target) {
            let units = Array(text.utf16)
            selection = ["unit": "utf16", "start": range.start, "end": range.end,
                         "before": String(decoding: units[..<range.start], as: UTF16.self),
                         "text": selected, "after": String(decoding: units[range.end...], as: UTF16.self)]
        }
        let mode = isManual ? "manual" : context == nil ? "targetOnly" :
            capture?.reliability == .anchored ? "anchored" : capture?.reliability == .heuristic ? "heuristic" : "unverified"
        // This object is always generated. Source text is never parsed as application metadata.
        let document: [String: Any] = ["format": "dictionary_context_v1", "mode": mode,
                                      "context_text": text, "selection": selection]
        return String(decoding: try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self)
    }

    static func manual(target: String, context: String) throws -> LookupRequest {
        let base = try captured(target: target, context: context, sentence: nil, source: "Manual")
        return LookupRequest(target: base.target, context: base.context,
                             containingSentence: base.context.flatMap { uniqueSentence(in: $0, target: base.target) },
                             source: base.source, isManual: true)
    }

    static func captured(target rawTarget: String, context rawContext: String?, sentence rawSentence: String?,
                         source: String, capture: SelectionLocation? = nil) throws -> LookupRequest {
        let legacyTrim = capture == nil || capture?.reliability == .legacyUnverified
        let target = legacyTrim ? rawTarget.trimmingCharacters(in: .whitespacesAndNewlines) : SelectionLocation.trim(rawTarget)
        guard !target.isEmpty else { throw LookupInputError.emptyTarget }
        if var location = capture {
            if location.reliability == .targetOnly {
                location.range = nil; location.sentenceRange = nil
                return LookupRequest(target: target, context: nil, containingSentence: nil, source: source, capture: location)
            }
            if location.reliability == .anchored, let text = rawContext, let span = location.range,
               let selected = span.slice(in: text), SelectionLocation.sameUnits(SelectionLocation.trim(selected), target) {
                let trim = SelectionLocation.trimmedSpan(selected)
                let selected = UTF16Span(start: span.start + trim.start, end: span.start + trim.end)
                var sentence: UTF16Span?
                if location.reason != .sentenceUnavailable, let s = location.sentenceRange,
                   s.contains(selected), let slice = s.slice(in: text), let supplied = rawSentence,
                   SelectionLocation.sameUnits(SelectionLocation.trim(slice), SelectionLocation.trim(supplied)) {
                    let edge = SelectionLocation.trimmedSpan(slice)
                    let adjusted = UTF16Span(start: s.start + edge.start, end: s.start + edge.end)
                    if adjusted.contains(selected) { sentence = adjusted }
                }
                guard let window = SelectionLocation.window(text: text, target: selected, sentence: sentence) else {
                    return try captured(target: target, context: nil, sentence: nil, source: source,
                        capture: .init(reliability: .targetOnly, method: location.method, reason: .budgetExceeded))
                }
                if SelectionLocation.sameUnits(window.context, target) {
                    return try captured(target: target, context: nil, sentence: nil, source: source,
                        capture: .init(reliability: .targetOnly, method: location.method, reason: .contextUnavailable))
                }
                location.range = window.range; location.sentenceRange = window.sentenceRange
                location.reason = sentence == nil ? .sentenceUnavailable : nil
                return LookupRequest(target: target, context: window.context,
                    containingSentence: window.sentenceRange?.slice(in: window.context), source: source, capture: location)
            }
            if location.reliability == .anchored {
                // An inconsistent claim never authorizes searching for a replacement occurrence.
                location.reliability = .legacyUnverified; location.reason = .rangeMismatch
            }
            location.range = nil; location.sentenceRange = nil
            return try legacy(target: rawTarget, context: rawContext, sentence: rawSentence, source: source, capture: location)
        }
        return try legacy(target: rawTarget, context: rawContext, sentence: rawSentence, source: source,
                          capture: .init(reliability: .legacyUnverified, method: .clipboard))
    }

    private static func legacy(target: String, context: String?, sentence: String?, source: String,
                               capture: SelectionLocation) throws -> LookupRequest {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw LookupInputError.emptyTarget }
        let trimmed = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let context = trimmed.isEmpty || trimmed == target ? nil : trimmed
        let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines)
        var capture = capture
        if context == nil { capture.reliability = .targetOnly; capture.reason = capture.reason ?? .contextUnavailable }
        return LookupRequest(target: target, context: context,
                             containingSentence: context == nil || sentence?.isEmpty != false || sentence == target ? nil : sentence,
                             source: source, capture: capture)
    }

    private static func uniqueSentence(in context: String, target: String) -> String? {
        guard let match = context.range(of: target, options: .literal) else { return nil }
        // Search after the first start, including overlapping occurrences.
        let next = context.index(after: match.lowerBound)
        guard context.range(of: target, options: .literal, range: next..<context.endIndex) == nil else { return nil }
        var result: String?
        context.enumerateSubstrings(in: context.startIndex..<context.endIndex, options: .bySentences) { text, _, range, stop in
            if range.lowerBound <= match.lowerBound && range.upperBound >= match.upperBound {
                result = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                stop = true
            }
        }
        return result
    }
}

enum LookupInputError: LocalizedError {
    case emptyTarget
    var errorDescription: String? { "Enter or select English text to translate." }
}

struct LookupResult {
    let request: LookupRequest
    let translation: Translation
}
