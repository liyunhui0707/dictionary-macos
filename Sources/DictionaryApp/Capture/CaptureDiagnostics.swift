import ApplicationServices
import Foundation

/// Only fixed attribute names and numeric AX errors cross the diagnostic boundary.
enum AXAttribute: String, Codable {
    case focusedApplication = "AXFocusedApplication", focusedUIElement = "AXFocusedUIElement"
    case selectedText = "AXSelectedText", value = "AXValue", selectedTextRange = "AXSelectedTextRange"
    case role = "AXRole", children = "AXChildren", parent = "AXParent"
    case selectedTextMarkerRange = "AXSelectedTextMarkerRange"
}

enum AXParameterizedAttribute: String {
    case stringForTextMarkerRange = "AXStringForTextMarkerRange"
    case sentenceForTextMarker = "AXSentenceTextMarkerRangeForTextMarker"
    case lengthForTextMarkerRange = "AXLengthForTextMarkerRange"
    case uiElementForTextMarker = "AXUIElementForTextMarker"
    case elementsForSearchPredicate = "AXUIElementsForSearchPredicate"

    static func live(_ element: AXUIElement, _ attribute: Self, _ parameter: CFTypeRef) -> AXRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attribute.rawValue as CFString, parameter, &value)
        guard error == .success else { return .failure(error) }
        guard let value else { return .failure(.noValue) }
        return .value(value)
    }
}

enum AXTextMarkerEndpoint {
    case start, end

    static func live(_ range: CFTypeRef, _ edge: Self) -> CFTypeRef? {
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = range as! AXTextMarkerRange
        return edge == .start ? AXTextMarkerRangeCopyStartMarker(range) : AXTextMarkerRangeCopyEndMarker(range)
    }
}

enum AXRead {
    case value(CFTypeRef)
    case failure(AXError)

    static func live(_ element: AXUIElement, _ attribute: AXAttribute) -> AXRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        guard error == .success else { return .failure(error) }
        guard let value else { return .failure(.noValue) }
        return .value(value)
    }
}

enum CaptureStrategy: String, Codable {
    case safariDOM, axRange, axTreeWalk, axSelectionOnly, clipboardOnly, screenOCR
    var reliability: String {
        switch self {
        case .axRange: return "selectionRange"
        case .safariDOM, .axTreeWalk, .screenOCR: return "heuristicContext"
        case .axSelectionOnly, .clipboardOnly: return "targetOnly"
        }
    }
}

enum CaptureIssueCode: String, Codable {
    case accessibilityNotTrusted, noSelection, attributeUnsupported, attributeNoValue, axCallFailed
    case targetExtractionFailed, contextUnavailable, clipboardFallbackFailed, safariUnavailable
}

enum ClipboardFailure: String, Codable {
    case eventsUnavailable, unchanged, unusableText, interrupted, unpreservableContents, restorationFailed
}

struct CaptureIssue: Codable, Equatable {
    let code: CaptureIssueCode
    var attribute: AXAttribute? = nil
    var axError: Int32? = nil
    var elapsedMilliseconds: Int? = nil
    var clipboardReason: ClipboardFailure? = nil
}

struct CaptureDetails: Codable {
    var screenContext: ScreenContextStatus? = nil
    var screenRecognitionBudgetMilliseconds: Int? = nil
    var screenRecognitionElapsedMilliseconds: Int? = nil
    var strategy: CaptureStrategy? = nil
    var issues: [CaptureIssue] = []
    var accessibilityTrusted: Bool? = nil
    var reliability: CaptureReliability? = nil
    var reason: CaptureReason? = nil

    mutating func includeQuality(_ capture: SelectionLocation?) {
        reliability = capture?.reliability ?? reliability
        reason = capture?.reason ?? reason
    }

    mutating func add(_ issue: CaptureIssue) {
        // Tree traversal can encounter thousands of identical unsupported attributes.
        guard issues.count < 24, !issues.contains(where: {
            $0.code == issue.code && $0.attribute == issue.attribute && $0.axError == issue.axError && $0.clipboardReason == issue.clipboardReason
        }) else { return }
        issues.append(issue)
    }
}

struct CaptureReport {
    let captured: CapturedContext?
    let details: CaptureDetails
    // In-memory native evidence only; never included in diagnostic serialization.
    var booksSelection: BooksSelectionReader.Selection? = nil
    var webSelection: AXWebSelectionReader.Selection? = nil
    var focus: CaptureFocus? = nil
}

struct CaptureFocus {
    let application: AXUIElement
    let element: AXUIElement

    func matches(_ other: CaptureFocus?) -> Bool {
        guard let other else { return false }
        return CFEqual(application, other.application) && CFEqual(element, other.element)
    }
}

struct ClipboardCapture {
    let text: String?
    let failure: ClipboardFailure?
}

struct CaptureFailure: LocalizedError {
    let details: CaptureDetails
    var errorDescription: String? {
        if details.issues.contains(where: { $0.clipboardReason == .restorationFailed }) {
            return "未能恢复原剪贴板，已停止查词。剪贴板可能仍是刚才选中的内容；请检查后重新复制需要保留的内容。"
        }
        if details.reason == .sourceChanged {
            return "来源窗口已变化，请重新选中文字后再试。"
        }
        if details.issues.contains(where: { $0.code == .accessibilityNotTrusted }) {
            return "当前 Wordlit 尚无选词权限。请在系统设置中为当前应用开启辅助功能，再重试。"
        }
        if details.issues.contains(where: { $0.code == .noSelection }) {
            return "没有读到选中文字。请先选中英文再试，也可以在主窗口输入。"
        }
        if details.issues.contains(where: { $0.code == .targetExtractionFailed }) {
            return "未能解析选区文字，可将原文粘贴到主窗口查询。"
        }
        if details.issues.contains(where: { $0.code == .axCallFailed }) {
            return "未能从当前软件读到选区，可重新选择，或将原文粘贴到主窗口。"
        }
        return "当前软件未提供可用的选区文字。可重新选择，或将原文粘贴到主窗口。"
    }
}

/// Trust gates AX/copy, not Safari's independent Apple Events path.
/// Books AX selection attributes can agree on the wrong word after pagination.
@MainActor
final class NativeCapturePipeline {
    private let isTrusted: () -> Bool
    private let safari: () -> CapturedContext?
    private let ax: () -> CaptureReport
    private let clipboard: () async throws -> ClipboardCapture
    private let isSourceCurrent: () -> Bool

    init(isTrusted: @escaping () -> Bool, safari: @escaping () -> CapturedContext?,
         ax: @escaping () -> CaptureReport, clipboard: @escaping () async throws -> ClipboardCapture,
         isSourceCurrent: @escaping () -> Bool = { true }) {
        self.isTrusted = isTrusted; self.safari = safari; self.ax = ax; self.clipboard = clipboard
        self.isSourceCurrent = isSourceCurrent
    }

    func capture(isSafari: Bool, isBooks: Bool = false) async throws -> CapturedContext {
        let trusted = isTrusted()
        var details = CaptureDetails(accessibilityTrusted: trusted)
        try requireSource(details)
        if isSafari {
            let result = safari()
            try requireSource(details)
            if var captured = result {
                details.strategy = .safariDOM; details.includeQuality(captured.capture); captured.diagnostics = details; return captured
            }
            details.add(CaptureIssue(code: .safariUnavailable))
        }
        guard trusted else {
            details.add(CaptureIssue(code: .accessibilityNotTrusted))
            throw CaptureFailure(details: details)
        }
        let report = ax()
        report.details.issues.forEach { details.add($0) }
        try requireSource(details)
        if !isBooks, report.webSelection == nil, var captured = report.captured {
            details.strategy = report.details.strategy; details.includeQuality(captured.capture); captured.diagnostics = details; return captured
        }
        let result: ClipboardCapture
        do { result = try await clipboard() }
        catch {
            details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: .interrupted))
            try requireSource(details)
            throw CaptureFailure(details: details)
        }
        if let failure = result.failure {
            details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: failure))
        }
        try requireSource(details)
        try Task.checkCancellation()
        if let text = result.text.map({ isBooks ? SelectionLocation.trim($0) : $0 }), !text.isEmpty {
            // Books can append a citation to copied passages. Do not guess which
            // portion was selected or submit the citation as the lookup target.
            if isBooks && text.utf16.count > 2000 {
                details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: .unusableText))
                throw CaptureFailure(details: details)
            }
            if isBooks && text.unicodeScalars.contains(where: CharacterSet.newlines.contains) {
                // Do not strip a guessed citation. Multi-paragraph selection is usable
                // only if an unchanged native snapshot independently agrees exactly.
                let after = ax()
                try requireSource(details)
                guard let before = report.booksSelection, let current = after.booksSelection,
                      BooksSelectionReader.matches(before, current),
                      SelectionLocation.sameUnits(SelectionLocation.trim(current.target), text) else {
                    details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: .unusableText))
                    throw CaptureFailure(details: details)
                }
                details.strategy = .clipboardOnly
                return CapturedContext(target: text, context: text, containingSentence: nil, diagnostics: details,
                    capture: .init(reliability: .targetOnly, method: .clipboard))
            }
            var reason: CaptureReason = .contextUnavailable
            if !isBooks, let before = report.webSelection {
                let after = ax()
                try requireSource(details)
                if let current = after.webSelection, AXWebSelectionReader.matches(before, current),
                   report.focus?.matches(after.focus) == true {
                    if SelectionLocation.sameUnits(SelectionLocation.trim(text), current.target) {
                        let recovered = ContextExtractor.contextForCopiedNativeTarget(text, text: current.text)
                        if recovered.capture?.reliability == .heuristic {
                            let capture = SelectionLocation(reliability: .heuristic, method: .axTreeWalk,
                                reason: current.sentence == nil ? recovered.capture?.reason : nil)
                            details.strategy = .axTreeWalk; details.includeQuality(capture)
                            return CapturedContext(target: text, context: recovered.context,
                                containingSentence: current.sentence ?? recovered.containingSentence,
                                diagnostics: details, capture: capture)
                        }
                        reason = recovered.capture?.reason ?? .contextUnavailable
                    } else { reason = .rangeMismatch }
                } else { reason = .sourceChanged }
            } else if isBooks, let before = report.booksSelection {
                let after = ax()
                try requireSource(details)
                if let current = after.booksSelection, BooksSelectionReader.matches(before, current) {
                    var recovered = ContextExtractor.contextForCopiedNativeTarget(text, text: current.text)
                    if recovered.capture?.reliability == .heuristic {
                        details.strategy = .axRange; details.includeQuality(recovered.capture)
                        recovered.diagnostics = details
                        return recovered
                    }
                    reason = recovered.capture?.reason ?? .contextUnavailable
                } else { reason = .sourceChanged }
            } else if isBooks, let first = report.captured {
                if !SelectionLocation.sameUnits(first.target, text) {
                    reason = .rangeMismatch
                } else if first.capture?.reliability == .targetOnly {
                    reason = first.capture?.reason ?? .contextUnavailable
                } else {
                    let after = ax()
                    try requireSource(details)
                    if let second = after.captured,
                       SelectionLocation.sameUnits(first.target, second.target),
                       SelectionLocation.sameUnits(first.context, second.context),
                       first.capture == second.capture,
                       first.containingSentence == second.containingSentence {
                        // Copy corroborates the word, not Books' numerical range.
                        // Keep this as heuristic context; never send exact offsets.
                        let capture = SelectionLocation(reliability: .heuristic, method: .axRange,
                                                        reason: second.capture?.reason)
                        details.strategy = .axRange; details.includeQuality(capture)
                        return CapturedContext(target: text, context: second.context,
                            containingSentence: second.containingSentence, diagnostics: details, capture: capture)
                    }
                    reason = .sourceChanged
                }
            }
            details.strategy = .clipboardOnly
            details.add(CaptureIssue(code: .contextUnavailable))
            let capture = SelectionLocation(reliability: .targetOnly, method: .clipboard, reason: reason)
            details.includeQuality(capture)
            return CapturedContext(target: text, context: text, containingSentence: nil, diagnostics: details, capture: capture)
        }
        details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: result.failure ?? .unusableText))
        throw CaptureFailure(details: details)
    }

    private func requireSource(_ details: CaptureDetails) throws {
        guard isSourceCurrent() else {
            var failure = details
            failure.reason = .sourceChanged
            throw CaptureFailure(details: failure)
        }
    }
}
