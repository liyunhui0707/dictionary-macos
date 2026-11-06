import AppKit
import SwiftUI
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.serialized)
struct EditorLayoutTests {
    @Test(arguments: [false, true])
    func undoRedoSynchronizesDraft(contextField: Bool) throws {
        _ = NSApplication.shared
        let state = ManualLookupState(coordinator: LookupCoordinator(provider: ControlledProvider()))
        let binding = Binding<String>(
            get: { contextField ? state.context : state.target },
            set: { if contextField { state.context = $0 } else { state.target = $0 } })
        let hosting = NSHostingView(rootView: LookupTextEditor(text: binding, label: "Input", onSubmit: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let editor = try #require(findEditor(hosting))
        window.makeFirstResponder(editor)
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("river bank", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        #expect(binding.wrappedValue == "river bank")
        #expect(undo.canUndo)
        #expect(editor.tryToPerform(Selector(("undo:")), with: nil))
        #expect(editor.string.isEmpty)
        #expect(binding.wrappedValue.isEmpty)
        #expect(undo.canRedo)
        #expect(editor.tryToPerform(Selector(("redo:")), with: nil))
        #expect(editor.string == "river bank")
        #expect(binding.wrappedValue == "river bank")
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 6, length: 4))
        editor.deleteBackward(nil)
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        #expect(binding.wrappedValue == "river ")
        #expect(editor.tryToPerform(Selector(("undo:")), with: nil))
        #expect(editor.string == "river bank")
        #expect(binding.wrappedValue == "river bank")
    }

    @Test func emptyEditorFillsItsInputArea() throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: LookupTextEditor(text: .constant(""), label: "English", onSubmit: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        hosting.layoutSubtreeIfNeeded()
        let editor = try #require(findEditor(hosting))
        let scroll = try #require(editor.enclosingScrollView)
        scroll.tile()
        #expect(editor.frame.height >= scroll.contentSize.height)
        #expect(editor.frame.width >= scroll.contentSize.width)
    }

    @Test(arguments: ["", "river", "中文输入", "first line\nsecond line"])
    func searchPlaceholderAndGlyphsShareOrigin(value: String) async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: LookupTextEditor(text: .constant(value), label: "English",
            placeholder: "输入英文单词、短语或句子", centersFirstLine: true, onSubmit: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 46),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.contentView = hosting
        defer { window.close() }
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!window.isVisible)
        let editor = try #require(findEditor(hosting))
        let container = try #require(editor.textContainer)
        let layout = try #require(editor.layoutManager)
        let font = try #require(editor.font)
        layout.ensureLayout(for: container)
        #expect(editor.placeholderRect.origin == editor.textContainerOrigin)
        #expect(container.lineFragmentPadding == 0)
        let lineHeight = layout.defaultLineHeight(for: font)
        #expect(abs(editor.textContainerOrigin.y + lineHeight / 2 - 23) <= 0.5)
        if !value.isEmpty {
            let firstLine = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            #expect(abs(firstLine.minY) < 0.5)
            #expect(abs(firstLine.height - lineHeight) < 1)
        }
        #expect(editor.enclosingScrollView?.autohidesScrollers == true)
        if let output = ProcessInfo.processInfo.environment["DICTIONARY_UI_PREVIEWS"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            editor.drawsBackground = true
            editor.backgroundColor = .white
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = value.isEmpty ? "empty" : value == "river" ? "river" : value.contains("\n") ? "multiline" : "chinese"
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("editor-\(name).png"))
        }
    }

    @Test func commandReturnSubmitsButOrdinaryReturnDoesNot() throws {
        _ = NSApplication.shared
        let editor = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        let commandReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                        timestamp: 0, windowNumber: 0, context: nil,
                                                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: commandReturn)
        #expect(submissions == 1)
        editor.insertNewline(nil)
        #expect(submissions == 1)
        #expect(editor.string.contains("\n"))
    }

    @Test func commandReturnDuringMarkedTextDoesNotSubmit() throws {
        _ = NSApplication.shared
        var draft = ""
        var submissions = 0
        let binding = Binding<String>(get: { draft }, set: { draft = $0 })
        let hosting = NSHostingView(rootView: LookupTextEditor(text: binding, label: "English", onSubmit: { submissions += 1 }))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        hosting.layoutSubtreeIfNeeded()
        let editor = try #require(findEditor(hosting))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        #expect(submissions == 0)
        editor.unmarkText()
        #expect(draft == editor.string)
    }

    private func findEditor(_ view: NSView) -> SubmitTextView? {
        if let editor = view as? SubmitTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor($0) }.first
    }
}
