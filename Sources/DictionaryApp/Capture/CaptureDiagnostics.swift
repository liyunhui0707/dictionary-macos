import ApplicationServices
import Foundation

/// Only fixed attribute names and numeric AX errors cross the diagnostic boundary.
enum AXAttribute: String, Codable {
    case focusedApplication = "AXFocusedApplication", focusedUIElement = "AXFocusedUIElement"
    case selectedText = "AXSelectedText", value = "AXValue", selectedTextRange = "AXSelectedTextRange"
    case role = "AXRole", children = "AXChildren", parent = "AXParent"
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
    case safariDOM, axRange, axTreeWalk, axSelectionOnly, clipboardOnly
    var reliability: String {
        switch self {
        case .axRange: return "selectionRange"
        case .safariDOM, .axTreeWalk: return "heuristicContext"
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
    // In-memory Books evidence only; never included in diagnostic serialization.
    var booksSelection: BooksSelectionReader.Selection? = nil
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
        if details.issues.contains(where: { $0.code == .accessibilityNotTrusted }) {
            return "This Dictionary process does not have Accessibility permission. Authorize this exact app in System Settings, then retry."
        }
        if details.issues.contains(where: { $0.code == .noSelection }) {
            return "The focused text element reported an empty selection; clipboard fallback did not yield text. Select an English word and retry."
        }
        if details.issues.contains(where: { $0.code == .targetExtractionFailed }) {
            return "Selection data was returned but could not be read as text. Try manual lookup or check QA diagnostics."
        }
        if details.issues.contains(where: { $0.code == .axCallFailed }) {
            return "Accessibility could not read the target app; clipboard fallback did not yield text. Retry or use manual lookup."
        }
        return "The target app did not expose readable selected text, and clipboard fallback did not yield text. Try manual lookup or check QA diagnostics."
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

    init(isTrusted: @escaping () -> Bool, safari: @escaping () -> CapturedContext?,
         ax: @escaping () -> CaptureReport, clipboard: @escaping () async throws -> ClipboardCapture) {
        self.isTrusted = isTrusted; self.safari = safari; self.ax = ax; self.clipboard = clipboard
    }

    func capture(isSafari: Bool, isBooks: Bool = false) async throws -> CapturedContext {
        let trusted = isTrusted()
        var details = CaptureDetails(accessibilityTrusted: trusted)
        if isSafari {
            if var captured = safari() {
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
        if !isBooks, var captured = report.captured {
            details.strategy = report.details.strategy; details.includeQuality(captured.capture); captured.diagnostics = details; return captured
        }
        let result: ClipboardCapture
        do { result = try await clipboard() }
        catch {
            details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: .interrupted))
            throw CaptureFailure(details: details)
        }
        try Task.checkCancellation()
        if let text = result.text.map({ isBooks ? SelectionLocation.trim($0) : $0 }), !text.isEmpty {
            // Books can append a citation to copied passages. Do not guess which
            // portion was selected or submit the citation as the lookup target.
            if isBooks && (text.utf16.count > 2000 || text.unicodeScalars.contains(where: CharacterSet.newlines.contains)) {
                details.add(CaptureIssue(code: .clipboardFallbackFailed, clipboardReason: .unusableText))
                throw CaptureFailure(details: details)
            }
            var reason: CaptureReason = .contextUnavailable
            if isBooks, let before = report.booksSelection {
                let after = ax()
                if let current = after.booksSelection, BooksSelectionReader.matches(before, current) {
                    var recovered = ContextExtractor.contextForCopiedBooksTarget(text, text: current.text)
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
}
