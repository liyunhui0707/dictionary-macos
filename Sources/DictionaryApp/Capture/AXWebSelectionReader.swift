import ApplicationServices
import Foundation

/// WebKit exposes a document selection through text markers. Keep the marker
/// opaque: no private framework symbols or fabricated numeric offsets.
struct AXWebSelectionReader {
    struct Selection {
        let element: AXUIElement
        let marker: CFTypeRef
        let target: String
        let text: String
        var sentenceMarker: CFTypeRef? = nil
        var sentence: String? = nil
    }

    let read: (AXUIElement, AXAttribute) -> AXRead
    let parameter: (AXUIElement, AXParameterizedAttribute, CFTypeRef) -> AXRead
    let endpoint: (CFTypeRef, AXTextMarkerEndpoint) -> CFTypeRef?

    init(read: @escaping (AXUIElement, AXAttribute) -> AXRead,
         parameter: @escaping (AXUIElement, AXParameterizedAttribute, CFTypeRef) -> AXRead,
         endpoint: @escaping (CFTypeRef, AXTextMarkerEndpoint) -> CFTypeRef? = AXTextMarkerEndpoint.live) {
        self.read = read; self.parameter = parameter; self.endpoint = endpoint
    }

    func selection(in root: AXUIElement) -> Selection? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        guard let documents = webAreas(in: root, deadline: deadline) else { return nil }
        var candidate: Selection?
        for element in documents {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            switch read(element, .selectedTextMarkerRange) {
            case .value(let marker):
                guard case .value(let value) = parameter(element, .stringForTextMarkerRange, marker),
                      let selected = value as? String else { return nil }
                let target = SelectionLocation.trim(selected)
                if !target.isEmpty {
                    guard candidate == nil, target.utf16.count <= 2000 else { return nil }
                    if let sentence = selectedSentence(element, marker: marker) {
                        candidate = Selection(element: element, marker: marker, target: target,
                            text: sentence.text, sentenceMarker: sentence.marker, sentence: sentence.text)
                    } else {
                        guard let text = documentText(element, deadline: deadline) else { return nil }
                        candidate = Selection(element: element, marker: marker, target: target, text: text)
                    }
                }
            case .failure(let error) where error == .attributeUnsupported || error == .noValue: break
            case .failure: return nil
            }
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? candidate : nil
    }

    /// Ask WebKit for frames rather than reading every paragraph's structure.
    /// Include the root and every returned frame so competing selections still fail closed.
    private func webAreas(in root: AXUIElement, deadline: TimeInterval) -> [AXUIElement]? {
        guard case .value(let role) = read(root, .role), role as? String == "AXWebArea" else { return nil }
        let limit = 65
        let predicate = ["AXSearchKey": "AXFrameSearchKey", "AXResultsLimit": limit,
                         "AXDirection": "AXDirectionNext", "AXVisibleOnly": false,
                         "AXImmediateDescendantsOnly": false] as CFDictionary
        switch parameter(root, .elementsForSearchPredicate, predicate) {
        case .value(let value):
            // Hitting the requested cap cannot prove that all frames were returned.
            guard let entries = value as? [AnyObject], entries.count < limit else { return nil }
            var documents = [root]
            for entry in entries {
                let value: CFTypeRef? = CFGetTypeID(entry) == AXUIElementGetTypeID() ? entry :
                    (entry as? [String: Any])?["AXSearchResultElement"] as CFTypeRef?
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
                      ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                let element = value as! AXUIElement
                guard case .value(let role) = read(element, .role), role as? String == "AXWebArea",
                      belongs(element, to: root, deadline: deadline) else { return nil }
                if !documents.contains(where: { CFEqual($0, element) }) { documents.append(element) }
            }
            return documents
        case .failure(let error) where error == .attributeUnsupported || error == .parameterizedAttributeUnsupported ||
            error == .notImplemented || error == .noValue:
            return walkWebAreas(in: root, deadline: deadline)
        case .failure: return nil
        }
    }

    private func belongs(_ element: AXUIElement, to root: AXUIElement, deadline: TimeInterval) -> Bool {
        var current = element
        var seen: [AXUIElement] = []
        for _ in 0...16 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            if CFEqual(current, root) { return true }
            guard !seen.contains(where: { CFEqual($0, current) }),
                  case .value(let parent) = read(current, .parent),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            seen.append(current)
            current = parent as! AXUIElement
        }
        return false
    }

    private func walkWebAreas(in root: AXUIElement, deadline: TimeInterval) -> [AXUIElement]? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [AXUIElement] = []
        var documents: [AXUIElement] = []
        while let (element, depth) = pending.popLast() {
            guard depth <= 16, seen.count < 4000, ProcessInfo.processInfo.systemUptime < deadline,
                  !seen.contains(where: { CFEqual($0, element) }),
                  case .value(let roleValue) = read(element, .role), let role = roleValue as? String else { return nil }
            seen.append(element)
            if role == "AXWebArea" { documents.append(element) }
            // Discovery needs roles and container structure, never all chapter text.
            if role == "AXStaticText" { continue }
            guard let children = children(of: element, role: role),
                  children.count <= 4000 - seen.count - pending.count else { return nil }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? documents : nil
    }

    /// Both selection endpoints must resolve to the same bounded native sentence.
    /// Repeated words elsewhere in a chapter cannot invalidate this local evidence.
    private func selectedSentence(_ element: AXUIElement, marker: CFTypeRef) -> (marker: CFTypeRef, text: String)? {
        guard let start = endpoint(marker, .start), let end = endpoint(marker, .end),
              case .value(let first) = parameter(element, .sentenceForTextMarker, start),
              case .value(let last) = parameter(element, .sentenceForTextMarker, end), CFEqual(first, last),
              case .value(let lengthValue) = parameter(element, .lengthForTextMarkerRange, first),
              let length = lengthValue as? Int, length > 0, length <= 8000,
              case .value(let textValue) = parameter(element, .stringForTextMarkerRange, first),
              let raw = textValue as? String, raw.utf16.count == length else { return nil }
        let text = SelectionLocation.trim(raw)
        return text.isEmpty ? nil : (first, text)
    }

    private func children(of element: AXUIElement, role: String) -> [AXUIElement]? {
        switch read(element, .children) {
        case .value(let value): return value as? [AXUIElement]
        case .failure(let error) where error == .attributeUnsupported || error == .noValue:
            // Observed native leaves can omit AXChildren entirely.
            return ["AXStaticText", "AXButton", "AXMenuButton", "AXTextField", "AXSlider", "AXValueIndicator"].contains(role) ? [] : nil
        case .failure: return nil
        }
    }

    private func documentText(_ root: AXUIElement, deadline: TimeInterval) -> String? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [AXUIElement] = []
        var pieces: [String] = []
        var units = 0
        while let (element, depth) = pending.popLast() {
            guard depth <= 16, seen.count < 512, ProcessInfo.processInfo.systemUptime < deadline,
                  !seen.contains(where: { CFEqual($0, element) }),
                  case .value(let roleValue) = read(element, .role), let role = roleValue as? String else { return nil }
            seen.append(element)
            if role == "AXWebArea", !CFEqual(root, element) { continue }
            if role == "AXStaticText" {
                guard case .value(let value) = read(element, .value), let text = value as? String else { return nil }
                units += text.utf16.count + (pieces.isEmpty ? 0 : 1)
                guard units <= 8000 else { return nil }
                pieces.append(text)
                continue
            }
            guard let children = children(of: element, role: role),
                  children.count <= 512 - seen.count - pending.count else { return nil }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " ")
    }

    static func matches(_ first: Selection, _ second: Selection) -> Bool {
        CFEqual(first.element, second.element) && CFEqual(first.marker, second.marker) &&
        SelectionLocation.sameUnits(first.target, second.target) && SelectionLocation.sameUnits(first.text, second.text) &&
        first.sentence == second.sentence &&
        (first.sentenceMarker.map { firstMarker in second.sentenceMarker.map { CFEqual(firstMarker, $0) } ?? false } ?? (second.sentenceMarker == nil))
    }
}
