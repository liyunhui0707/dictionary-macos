import AppKit

@MainActor
protocol SelectionPasteboard {
    var text: String? { get }
    var changeCount: Int { get }
    func snapshot() -> [[String: Data]]?
    @discardableResult func restore(_ items: [[String: Data]]) -> Bool
}

@MainActor
struct SystemSelectionPasteboard: SelectionPasteboard {
    let board: NSPasteboard
    init(board: NSPasteboard = .general) { self.board = board }
    var text: String? { board.string(forType: .string) }
    var changeCount: Int { board.changeCount }
    func snapshot() -> [[String: Data]]? {
        var result: [[String: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var formats: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                formats[type.rawValue] = data
            }
            result.append(formats)
        }
        return result
    }
    @discardableResult
    func restore(_ items: [[String: Data]]) -> Bool {
        var restored: [NSPasteboardItem] = []
        for formats in items {
            guard !formats.isEmpty else { return false }
            let item = NSPasteboardItem()
            for (type, data) in formats {
                guard item.setData(data, forType: .init(type)) else { return false }
            }
            restored.append(item)
        }
        board.clearContents()
        return restored.isEmpty || board.writeObjects(restored)
    }
}

@MainActor
final class SelectionReader {
    private let pasteboard: SelectionPasteboard
    private let copy: () -> Bool
    private let wait: () async throws -> Void
    private let now: () -> Date

    init(pasteboard: SelectionPasteboard? = nil, copy: (() -> Bool)? = nil,
         wait: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 20_000_000) },
         now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard ?? SystemSelectionPasteboard()
        self.copy = copy ?? Self.simulateCmdC
        self.wait = wait; self.now = now
    }

    func readSelection() async throws -> String? { try await readSelectionResult().text }

    func readSelectionResult() async throws -> ClipboardCapture {
        let previousChangeCount = pasteboard.changeCount
        guard let previousItems = pasteboard.snapshot(), pasteboard.changeCount == previousChangeCount else {
            return ClipboardCapture(text: nil, failure: .unpreservableContents)
        }
        // Preserve every materialized format and item, including an empty board.
        // A copy with identical plain text may still have replaced rich content.
        let outcome: Result<ClipboardCapture, Error>
        do { outcome = .success(try await copySelection(after: previousChangeCount)) }
        catch { outcome = .failure(error) }
        // Complete cleanup before returning success or propagating cancellation.
        // A failed native write must not be reported as a successful lookup.
        if pasteboard.changeCount != previousChangeCount, !pasteboard.restore(previousItems) {
            return ClipboardCapture(text: nil, failure: .restorationFailed)
        }
        return try outcome.get()
    }

    private func copySelection(after previousChangeCount: Int) async throws -> ClipboardCapture {
        guard copy() else { return ClipboardCapture(text: nil, failure: .eventsUnavailable) }
        let deadline = now().addingTimeInterval(0.5)
        while pasteboard.changeCount == previousChangeCount, now() < deadline {
            try await wait()
        }
        guard pasteboard.changeCount != previousChangeCount else { return ClipboardCapture(text: nil, failure: .unchanged) }
        let captured = pasteboard.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captured, !captured.isEmpty else { return ClipboardCapture(text: nil, failure: .unusableText) }
        return ClipboardCapture(text: captured, failure: nil)
    }

    private static func simulateCmdC() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 0x08
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true // Events created/posted, not a delivery acknowledgement.
    }
}
