import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct SelectionReaderTests {
    @Test func noChangeDoesNotReturnOldClipboardAsSelection() async throws {
        let board = FakeSelectionPasteboard("private old")
        let reader = SelectionReader(pasteboard: board, copy: { true }, wait: {}, now: advancingClock())
        let result = try await reader.readSelectionResult()
        #expect(result.text == nil && result.failure == .unchanged)
        #expect(board.text == "private old")
    }

    @Test func changedClipboardSuccessAndEmptyAreDistinctAndCleanupCompletes() async throws {
        for text in ["bank", " "] {
            let board = FakeSelectionPasteboard("previous")
            let reader = SelectionReader(pasteboard: board, copy: { board.replace(text); return true }, wait: {}, now: advancingClock())
            let result = try await reader.readSelectionResult()
            #expect(result.text == (text == "bank" ? "bank" : nil))
            #expect(result.failure == (text == "bank" ? nil : .unusableText))
            #expect(board.text == "previous")
        }
    }

    @Test func copyEventCreationFailureIsNotMisreportedAsNoSelection() async throws {
        let board = FakeSelectionPasteboard("previous")
        let reader = SelectionReader(pasteboard: board, copy: { false }, wait: {}, now: advancingClock())
        let result = try await reader.readSelectionResult()
        #expect(result.failure == .eventsUnavailable)
        #expect(board.text == "previous")
    }

    @Test func interruptedWaitStillRestoresClipboardBeforeReturning() async {
        let board = FakeSelectionPasteboard("previous")
        let reader = SelectionReader(pasteboard: board, copy: { true }, wait: {
            board.replace("copied"); throw CancellationError()
        }, now: { Date(timeIntervalSince1970: 0) })
        do { _ = try await reader.readSelectionResult(); Issue.record("Expected interruption") }
        catch { #expect(error is CancellationError) }
        #expect(board.text == "previous")
    }

    @Test func copyingPreservesRichMultipleItemsImagesAndEmptyBoard() async throws {
        for items: [[String: Data]] in [[], [["image": Data([1, 2, 3])]],
            [["text": Data("bank".utf8), "rich": Data([4, 5])], ["file": Data([6])]]] {
            let board = FakeSelectionPasteboard(nil)
            board.items = items
            let reader = SelectionReader(pasteboard: board, copy: { board.replace("bank"); return true }, wait: {}, now: advancingClock())
            let result = try await reader.readSelectionResult()
            #expect(result.text == "bank")
            #expect(board.items == items)
        }
    }

    @Test func unreadableClipboardIsNotOverwritten() async throws {
        let board = FakeSelectionPasteboard(nil)
        board.canSnapshot = false
        let reader = SelectionReader(pasteboard: board, copy: { Issue.record("Must preserve before copying"); return true })
        let result = try await reader.readSelectionResult()
        #expect(result.text == nil && result.failure == .unpreservableContents)
        #expect(board.changeCount == 0)
    }

    @Test func failedRestorationDoesNotReportSuccessfulCapture() async throws {
        let board = FakeSelectionPasteboard("previous")
        board.canRestore = false
        let reader = SelectionReader(pasteboard: board, copy: { board.replace("bank"); return true })
        let result = try await reader.readSelectionResult()
        #expect(result.text == nil)
        #expect(result.failure?.rawValue == "restorationFailed")
    }

    @Test func restorationFailureDuringInterruptionRemainsVisible() async throws {
        let board = FakeSelectionPasteboard("previous")
        board.canRestore = false
        let reader = SelectionReader(pasteboard: board, copy: { true }, wait: {
            board.replace("copied"); throw CancellationError()
        })
        let result = try await reader.readSelectionResult()
        #expect(result.text == nil && result.failure == .restorationFailed)
    }

    private func advancingClock() -> () -> Date {
        var tick = 0.0
        return { tick += 1; return Date(timeIntervalSince1970: tick) }
    }
}

@MainActor
private final class FakeSelectionPasteboard: SelectionPasteboard {
    var items: [[String: Data]]
    var canSnapshot = true
    var canRestore = true
    var text: String? { items.first?["text"].flatMap { String(data: $0, encoding: .utf8) } }
    var changeCount = 0
    init(_ text: String?) { items = text.map { [["text": Data($0.utf8)]] } ?? [] }
    func replace(_ string: String) { items = [["text": Data(string.utf8)]]; changeCount += 1 }
    func snapshot() -> [[String: Data]]? { canSnapshot ? items : nil }
    func restore(_ items: [[String: Data]]) -> Bool {
        guard canRestore else { return false }
        self.items = items; changeCount += 1
        return true
    }
}
