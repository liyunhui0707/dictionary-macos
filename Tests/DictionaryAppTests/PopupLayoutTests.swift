import AppKit
import SwiftUI
import Testing
@testable import DictionaryApp

/// Test-owned, never-ordered-front hosting windows; not desktop or focus acceptance.
@MainActor
@Suite(.serialized)
struct PopupLayoutTests {
    private let source = "We sat on the bank of the river."

    @Test func overflowingResultKeepsAnAISummaryWithoutLeakingItIntoTheNextRequest() throws {
        let request = try LookupRequest.manual(target: "bank", context: "")
        let state = PopupState()
        let view = TranslationPopupView(state: state, onClose: {})
        state.phase = result(request, meaning: "河岸")
        state.contentHeight = 200
        #expect(view.toolbarTitle == "Dictionary")
        state.contentHeight = 900
        #expect(view.toolbarTitle == "bank · AI 建议：河岸")
        for phase in [LookupPhase.loading(request), .finished(request, .cancelled),
                      .finished(request, .failure("Synthetic error", rawOutput: nil)), .idle] {
            state.phase = phase
            #expect(view.toolbarTitle == "Dictionary")
        }
        state.phase = result(try .manual(target: "spring", context: ""), meaning: "泉水")
        #expect(view.toolbarTitle == "spring · AI 建议：泉水")
        state.contentHeight = 100
        #expect(view.toolbarTitle == "Dictionary")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func shortWordOnlyResultIsCompact(appearance: ColorScheme) async throws {
        let request = try LookupRequest.captured(target: "bank", context: nil, sentence: nil, source: "Synthetic",
            capture: SelectionLocation(reliability: .targetOnly, method: .clipboard))
        let size = try await size(of: request, meaning: "银行；河岸", appearance: appearance,
                                  preview: appearance == .light ? "word-only-light" : "word-only-dark")
        #expect(size.height < 300)
        #expect(size.width <= 460)
    }

    @Test func cloudControlsAreMeasuredOutsideScrollingAndRemainWithinScreen() async throws {
        let request = try LookupRequest.manual(target: "bank", context: "We sat on the bank of the river.")
        let provider = ControlledProvider()
        let cloud = CloudAssistanceState(provider: provider)
        cloud.prepare(request)
        let state = PopupState()
        state.availableSize = CGSize(width: 420, height: 380)
        state.phase = result(request, meaning: String(repeating: "Original meaning ", count: 100))
        _ = try await withHosting(state, cloud: cloud) { hosting in
            let initial = try await settle(hosting)
            #expect(state.cloudControlsHeight > 28)
            #expect(initial.height <= 380)
            let scroll = try #require(findScrollView(hosting))
            let document = try #require(scroll.documentView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(scroll.contentView.bounds.minY > 0)
            let offer = try #require(cloud.offer)
            let task = try #require(cloud.ask(offerID: offer.id))
            let call = await provider.waitForCall("bank")
            await provider.succeed(call, meaning: String(repeating: "河岸 ", count: 100))
            await task.value
            let completed = try await settle(hosting)
            #expect(state.cloudControlsHeight > 28)
            #expect(completed.height <= 380)
            #expect(scroll.contentView.bounds.minY < 1)
            #expect(TranslationPopupView(state: state, onClose: {}, cloud: cloud).toolbarTitle.contains("DeepSeek AI"))
            return completed
        }
    }

    @Test func shortSentenceAndTranslationFitWithoutAnEmptyFixedViewport() async throws {
        let request = try LookupRequest.captured(target: "bank", context: source, sentence: source, source: "Synthetic",
            capture: captureMetadata(start: 14, end: 18, sentenceStart: 0, sentenceEnd: 32))
        let size = try await size(of: request, meaning: "河岸", example: "我们坐在河岸上。", preview: "short-light")
        #expect(size.height < 360)
    }

    @Test func longSentenceAndTranslationUseABoundedLargerViewport() async throws {
        let source = "The bank " + String(repeating: "beside the winding river ", count: 30) + "was quiet."
        let request = try LookupRequest.captured(target: "bank", context: source, sentence: source, source: "Synthetic",
            capture: captureMetadata(start: 4, end: 8, sentenceStart: 0, sentenceEnd: source.utf16.count))
        let size = try await size(of: request, meaning: "河岸", example: String(repeating: "蜿蜒河流旁的河岸很安静。", count: 60),
                                  appearance: .dark, preview: "long-dark")
        #expect(size.height >= 500)
        #expect(size.height <= 560)
    }

    @Test func unavailableSentenceDoesNotReserveSpaceForRejectedTranslation() async throws {
        let request = try LookupRequest.captured(target: "bank", context: source, sentence: nil, source: "Synthetic",
            capture: captureMetadata(start: 14, end: 18, reason: .sentenceUnavailable))
        let size = try await size(of: request, meaning: "河岸", example: String(repeating: "REJECTED ", count: 500),
                                  preview: "sentence-unavailable")
        #expect(size.height < 320)
        #expect(LookupResultPresentation(request: request).sentence == nil)
    }

    @Test func smallScreenBoundsLimitTheActualHostedView() async throws {
        let request = try LookupRequest.manual(target: "bank", context: "")
        let size = try await size(of: request, meaning: String(repeating: "Synthetic meaning ", count: 200),
                                  available: NSSize(width: 300, height: 240))
        #expect(size.width <= 300 && size.height <= 240)
        #expect(size.height > 81) // the toolbar is reserved outside the scroll viewport
    }

    @Test func anExistingViewShrinksAgainAfterALongResult() async throws {
        let request = try LookupRequest.manual(target: "bank", context: "")
        let state = PopupState()
        state.phase = result(request, meaning: "河岸")
        _ = try await withHosting(state) { hosting in
            let short = try await settle(hosting)
            state.phase = result(request, meaning: String(repeating: "Long synthetic meaning ", count: 200))
            let long = try await settle(hosting)
            state.phase = result(request, meaning: "河岸")
            let restored = try await settle(hosting)
            #expect(long.height > short.height && long.height <= 560)
            #expect(abs(restored.height - short.height) <= 1)
            return restored
        }
    }

    @Test func loadingErrorAndCancellationRemainBounded() async throws {
        let request = try LookupRequest.manual(target: "bank", context: "")
        let state = PopupState()
        _ = try await withHosting(state) { hosting in
            for phase in [LookupPhase.loading(request), .finished(request, .failure("Synthetic error", rawOutput: nil)),
                          .finished(request, .cancelled)] {
                state.phase = phase
                let size = try await settle(hosting)
                #expect(size.height > 81 && size.height <= 560)
            }
            return hosting.fittingSize
        }
    }

    @Test func screenClampHandlesGrowthOversizeAndNegativeScreenOrigins() {
        let screen = NSRect(x: -1200, y: 40, width: 1000, height: 700)
        for frame in [NSRect(x: -1250, y: 0, width: 420, height: 560),
                      NSRect(x: -400, y: 600, width: 420, height: 560),
                      NSRect(x: -1200, y: 40, width: 1400, height: 900)] {
            let bounded = PopupScreenBounds.clamp(frame, to: screen)
            #expect(PopupScreenBounds.available(in: screen).contains(bounded))
        }
    }

    @Test func fittingPinnedPositionIsPreserved() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let chosen = NSRect(x: 300, y: 180, width: 420, height: 250)
        #expect(PopupScreenBounds.clamp(chosen, to: screen) == chosen)
    }

    @Test func secondaryMeaningsStartCollapsedAndLongContentCanScroll() async throws {
        let request = try LookupRequest.manual(target: "bank", context: "")
        let state = PopupState()
        state.phase = .finished(request, .success(LookupResult(request: request, translation:
            Translation(meaningInContext: "河岸", literalGloss: String(repeating: "General meaning ", count: 200),
                        partOfSpeech: "noun", exampleTranslation: nil, alternatives: ["银行"])) ))
        _ = try await withHosting(state) { hosting in
            #expect(try await settle(hosting).height < 300)
            state.phase = result(request, meaning: String(repeating: "Long meaning ", count: 200))
            _ = try await settle(hosting)
            let scroll = try #require(findScrollView(hosting))
            let document = try #require(scroll.documentView)
            #expect(document.frame.height > scroll.contentSize.height)
            return hosting.fittingSize
        }
    }

    // Render only this test's own hidden views; never capture the desktop or order a window front.
    // This is reviewable rendering evidence, not physical input/focus/desktop acceptance.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_POPUP_PREVIEWS"] != nil))
    func consolidatedOffscreenEvidence() async throws {
        let word = try LookupRequest.captured(target: "bank", context: nil, sentence: nil, source: "Synthetic",
            capture: SelectionLocation(reliability: .targetOnly, method: .clipboard))
        let ordinary = try LookupRequest.captured(target: "bank", context: source, sentence: source, source: "Synthetic",
            capture: captureMetadata(start: 14, end: 18, sentenceStart: 0, sentenceEnd: source.utf16.count))
        let unavailable = try LookupRequest.captured(target: "bank", context: source, sentence: nil, source: "Synthetic",
            capture: captureMetadata(start: 14, end: 18, reason: .sentenceUnavailable))
        let longSource = "The bank " + String(repeating: "beside the winding river ", count: 30) + "was quiet."
        let long = try LookupRequest.captured(target: "bank", context: longSource, sentence: longSource, source: "Synthetic",
            capture: captureMetadata(start: 4, end: 8, sentenceStart: 0, sentenceEnd: longSource.utf16.count))
        for appearance in [ColorScheme.light, .dark] {
            let suffix = appearance == .light ? "light" : "dark"
            for (name, request, meaning, example) in [
                ("word-only", word, "银行；河岸", "REJECTED TRANSLATION"),
                ("ordinary", ordinary, "河岸", "我们坐在河岸上。"),
                ("sentence-unavailable", unavailable, "河岸", "REJECTED TRANSLATION")
            ] {
                _ = try await size(of: request, meaning: meaning, example: example,
                                   appearance: appearance, preview: "\(name)-\(suffix)")
            }
            let state = PopupState()
            state.phase = result(long, meaning: "河岸", example: String(repeating: "蜿蜒河流旁的河岸很安静。", count: 30))
            _ = try await withHosting(state, appearance: appearance) { hosting in
                let size = try await settle(hosting)
                #expect(size.height <= 560)
                try savePreview(hosting, name: "long-top-\(suffix)")
                let scroll = try #require(findScrollView(hosting))
                let document = try #require(scroll.documentView)
                try #require(document.isFlipped)
                try #require(document.bounds.height > scroll.contentSize.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentSize.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                _ = try await settle(hosting)
                #expect(scroll.contentView.bounds.minY > 0)
                try savePreview(hosting, name: "long-bottom-\(suffix)")
                return size
            }
            let provider = ControlledProvider()
            let coordinator = LookupCoordinator(provider: provider)
            let operation = coordinator.submit(ordinary, to: .selection)
            let call = await provider.waitForCall("bank")
            state.phase = coordinator.selection
            _ = try await withHosting(state, appearance: appearance) { hosting in
                _ = try await settle(hosting)
                try savePreview(hosting, name: "loading-\(suffix)")
                try await Task.sleep(for: .seconds(6)) // real monotonic waiting, not a forged start time
                _ = try await settle(hosting)
                guard case .loading(_, let startedAt) = coordinator.selection else {
                    Issue.record("Expected the synthetic provider to remain pending")
                    return hosting.fittingSize
                }
                let waiting = LookupWaitingPresentation(startedAt: startedAt, now: .now)
                #expect(waiting.title == "仍在处理中…")
                print("OFFSCREEN_WAIT \(suffix) elapsed=\(waiting.elapsed)")
                try savePreview(hosting, name: "delayed-loading-\(suffix)")
                await provider.succeed(call, meaning: "河岸", example: "我们坐在河岸上。")
                _ = await operation.value
                #expect(!coordinator.selection.isLoading)
                state.phase = coordinator.selection
                let completed = try await settle(hosting)
                try savePreview(hosting, name: "completed-\(suffix)")
                return completed
            }
            let cancelled = coordinator.submit(ordinary, to: .selection)
            let late = await provider.waitForCall("bank", occurrence: 2)
            coordinator.dismissSelection() // same operation used by PopupController.close
            #expect(await cancelled.value.isCancelled)
            await provider.succeed(late)
            await cancelled.providerTask?.value
            guard case .idle = coordinator.selection else {
                Issue.record("A late result must not restore cancelled selection content")
                return
            }
            print("OFFSCREEN_CANCEL \(suffix) selection=idle lateResultIgnored=true; desktop dismissal not exercised")
        }
    }

    // Opt-in, owner-operated desktop batch. No generated input, live provider or service calls.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_POPUP_VISUAL_CHECK"] == "1"),
          .timeLimit(.minutes(5)))
    func concentratedVisualAcceptance() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["DICTIONARY_POPUP_GUI_OUTPUT"])
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try #require(directory.lastPathComponent == "gui-polish-2026-10-30")
        try #require(directory.resolvingSymlinksInPath().path == directory.path)
        let app = NSApplication.shared
        let previousWindows = Set(app.windows.map(ObjectIdentifier.init))
        let originalPID = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        try #require(originalPID != ProcessInfo.processInfo.processIdentifier)
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let popup = PopupController(coordinator: coordinator)
        defer { popup.close() }
        var records: [[String: Any]] = []
        var outsideClicks = 0
        let monitor = try #require(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            Task { @MainActor in outsideClicks += 1 }
        })
        defer { NSEvent.removeMonitor(monitor) }
        func record(_ stage: String, panel: NSPanel) throws {
            let entry: [String: Any] = ["stage": stage, "time": Date().timeIntervalSince1970,
                "testPID": ProcessInfo.processInfo.processIdentifier, "window": panel.windowNumber,
                "visible": panel.isVisible, "originalPID": originalPID,
                "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "outsideClicks": outsideClicks]
            records.append(entry)
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("stages.json"), options: .atomic)
            print("POPUP_GUI stage=\(stage) visible=\(panel.isVisible)")
        }
        func waitFor(_ stage: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try #require(condition(), "Interaction not observed: \(stage)")
        }
        func checkFocus(_ panel: NSPanel) throws {
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == originalPID,
                         "Original application lost foreground focus")
            if panel.isVisible { try #require(panel.screen?.visibleFrame.contains(panel.frame) == true) }
        }
        func capture(_ name: String, panel: NSPanel) throws {
            // Own-view bitmap while visible, not a composited desktop/material screenshot.
            try #require(panel.isVisible && panel.occlusionState.contains(.visible))
            let view = try #require(panel.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
        }
        let short = try LookupRequest.captured(target: "bank", context: source, sentence: source, source: "Synthetic",
            capture: captureMetadata(start: 14, end: 18, sentenceStart: 0, sentenceEnd: source.utf16.count))
        let first = coordinator.submit(short, to: .selection)
        let firstCall = await provider.waitForCall("bank")
        await provider.succeed(firstCall, meaning: "河岸", example: "我们坐在河岸上。")
        try #require(await first.value.result != nil)
        let windows = app.windows.filter { !previousWindows.contains(ObjectIdentifier($0)) }
        try #require(windows.count == 1)
        let panel = try #require(windows.first as? NSPanel)
        let hosting = try #require(panel.contentViewController as? NSHostingController<TranslationPopupView>)
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .seconds(1))
        try checkFocus(panel)
        try capture("light", panel: panel)
        try record("LIGHT_CLICK_PIN", panel: panel)
        try await waitFor("Pin", { hosting.rootView.state.isPinned })
        try checkFocus(panel)
        let beforePinnedOutside = outsideClicks
        try record("PINNED_CLICK_ORIGINAL_APP", panel: panel)
        try await waitFor("outside click while pinned", { outsideClicks > beforePinnedOutside })
        try await Task.sleep(for: .milliseconds(400))
        try #require(panel.isVisible && hosting.rootView.state.isPinned)
        try checkFocus(panel)
        try capture("pinned", panel: panel)
        try record("CLICK_UNPIN_THEN_ORIGINAL_APP", panel: panel)
        try await waitFor("Unpin", { !hosting.rootView.state.isPinned })
        let beforeUnpinnedOutside = outsideClicks
        try await waitFor("outside click while unpinned", { outsideClicks > beforeUnpinnedOutside })
        try await waitFor("outside dismissal", { !panel.isVisible })
        try checkFocus(panel)
        try record("OUTSIDE_DISMISSED", panel: panel)
        try await Task.sleep(for: .seconds(2))

        let longSource = "The bank " + String(repeating: "beside the winding river ", count: 30) + "was quiet."
        let long = try LookupRequest.captured(target: "bank", context: longSource, sentence: longSource, source: "Synthetic",
            capture: captureMetadata(start: 4, end: 8, sentenceStart: 0, sentenceEnd: longSource.utf16.count))
        let second = coordinator.submit(long, to: .selection)
        let secondCall = await provider.waitForCall("bank", occurrence: 2)
        await provider.succeed(secondCall, meaning: "河岸", example: String(repeating: "蜿蜒河流旁的河岸很安静。", count: 30))
        try #require(await second.value.result != nil)
        panel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .seconds(1))
        try checkFocus(panel)
        try capture("dark-long-top", panel: panel)
        try record("DARK_SCROLL_THEN_CLICK_CLOSE", panel: panel)
        let scroll = try #require(findScrollView(hosting.view))
        let initialScrollY = scroll.contentView.bounds.minY
        try await waitFor("scroll", { scroll.contentView.bounds.minY > initialScrollY + 30 })
        try #require(hosting.rootView.toolbarTitle == "bank · AI 建议：河岸")
        try capture("dark-long-scrolled", panel: panel)
        try await waitFor("Close", { !panel.isVisible })
        try checkFocus(panel)
        try record("CLOSED", panel: panel)
        try await Task.sleep(for: .seconds(2))

        let pending = coordinator.submit(short, to: .selection)
        let pendingCall = await provider.waitForCall("bank", occurrence: 3)
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .seconds(1))
        try capture("loading", panel: panel)
        try record("WAIT_FOR_STILL_WORKING_THEN_CLICK_CANCEL", panel: panel)
        try await Task.sleep(for: .seconds(5))
        try capture("delayed-loading", panel: panel)
        try await waitFor("Cancel", { !panel.isVisible })
        try #require(await pending.value.isCancelled)
        await provider.succeed(pendingCall, meaning: "LATE RESULT MUST NOT REAPPEAR")
        await pending.providerTask?.value
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1))
            try #require(!panel.isVisible)
            guard case .idle = coordinator.selection else { Issue.record("Late result restored selection"); return }
        }
        try checkFocus(panel)
        try #require(await provider.calls.count == 3)
        try record("COMPLETE_CANCELLED_AND_STAYED_HIDDEN", panel: panel)
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }

    private func result(_ request: LookupRequest, meaning: String, example: String? = nil) -> LookupPhase {
        .finished(request, .success(LookupResult(request: request, translation:
            Translation(meaningInContext: meaning, literalGloss: nil, partOfSpeech: nil,
                        exampleTranslation: example, alternatives: nil))))
    }

    private func size(of request: LookupRequest, meaning: String, example: String? = nil,
                      appearance: ColorScheme = .light, available: NSSize = NSSize(width: 420, height: 560),
                      preview: String? = nil) async throws -> NSSize {
        let state = PopupState()
        state.availableSize = available
        state.phase = result(request, meaning: meaning, example: example)
        return try await withHosting(state, appearance: appearance) { hosting in
            let size = try await settle(hosting)
            if let preview { try savePreview(hosting, name: preview) }
            return size
        }
    }

    private func savePreview(_ hosting: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DICTIONARY_POPUP_PREVIEWS"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try #require(directory.lastPathComponent == "popup-layout-2026-10-30" || directory.lastPathComponent.hasPrefix("native-design-"))
        try #require(hosting.window?.isVisible == false)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
        print("OFFSCREEN_POPUP \(name) width=\(hosting.bounds.width) height=\(hosting.bounds.height)")
    }

    private func withHosting(_ state: PopupState, appearance: ColorScheme = .light, cloud: CloudAssistanceState? = nil,
                             check: (NSView) async throws -> NSSize) async throws -> NSSize {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: TranslationPopupView(state: state, onClose: {}, cloud: cloud)
            .environment(\.colorScheme, appearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        let size = try await check(hosting)
        #expect(!window.isVisible)
        #expect(size.width.isFinite && size.height.isFinite)
        return size
    }

    private func settle(_ hosting: NSView) async throws -> NSSize {
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            hosting.window?.setContentSize(hosting.fittingSize)
            try await Task.sleep(for: .milliseconds(20))
        }
        return hosting.fittingSize
    }
}
