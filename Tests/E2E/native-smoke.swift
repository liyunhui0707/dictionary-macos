// Parameterized, bounded version of the successful 2026-10-25 native AX probe.
// No Apple Events, clipboard, document opening/writing, permission prompts or arbitrary keys.
import AppKit
import ApplicationServices
import Foundation

// BEGIN CONTEXTUAL MEANING
// Call only with the value of an independently identified contextual-meaning field.
// Never pass concatenated labels, Literal, Alternatives or sentence translation.
func assessContextualMeaning(fieldValue: String?, start: Int) -> [String: Any] {
    guard let value = fieldValue else { return ["status":"MANUAL_REQUIRED", "observed":false] }
    let matches = value.contains(start == 4 ? "银行" : "河岸") || (start == 41 && value.contains("河边"))
    return ["status": matches ? "PASS" : "FAIL", "observed":true, "field":"meaningInContext"]
}
// END CONTEXTUAL MEANING

struct GuardFailure: Error { let code: String }
func require(_ value: Bool, _ code: String) throws { if !value { throw GuardFailure(code: code) } }
func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
}
func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
    var nodes = [root], index = 0
    while index < nodes.count {
        let children = attribute(nodes[index], kAXChildrenAttribute) as? [AXUIElement] ?? []
        try require(nodes.count + children.count <= 2000, "axBudgetExceeded")
        nodes.append(contentsOf: children); index += 1
    }
    return nodes
}
func range(_ node: AXUIElement) throws -> CFRange {
    guard let value = attribute(node, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
        throw GuardFailure(code: "rangeUnavailable")
    }
    var result = CFRange()
    try require(AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &result), "rangeUnreadable")
    return result
}
func setRange(_ node: AXUIElement, _ start: Int, _ end: Int) throws {
    var selected = CFRange(location: start, length: end - start)
    guard let value = AXValueCreate(.cfRange, &selected) else { throw GuardFailure(code: "rangeCreationFailed") }
    try require(AXUIElementSetAttributeValue(node, kAXSelectedTextRangeAttribute as CFString, value) == .success, "rangeWriteFailed")
}
func emit(_ value: [String: Any]) {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
}

@main struct NativeSmoke {
    @MainActor static func main() {
        do {
            let args = CommandLine.arguments
            try require(args.count >= 5, "explicitArgumentsRequired")
            let mode = args[1], file = URL(fileURLWithPath: args[2]).standardizedFileURL
            guard let pid = Int32(args[3]), let start = Int(args[4]) else { throw GuardFailure(code: "invalidArguments") }
            try require([4, 41].contains(start), "unsupportedFixtureRange")
            try require(["guard", "select", "trigger", "popup", "dismiss", "restore"].contains(mode), "unsupportedMode")
            let base = "The bank approved my loan. We sat on the bank of the river."
            try require(try String(contentsOf: file, encoding: .utf8) == base + "\n", "fixtureChanged")
            try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "existingPermissionRequired")
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
                throw GuardFailure(code: "textEditNotRunning")
            }
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, "textEditMustRemainFrontmost")
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let owned = windows.filter { window in
                let document = attribute(window, kAXDocumentAttribute)
                let url = (document as? URL) ?? (document as? String).flatMap(URL.init(string:))
                return url?.standardizedFileURL == file
            }
            try require(owned.count == 1, "exactOwnedWindowRequired")
            // Require the owned document to be the active window, not just somewhere in TextEdit.
            guard let focused = attribute(root, kAXFocusedWindowAttribute) else { throw GuardFailure(code: "focusedWindowUnavailable") }
            try require(CFEqual(focused, owned[0]), "ownedWindowMustBeFocused")
            let texts = try descendants(owned[0]).filter { attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole }
            try require(texts.count == 1, "uniqueOwnedTextAreaRequired")
            let text = texts[0]
            let content = attribute(text, kAXValueAttribute) as? String
            try require(content == base || content == base + "\n", "ownedContentChanged")
            let original = try range(text)
            try require(original.location >= 0 && original.length >= 0 && original.location + original.length <= (base + "\n").utf16.count, "invalidOwnedRange")
            let dictionary = AXUIElementCreateApplication(pid)
            let popupWindows = (attribute(dictionary, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
                (attribute($0, kAXSubroleAttribute) as? String) != kAXStandardWindowSubrole
            }
            if mode == "guard" { try require(popupWindows.isEmpty, "closeExistingDictionaryPopupManually") }
            if mode == "select" { try setRange(text, start, start + 4) }
            if ["trigger", "popup", "dismiss", "restore"].contains(mode) {
                try require(original.location == start && original.length == 4 && attribute(text, kAXSelectedTextAttribute) as? String == "bank", "ownedSelectionChanged")
            }
            if mode == "trigger" {
                try require(popupWindows.isEmpty, "unexpectedPopupBeforeInput")
                let source = CGEventSource(stateID: .hidSystemState)
                // Construct all events before posting any modifier, so failure can't leave Option held.
                let sequence: [(CGKeyCode, Bool, CGEventFlags)] = [(58,true,.maskAlternate),(2,true,.maskAlternate),(2,false,.maskAlternate),(58,false,[])]
                let events = try sequence.map { key, down, flags -> CGEvent in
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { throw GuardFailure(code: "eventCreationFailed") }
                    event.flags = flags; return event
                }
                events.forEach { $0.post(tap: .cghidEventTap) }
            }
            if mode == "popup" || mode == "dismiss" {
                if mode == "dismiss" && popupWindows.isEmpty { emit(["dismissed":true]); return }
                try require(popupWindows.count == 1, "uniqueOwnedPopupRequired")
                let popup = popupWindows[0], nodes = try descendants(popup)
                // Caller has correlated this new popup to its own intent before reaching here.
                // Never read the Dictionary main/manual window. Return predicates, not model text.
                let labels = nodes.filter { attribute($0, kAXRoleAttribute) as? String == kAXStaticTextRole }.compactMap { attribute($0, kAXValueAttribute) as? String }
                let sentence = start == 4 ? "The bank approved my loan." : "We sat on the bank of the river."
                try require(labels.contains("SUBMITTED ENGLISH") && labels.contains("bank") && labels.contains(sentence), "popupOwnershipNotProven")
                if mode == "dismiss" {
                    // Use only a standard close/cancel action; never guess an unlabelled button.
                    if let close = attribute(popup, kAXCloseButtonAttribute) {
                        try require(CFGetTypeID(close) == AXUIElementGetTypeID(), "invalidPopupCloseAttribute")
                        let element = unsafeBitCast(close, to: AXUIElement.self)
                        try require(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success, "popupCloseFailed")
                    } else {
                        try require(AXUIElementPerformAction(popup, kAXCancelAction as CFString) == .success, "manualPopupCloseRequired")
                    }
                    emit(["dismissed":true]); return
                }
                emit(["sentence_matches":labels.contains(sentence), "original_sentence_label":labels.contains("Original sentence"),
                      // The current UI has no stable meaning-field identifier/label.
                      // Flat AX text order/typography cannot prove field ownership.
                      "meaningCheck":assessContextualMeaning(fieldValue:nil, start:start),
                      "sentence_translation_present":labels.contains("Sentence translation")]); return
            }
            if mode == "restore" {
                try require(args.count == 7, "restoreRangeRequired")
                guard let left = Int(args[5]), let right = Int(args[6]) else { throw GuardFailure(code: "restoreRangeInvalid") }
                try require(left >= 0 && right >= left && right <= (base + "\n").utf16.count, "restoreRangeInvalid")
                try setRange(text, left, right)
            }
            let selected = try range(text)
            emit(["TextEditPID":app.processIdentifier,"start":selected.location,"end":selected.location + selected.length,
                  "source_content_matches":true,"automatic_input_not_physical":mode == "trigger"])
        } catch let error as GuardFailure { emit(["blocked":true,"reason":error.code]) }
        catch { emit(["blocked":true,"reason":"fixtureReadFailed"]) }
    }
}
