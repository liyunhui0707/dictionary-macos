import AppKit
import Testing
@testable import DictionaryApp

/// Real pasteboard service, isolated from the user's general clipboard. The copy
/// closure writes synthetic data; these tests do not prove physical Cmd-C delivery.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativePasteboardTests {
    @Test func invalidRestoreDoesNotClearExistingNativeContents() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = SystemSelectionPasteboard(board: board)
        try #require(adapter.restore([[NSPasteboard.PasteboardType.string.rawValue: Data("prior".utf8)]]))
        let before = try #require(adapter.snapshot())
        let count = adapter.changeCount
        #expect(adapter.restore([[:]]) == false)
        #expect(adapter.changeCount == count && adapter.snapshot() == before)
    }

    @Test func nativeFormatsAndMultipleItemsSurviveSameTextCopy() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = SystemSelectionPasteboard(board: board)
        let original: [[String: Data]] = [
            [NSPasteboard.PasteboardType.string.rawValue: Data("bank".utf8),
             NSPasteboard.PasteboardType.rtf.rawValue: Data("{\\rtf1 bank}".utf8)],
            ["org.dictionary.synthetic-binary": Data([0, 255, 1, 2])]
        ]
        adapter.restore(original)
        // macOS may synthesize additional representations (for example UTF-16).
        // Compare restoration with the actual native snapshot, retaining those too.
        let before = try #require(adapter.snapshot())
        try #require(before.count == original.count)
        for (item, expected) in zip(before, original) {
            for (type, data) in expected { try #require(item[type] == data) }
        }
        let reader = SelectionReader(pasteboard: adapter, copy: {
            board.clearContents()
            return board.setString("bank", forType: .string)
        })
        let result = try await reader.readSelectionResult()
        #expect(result.text == "bank" && result.failure == nil)
        #expect(adapter.snapshot() == before)
    }

    @Test func nativeEmptyClipboardIsRestored() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let adapter = SystemSelectionPasteboard(board: board)
        let reader = SelectionReader(pasteboard: adapter, copy: {
            board.clearContents()
            return board.setString("river", forType: .string)
        })
        #expect(try await reader.readSelectionResult().text == "river")
        #expect(adapter.snapshot() == [])
        #expect(adapter.text == nil)
    }

    @Test func nativeClipboardIsRestoredWhenWaitThrows() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = SystemSelectionPasteboard(board: board)
        let original = [[NSPasteboard.PasteboardType.string.rawValue: Data("synthetic prior content".utf8)]]
        adapter.restore(original)
        try #require(adapter.snapshot() == original)
        let reader = SelectionReader(pasteboard: adapter, copy: { true }, wait: {
            board.clearContents()
            board.setString("copied word", forType: .string)
            throw CancellationError()
        })
        do {
            _ = try await reader.readSelectionResult()
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(adapter.snapshot() == original)
    }

    @Test func newCaptureStartsOnlyAfterNativeClipboardRestoration() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let adapter = SystemSelectionPasteboard(board: board)
        let original = [[NSPasteboard.PasteboardType.string.rawValue: Data("synthetic previous".utf8)]]
        adapter.restore(original)
        try #require(adapter.snapshot() == original)
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let controller = SelectionCaptureController(coordinator: coordinator)
        var firstStarted = false
        var resumeCopy: CheckedContinuation<Void, Never>?
        let reader = SelectionReader(pasteboard: adapter, copy: { true }, wait: {
            firstStarted = true
            await withCheckedContinuation { resumeCopy = $0 }
            board.clearContents()
            board.setString("old", forType: .string)
        })
        controller.start(source: "Synthetic Books", isSourceCurrent: { true }) {
            let result = try await reader.readSelectionResult()
            return CapturedContext(target: result.text ?? "", context: "old", containingSentence: nil)
        }
        while !firstStarted { await Task.yield() }
        controller.start(source: "Synthetic Books", isSourceCurrent: { true }) {
            #expect(adapter.snapshot() == original)
            return CapturedContext(target: "new", context: "new", containingSentence: nil)
        }
        resumeCopy?.resume()
        await controller.task?.value
        let call = await provider.waitForCall("new")
        #expect(await provider.calls.map(\.target) == ["new"])
        coordinator.dismissSelection()
        await provider.succeed(call)
        #expect(adapter.snapshot() == original)
    }
}
