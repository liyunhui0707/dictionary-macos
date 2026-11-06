import AppKit
import SwiftUI
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PopupDismissalTests {
    // Opt-in desktop smoke. Never runs as part of an ordinary test invocation.
    // Its bitmap is an own-view render, not proof of Air desktop visibility;
    // an operator must separately confirm the real popup and Pro noninterference.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_AIR_POPUP_SMOKE"] == "1"))
    func airPopupVisibilitySmoke() async throws {
        let expectedHost = try #require(ProcessInfo.processInfo.environment["DICTIONARY_POPUP_TEST_HOST"])
        try #require(ProcessInfo.processInfo.hostName.split(separator: ".").first == expectedHost)
        let output = try #require(ProcessInfo.processInfo.environment["DICTIONARY_AIR_POPUP_OUTPUT"])
        try #require(output.range(of: #"^/private/tmp/dictionary-popup-air\.[A-Za-z0-9]+/evidence$"#,
                                  options: .regularExpression) != nil)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try #require(directory.resolvingSymlinksInPath().path == output)
        try #require((try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)

        let app = NSApplication.shared
        let previousWindows = Set(app.windows.map(ObjectIdentifier.init))
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        let target = "air-popup-smoke"
        let meaning = "AIR POPUP SMOKE: SYNTHETIC RESULT"
        let operation = coordinator.submit(try .manual(target: target, context: ""), to: .selection)
        let call = await provider.waitForCall(target)
        await provider.succeed(call, meaning: meaning)
        try #require(await operation.value.result != nil)

        let created = app.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) }
        try #require(created.count == 1)
        let panel = try #require(created.first as? NSPanel)
        try #require(panel.contentViewController is NSHostingController<TranslationPopupView>)
        let screen = try #require(panel.screen ?? NSScreen.main)
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.midY - panel.frame.height / 2))
        try await Task.sleep(for: .seconds(1))
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        try #require(panel.isVisible && panel.occlusionState.contains(.visible))
        try #require(screen.visibleFrame.contains(panel.frame))
        var visited = Set<ObjectIdentifier>()
        let displayed = try popupAccessibilityText(content, visited: &visited)
        try #require(displayed.contains(target))
        try #require(displayed.contains(meaning))
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("popup-own-view.png"), options: .withoutOverwriting)
        print("AIR_POPUP_SMOKE visible=true text=true pid=\(ProcessInfo.processInfo.processIdentifier) window=\(panel.windowNumber) holdSeconds=20")
        try await Task.sleep(for: .seconds(20))
        try #require(panel.isVisible)
        popup.close()
        try await Task.sleep(for: .seconds(1))
        #expect(!panel.isVisible)
        #expect(!panel.occlusionState.contains(.visible))
        #expect(await provider.calls.count == 1)
        guard case .idle = coordinator.selection else {
            Issue.record("Closing the production popup must leave selection idle")
            return
        }
        print("AIR_POPUP_SMOKE hidden=true provider=ControlledProvider calls=1")
    }

    private func popupAccessibilityText(_ element: Any, visited: inout Set<ObjectIdentifier>) throws -> [String] {
        guard let object = element as? NSObject else { return [] }
        guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
        try #require(visited.count <= 256)
        var text: [String] = []
        // Read only this test-owned view's accessibility subtree. No system AX
        // client, external application inspection or Accessibility permission.
        for name in ["accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector),
               let value = object.perform(selector)?.takeUnretainedValue() as? String {
                text.append(value)
            }
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: children),
           let values = object.perform(children)?.takeUnretainedValue() as? [Any] {
            for child in values { text += try popupAccessibilityText(child, visited: &visited) }
        }
        if let view = object as? NSView {
            for child in view.subviews { text += try popupAccessibilityText(child, visited: &visited) }
        }
        return text
    }

    @Test(arguments: [false, true])
    func outsideClickCancelsImmediatelyWithoutAffectingManualLookup(lateFailure: Bool) async throws {
        _ = NSApplication.shared
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        let manual = coordinator.submit(try .manual(target: "manual", context: ""), to: .manual)
        await provider.waitForCall("manual")
        let selection = coordinator.submit(try .manual(target: "selection", context: ""), to: .selection)
        await provider.waitForCall("selection")
        popup.outsideClickAction()()
        #expect(await selection.value.isCancelled)
        #expect(coordinator.manual.isLoading)
        if lateFailure { await provider.fail("selection") } else { await provider.succeed("selection") }
        await selection.providerTask?.value
        await provider.succeed("manual")
        #expect(await manual.value.result != nil)
        guard case .idle = coordinator.selection else {
            Issue.record("Late provider outcomes must not reopen the dismissed popup")
            return
        }
    }

    @Test(arguments: [false, true])
    func outsideClickStillDismissesAfterSameRequestCompletes(failure: Bool) async throws {
        _ = NSApplication.shared
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        let operation = coordinator.submit(try .manual(target: "bank", context: ""), to: .selection)
        await provider.waitForCall("bank")
        let dismiss = popup.outsideClickAction()
        if failure { await provider.fail("bank") } else { await provider.succeed("bank") }
        _ = await operation.value
        dismiss()
        guard case .idle = coordinator.selection else {
            Issue.record("The outside click must dismiss even after the same lookup finishes")
            return
        }
    }

    @Test func staleClickDoesNotCancelNewNativeCaptureBeforeItPublishes() async throws {
        _ = NSApplication.shared
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        let old = coordinator.submit(try .manual(target: "old", context: ""), to: .selection)
        await provider.waitForCall("old")
        await provider.succeed("old")
        _ = await old.value
        let dismiss = popup.outsideClickAction()
        let intent = coordinator.beginCapture()
        dismiss()
        // Capture has not published a loading phase yet, but is already the newer intent.
        #expect(coordinator.isCurrentCapture(intent))
    }

    @Test func staleClickDoesNotDismissNewRequest() async throws {
        _ = NSApplication.shared
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        let old = coordinator.submit(try .manual(target: "old", context: ""), to: .selection)
        await provider.waitForCall("old")
        let dismiss = popup.outsideClickAction()
        let new = coordinator.submit(try .manual(target: "new", context: ""), to: .selection)
        await provider.waitForCall("new")
        dismiss()
        #expect(coordinator.selection.isLoading)
        await provider.succeed("new")
        #expect(await new.value.result?.request.target == "new")
        await provider.succeed("old")
        await old.providerTask?.value
        #expect(await old.value.isCancelled)
    }

    @Test func clickDuringCaptureStillDismissesAfterCapturePublishes() async throws {
        _ = NSApplication.shared
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        let old = coordinator.submit(try .manual(target: "old", context: ""), to: .selection)
        await provider.waitForCall("old")
        await provider.succeed("old")
        _ = await old.value
        let intent = coordinator.beginCapture()
        let dismiss = popup.outsideClickAction()
        coordinator.finishCapture(intent, request: try .manual(target: "new", context: ""))
        await provider.waitForCall("new")
        dismiss()
        await provider.succeed("new")
        guard case .idle = coordinator.selection else {
            Issue.record("Capture and its translation must share the dismissal intent")
            return
        }
    }
}
