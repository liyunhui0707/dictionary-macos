import AppKit
import ApplicationServices

struct CapturedContext {
    let target: String
    let context: String
    /// The single sentence in `context` that contains `target`. nil when
    /// context-aware extraction wasn't available (pasteboard fallback path).
    let containingSentence: String?
    var diagnostics = CaptureDetails()
    var capture: SelectionLocation? = nil
}

final class ContextExtractor {
    private let readAttribute: (AXUIElement, AXAttribute) -> AXRead
    private let bundleIdentifier: (AXUIElement) -> String?
    private var details = CaptureDetails()
    private var booksSelection: BooksSelectionReader.Selection?

    init(readAttribute: @escaping (AXUIElement, AXAttribute) -> AXRead = AXRead.live,
         bundleIdentifier: @escaping (AXUIElement) -> String? = { app in
             var pid: pid_t = 0
             guard AXUIElementGetPid(app, &pid) == .success else { return nil }
             return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
         }) {
        self.readAttribute = readAttribute
        self.bundleIdentifier = bundleIdentifier
    }

    func extractReport() -> CaptureReport {
        details = CaptureDetails()
        booksSelection = nil
        let captured = extract()
        return CaptureReport(captured: captured, details: details, booksSelection: booksSelection)
    }

    private func read(_ element: AXUIElement, _ attribute: AXAttribute) -> CFTypeRef? {
        let started = ProcessInfo.processInfo.systemUptime
        switch readAttribute(element, attribute) {
        case .value(let value): return value
        case .failure(let error):
            let code: CaptureIssueCode = error == .attributeUnsupported ? .attributeUnsupported : error == .noValue ? .attributeNoValue : .axCallFailed
            details.add(CaptureIssue(code: code, attribute: attribute, axError: error.rawValue,
                                     elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)))
            return nil
        }
    }
    /// UTF-16 processing budget for a complete reconstructed candidate/attempt.
    private let treeWalkBudget = 8000
    private let maxAncestorHops = 12
    private let maxTreeWalkNodes = 4000

    /// Reads the selected text and surrounding paragraph from the focused UI element
    /// via the Accessibility API. Returns nil only when no selection is readable
    /// at all — caller falls back to pasteboard.
    ///
    /// Strategy: kAXSelectedTextAttribute is the most-supported attribute and
    /// gives us the substring directly. We try that first. Context (full text +
    /// range) is a bonus when available — when it's not, target itself is used
    /// as context, which is no worse than the pasteboard fallback.
    func extract() -> CapturedContext? {
        let system = AXUIElementCreateSystemWide()
        guard let app = focusedElementAttribute(system, .focusedApplication),
              let element = focusedElementAttribute(app, .focusedUIElement) else { return nil }
        if bundleIdentifier(app) == "com.apple.iBooksX",
           let role = copyStringAttribute(element, .role),
           ["AXGroup", "AXWebArea", "AXStaticText"].contains(role) {
            let reader = BooksSelectionReader(read: readAttribute)
            guard let first = reader.selection(in: element),
                  let second = reader.selection(in: element), BooksSelectionReader.matches(first, second),
                  let currentApp = focusedElementAttribute(system, .focusedApplication), CFEqual(app, currentApp),
                  let currentElement = focusedElementAttribute(app, .focusedUIElement), CFEqual(element, currentElement) else {
                details.add(CaptureIssue(code: .contextUnavailable))
                return nil
            }
            // Check the complete native text before cropping. Copy can confirm a
            // word but cannot identify which repeated occurrence Books selected.
            guard second.text.utf16.count <= treeWalkBudget else {
                return targetOnly(second.target, reason: .budgetExceeded)
            }
            booksSelection = second
            guard eligibleMatches(in: second.text, target: second.target).count == 1 else {
                return targetOnly(second.target, reason: .ambiguousOccurrence)
            }
            details.strategy = .axRange
            return anchored(fullText: second.text, span: second.span, target: second.target, pageFragment: true)
        }

        let target = readSelectedText(from: element)
        guard let target else { return nil }
        guard !target.isEmpty else {
            details.add(CaptureIssue(code: .noSelection, attribute: .selectedText)); return nil
        }

        if target.utf16.count > 2000 { return targetOnly(target, reason: .budgetExceeded) }

        if let (fullText, selRange) = readFullTextAndRange(from: element),
           selRange.location >= 0, selRange.length > 0,
           selRange.location <= fullText.utf16.count,
           selRange.length <= fullText.utf16.count - selRange.location {
            let span = UTF16Span(start: selRange.location, end: selRange.location + selRange.length)
            if let selected = span.slice(in: fullText),
               SelectionLocation.sameUnits(SelectionLocation.trim(selected), target) {
                // Re-read selection and range: AX attributes are not an atomic snapshot.
                if let again = readSelectedText(from: element), SelectionLocation.sameUnits(again, target),
                   let (againText, againRange) = readFullTextAndRange(from: element),
                   againRange == selRange,
                   let first = SelectionLocation.window(text: fullText, target: span, sentence: nil, limit: 8000),
                   let second = SelectionLocation.window(text: againText, target: span, sentence: nil, limit: 8000),
                   first.sourceStart == second.sourceStart, SelectionLocation.sameUnits(first.context, second.context) {
                    details.strategy = .axRange
                    return anchored(fullText: fullText, span: span, target: target)
                }
                return targetOnly(target, reason: .sourceChanged)
            }
            return targetOnly(target, reason: .rangeMismatch)
        }
        return extractByTreeWalk(focused: element, target: target)
    }

    /// Pure reconciliation of already-read evidence. The copied word determines
    /// the target; native offsets are not reused. Call only after the same node
    /// and full text have been observed before and after the copy.
    static func contextForCopiedBooksTarget(_ target: String, text: String) -> CapturedContext {
        let extractor = ContextExtractor()
        guard text.utf16.count <= extractor.treeWalkBudget else {
            return extractor.targetOnly(target, reason: .budgetExceeded)
        }
        let matches = extractor.eligibleMatches(in: text, target: target)
        guard matches.count == 1, let span = matches.first else {
            return extractor.targetOnly(target, reason: matches.isEmpty ? .rangeMismatch : .ambiguousOccurrence)
        }
        let result = extractor.anchored(fullText: text, span: span, target: target, pageFragment: true)
        guard result.capture?.reliability == .anchored else { return result }
        return CapturedContext(target: target, context: result.context, containingSentence: result.containingSentence,
            capture: .init(reliability: .heuristic, method: .axRange, reason: result.capture?.reason))
    }

    private func targetOnly(_ target: String, method: CaptureMethod = .axRange, reason: CaptureReason) -> CapturedContext {
        details.strategy = .axSelectionOnly
        details.add(CaptureIssue(code: .contextUnavailable))
        return CapturedContext(target: target, context: target, containingSentence: nil,
                               capture: .init(reliability: .targetOnly, method: method, reason: reason))
    }

    private func anchored(fullText: String, span: UTF16Span, target: String, pageFragment: Bool = false) -> CapturedContext {
        let selectedTrim = SelectionLocation.trimmedSpan(span.slice(in: fullText)!)
        let selected = UTF16Span(start: span.start + selectedTrim.start, end: span.start + selectedTrim.end)
        guard let scan = SelectionLocation.window(text: fullText, target: selected, sentence: nil, limit: 8000) else {
            return targetOnly(target, reason: .budgetExceeded)
        }
        var sentence = sentenceRange(in: scan.context, selection: scan.range)
        // Books exposes page fragments. A boundary at either edge of a text node
        // does not establish a complete sentence, even if it has punctuation.
        if pageFragment, let candidate = sentence {
            let visible = SelectionLocation.trimmedSpan(scan.context)
            if candidate.start <= visible.start || candidate.end >= visible.end { sentence = nil }
        }
        // A bounded scan edge is not proof of a full native sentence either.
        if let sentence, (sentence.start == 0 && scan.cutLeft) ||
            (sentence.end == scan.context.utf16.count && scan.cutRight) {
            return targetOnly(target, reason: .budgetExceeded)
        }
        let paragraph = (scan.context as NSString).paragraphRange(for: NSRange(location: scan.range.start, length: scan.range.end - scan.range.start))
        let paragraphSpan = UTF16Span(start: paragraph.location, end: NSMaxRange(paragraph))
        let bounds = paragraphSpan.contains(sentence ?? scan.range) ? paragraphSpan : UTF16Span(start: 0, end: scan.context.utf16.count)
        guard let paragraphText = bounds.slice(in: scan.context),
              let window = SelectionLocation.window(text: paragraphText, target: scan.range.rebased(by: bounds.start),
                                                     sentence: sentence?.rebased(by: bounds.start)) else {
            return targetOnly(target, reason: .budgetExceeded)
        }
        return CapturedContext(target: target, context: window.context,
                               containingSentence: window.sentenceRange?.slice(in: window.context),
                               capture: .init(reliability: .anchored, method: .axRange, range: window.range,
                                              sentenceRange: window.sentenceRange,
                                              reason: sentence == nil ? .sentenceUnavailable : nil))
    }

    /// A complete unique reconstruction is useful, but never an exact source range.
    private func extractByTreeWalk(focused: AXUIElement, target: String) -> CapturedContext {
        var current = focused
        var ancestors: [AXUIElement] = []
        var remainingNodes = maxTreeWalkNodes
        var remainingUnits = treeWalkBudget
        for hop in 0..<maxAncestorHops {
            ancestors.append(current)
            var seen: [AXUIElement] = []
            var pieces: [String] = []
            let stop = collectText(from: current, depth: 0, seen: &seen, pieces: &pieces,
                                   remainingNodes: &remainingNodes, remainingUnits: &remainingUnits)
            if stop == .budgetExceeded {
                return targetOnly(target, method: .axTreeWalk, reason: .budgetExceeded)
            }
            if stop == nil {
                let text = pieces.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = eligibleMatches(in: text, target: target)
                if matches.count > 1 { return targetOnly(target, method: .axTreeWalk, reason: .ambiguousOccurrence) }
                if let match = matches.first, text.utf16.count >= target.utf16.count + 8 {
                    let sentence = sentenceRange(in: text, selection: match)
                    guard let window = SelectionLocation.window(text: text, target: match, sentence: sentence) else {
                        return targetOnly(target, method: .axTreeWalk, reason: .budgetExceeded)
                    }
                    details.strategy = .axTreeWalk
                    return CapturedContext(target: target, context: window.context,
                        containingSentence: window.sentenceRange?.slice(in: window.context),
                        capture: .init(reliability: .heuristic, method: .axTreeWalk))
                }
            }
            // Reaching zero after a complete visit is not itself a budget stop.
            // Report exhaustion only if another required visit/copy cannot proceed.
            guard let next = parent(of: current) else {
                return targetOnly(target, method: .axTreeWalk, reason: stop ?? .contextUnavailable)
            }
            if ancestors.contains(where: { CFEqual($0, next) }) {
                return targetOnly(target, method: .axTreeWalk, reason: .incompleteTraversal)
            }
            if hop + 1 == maxAncestorHops {
                return targetOnly(target, method: .axTreeWalk, reason: .budgetExceeded)
            }
            current = next
        }
        return targetOnly(target, method: .axTreeWalk, reason: .budgetExceeded)
    }

    /// nil means complete; only these fixed stop reasons leave this bounded traversal.
    private func collectText(from element: AXUIElement, depth: Int, seen: inout [AXUIElement], pieces: inout [String],
                             remainingNodes: inout Int, remainingUnits: inout Int) -> CaptureReason? {
        guard depth <= 25, remainingNodes > 0 else { return .budgetExceeded }
        guard !seen.contains(where: { CFEqual($0, element) }) else { return .incompleteTraversal }
        seen.append(element); remainingNodes -= 1
        guard let role = copyStringAttribute(element, .role) else { return .incompleteTraversal }
        if role == "AXStaticText" {
            guard let value = copyStringAttribute(element, .value) else { return .incompleteTraversal }
            return appendText(value, pieces: &pieces, remainingUnits: &remainingUnits)
        }
        guard let children = read(element, .children) as? [AXUIElement] else { return .incompleteTraversal }
        if children.isEmpty {
            if let value = copyStringAttribute(element, .value) {
                return appendText(value, pieces: &pieces, remainingUnits: &remainingUnits)
            } else if role == "AXTextArea" || role == "AXTextField" { return .incompleteTraversal }
        }
        for child in children {
            if let stop = collectText(from: child, depth: depth + 1, seen: &seen, pieces: &pieces,
                                      remainingNodes: &remainingNodes, remainingUnits: &remainingUnits) { return stop }
        }
        return nil
    }

    private func appendText(_ value: String, pieces: inout [String], remainingUnits: inout Int) -> CaptureReason? {
        let units = value.utf16.count + (pieces.isEmpty ? 0 : 1)
        guard units <= remainingUnits else { return .budgetExceeded }
        remainingUnits -= units; pieces.append(value)
        return nil
    }

    private func eligibleMatches(in text: String, target: String) -> [UTF16Span] {
        var matches: [UTF16Span] = []
        var start = text.startIndex
        while start < text.endIndex, let match = text.range(of: target, options: .literal, range: start..<text.endIndex) {
            let before = match.lowerBound == text.startIndex ? nil : text[text.index(before: match.lowerBound)].unicodeScalars.first
            let after = match.upperBound == text.endIndex ? nil : text[match.upperBound].unicodeScalars.first
            let word = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_"))
            if !(before.map(word.contains) ?? false), !(after.map(word.contains) ?? false) {
                let r = NSRange(match, in: text)
                matches.append(.init(start: r.location, end: NSMaxRange(r)))
                if matches.count > 1 { break }
            }
            start = text.index(after: match.lowerBound)
        }
        return matches
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = read(element, .parent), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: AXAttribute) -> String? {
        read(element, attribute) as? String
    }

    private func sentenceRange(in text: String, selection: UTF16Span) -> UTF16Span? {
        var found: UTF16Span?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, stop in
            let ns = NSRange(range, in: text)
            let span = UTF16Span(start: ns.location, end: NSMaxRange(ns))
            if span.contains(selection), let raw = span.slice(in: text) {
                let trim = SelectionLocation.trimmedSpan(raw)
                let trimmed = UTF16Span(start: span.start + trim.start, end: span.start + trim.end)
                if trimmed.contains(selection) { found = trimmed; stop = true }
            }
        }
        return found
    }

    private func readSelectedText(from element: AXUIElement) -> String? {
        guard let ref = read(element, .selectedText) else { return nil }
        guard let s = ref as? String else {
            details.add(CaptureIssue(code: .targetExtractionFailed, attribute: .selectedText)); return nil
        }
        return SelectionLocation.trim(s)
    }

    private func readFullTextAndRange(from element: AXUIElement) -> (String, NSRange)? {
        guard let fullText = read(element, .value) as? String, !fullText.isEmpty else {
            return nil
        }

        guard let unwrapped = read(element, .selectedTextRange),
              CFGetTypeID(unwrapped) == AXValueGetTypeID() else {
            return nil
        }

        var cfRange = CFRange()
        guard AXValueGetValue(unwrapped as! AXValue, .cfRange, &cfRange), cfRange.length > 0 else {
            return nil
        }

        return (fullText, NSRange(location: cfRange.location, length: cfRange.length))
    }

    private func focusedElementAttribute(_ element: AXUIElement, _ attribute: AXAttribute) -> AXUIElement? {
        guard let value = read(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            details.add(CaptureIssue(code: .targetExtractionFailed, attribute: attribute)); return nil
        }
        return (value as! AXUIElement)
    }

}
