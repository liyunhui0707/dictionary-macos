import ApplicationServices
import Foundation

/// Books can focus a container while exposing the selection on a static-text child.
/// Never infer the selected occurrence by searching the page for a word.
struct BooksSelectionReader {
    struct Selection {
        let element: AXUIElement
        let target: String
        let text: String
        let span: UTF16Span
    }

    let read: (AXUIElement, AXAttribute) -> AXRead

    func selection(in root: AXUIElement) -> Selection? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [AXUIElement] = []
        var candidate: Selection?
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while let (element, depth) = pending.popLast() {
            guard depth <= 16, seen.count < 512,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  !seen.contains(where: { CFEqual($0, element) }) else { return nil }
            seen.append(element)
            guard case .value(let roleValue) = read(element, .role), let role = roleValue as? String else { return nil }
            if role == "AXStaticText" {
                // Empty selections on headings can have meaningless, nonzero ranges.
                let selected: String
                switch read(element, .selectedText) {
                case .value(let value):
                    guard let string = value as? String else { return nil }
                    selected = SelectionLocation.trim(string)
                case .failure(let error) where error == .attributeUnsupported || error == .noValue:
                    continue
                case .failure: return nil
                }
                if selected.isEmpty { continue }
                guard candidate == nil, selected.utf16.count <= 2000,
                      case .value(let value) = read(element, .value), let text = value as? String,
                      case .value(let rangeValue) = read(element, .selectedTextRange),
                      CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
                var range = CFRange()
                guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
                      range.location >= 0, range.length > 0,
                      range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
                let span = UTF16Span(start: range.location, end: range.location + range.length)
                guard let slice = span.slice(in: text),
                      SelectionLocation.sameUnits(SelectionLocation.trim(slice), selected) else { return nil }
                candidate = Selection(element: element, target: selected, text: text, span: span)
                continue
            }
            guard case .value(let value) = read(element, .children), let children = value as? [AXUIElement],
                  children.count <= 512 - seen.count - pending.count else { return nil }
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return candidate
    }

    static func matches(_ first: Selection, _ second: Selection) -> Bool {
        CFEqual(first.element, second.element) && first.span == second.span &&
        SelectionLocation.sameUnits(first.target, second.target) &&
        SelectionLocation.sameUnits(first.text, second.text)
    }
}
