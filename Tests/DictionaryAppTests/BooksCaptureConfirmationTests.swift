import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct BooksCaptureConfirmationTests {
    @Test func copiedWordRecoversUniqueContextDespiteWrongNativeOffset() async throws {
        let page = "Earlier. Students learn from the class. It is hard, so we return to the lab. Later."
        for (visible, wrong) in [("from", "so"), ("Students", "to the"), ("class", "hard")] {
            let report = nativeSnapshot(wrong, text: page)
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
                ClipboardCapture(text: visible, failure: nil)
            })
            let captured = try await pipeline.capture(isSafari: false, isBooks: true)
            #expect(captured.target == visible)
            #expect(captured.containingSentence == "Students learn from the class.")
            #expect(captured.capture?.reliability == .heuristic)
            #expect(captured.capture?.range == nil && captured.capture?.sentenceRange == nil)
        }
    }

    @Test func copiedWordCannotRecoverFromChangedOrAmbiguousNativeText() async throws {
        let page = "Earlier. Students learn from the class. It is hard. Later."
        let first = nativeSnapshot("hard", text: page)
        for after in [nativeSnapshot("hard", text: page + " Changed."),
                      nativeSnapshot("hard", text: page, node: 25001),
                      CaptureReport(captured: nil, details: .init())] {
            var reads = 0
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: {
                reads += 1; return reads == 1 ? first : after
            }, clipboard: { ClipboardCapture(text: "Students", failure: nil) })
            let result = try await pipeline.capture(isSafari: false, isBooks: true)
            #expect(result.target == "Students" && result.context == "Students")
            #expect(result.containingSentence == nil && result.capture?.reliability == .targetOnly)
        }
        for text in ["Earlier. The bank closed. We sat on the bank. It is hard. Later.",
                     "Earlier. The river is here. It is hard. Later.",
                     String(repeating: "padding ", count: 1100) + "The bank closed. It is hard."] {
            let report = nativeSnapshot("hard", text: text)
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
                ClipboardCapture(text: "bank", failure: nil)
            })
            let result = try await pipeline.capture(isSafari: false, isBooks: true)
            #expect(result.target == "bank" && result.context == "bank")
            #expect(result.containingSentence == nil && result.capture?.reliability == .targetOnly)
        }
    }

    @Test func recoveredPageEdgeNeverClaimsCompleteSentence() async throws {
        let report = nativeSnapshot("hard", text: "Students learn by testing. It is hard. Later.")
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
            ClipboardCapture(text: "Students", failure: nil)
        })
        let result = try await pipeline.capture(isSafari: false, isBooks: true)
        #expect(result.target == "Students" && result.context.contains("testing"))
        #expect(result.containingSentence == nil && result.capture?.reason == .sentenceUnavailable)
        #expect(result.capture?.reliability == .heuristic && result.capture?.range == nil)
    }

    private func nativeSnapshot(_ wrong: String, text: String, node: Int32 = 25000) -> CaptureReport {
        var report = snapshot(wrong)
        let range = (text as NSString).range(of: wrong)
        report.booksSelection = .init(element: AXUIElementCreateApplication(node), target: wrong,
            text: text, span: .init(start: range.location, end: NSMaxRange(range)))
        return report
    }

    @Test func restorationFailureRejectsLookupAndExplainsClipboardRisk() async {
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { snapshot("bank") }, clipboard: {
            ClipboardCapture(text: nil, failure: .restorationFailed)
        })
        do {
            _ = try await pipeline.capture(isSafari: false, isBooks: true)
            Issue.record("Failed restoration must stop lookup")
        } catch let failure as CaptureFailure {
            #expect(failure.details.issues.contains { $0.clipboardReason == .restorationFailed })
            #expect(failure.localizedDescription.contains("未能恢复原剪贴板"))
        } catch { Issue.record("Expected capture failure") }
    }

    @Test func selfConsistentWrongAXWordNeverReachesLookup() async throws {
        for (visible, wrong) in [("from", "so"), ("Students", "to the"), ("class", "hard")] {
            let report = snapshot(wrong)
            var copies = 0
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
                copies += 1
                return ClipboardCapture(text: visible, failure: nil)
            })
            let captured = try await pipeline.capture(isSafari: false, isBooks: true)
            #expect(copies == 1)
            #expect(captured.target == visible)
            #expect(captured.context == visible && captured.containingSentence == nil)
            #expect(captured.capture?.reliability == .targetOnly)
            #expect(captured.capture?.reason == .rangeMismatch)
        }
    }

    @Test func matchingCopyAndStableContextYieldOnlyHeuristicContext() async throws {
        let report = snapshot("river")
        var reads = 0
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: {
            reads += 1; return report
        }, clipboard: { ClipboardCapture(text: "river", failure: nil) })
        let result = try await pipeline.capture(isSafari: false, isBooks: true)
        #expect(reads == 2)
        #expect(result.target == "river" && result.context == report.captured?.context)
        #expect(result.containingSentence == report.captured?.containingSentence)
        #expect(result.capture?.reliability == .heuristic)
        #expect(result.capture?.range == nil && result.capture?.sentenceRange == nil)
    }

    @Test func changedOrMissingSecondSnapshotDiscardsContext() async throws {
        let first = snapshot("river")
        for next in [snapshot("bank"), snapshot("river", prefix: "Changed. "), CaptureReport(captured: nil, details: .init())] {
            var reads = 0
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: {
                reads += 1; return reads == 1 ? first : next
            }, clipboard: { ClipboardCapture(text: "river", failure: nil) })
            let result = try await pipeline.capture(isSafari: false, isBooks: true)
            #expect(result.target == "river" && result.context == "river")
            #expect(result.containingSentence == nil && result.capture?.reason == .sourceChanged)
        }
    }

    @Test func unusableCopyCannotFallBackToApparentlyValidAX() async {
        for text in [nil, "", " \n ", "river\nExcerpt From a book", String(repeating: "x", count: 2001)] as [String?] {
            let report = snapshot("river")
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
                ClipboardCapture(text: text, failure: text == nil ? .unchanged : nil)
            })
            do {
                _ = try await pipeline.capture(isSafari: false, isBooks: true)
                Issue.record("Unconfirmed Books target must not be submitted")
            } catch let failure as CaptureFailure {
                #expect(failure.details.issues.contains { $0.code == .clipboardFallbackFailed })
            } catch { Issue.record("Expected typed capture failure") }
        }
    }

    @Test func copyOnlyAndAmbiguousContextKeepOnlyCopiedTarget() async throws {
        for report in [CaptureReport(captured: nil, details: .init()),
                       CaptureReport(captured: CapturedContext(target: "bank", context: "bank", containingSentence: nil,
                            capture: .init(reliability: .targetOnly, method: .axRange, reason: .ambiguousOccurrence)), details: .init())] {
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
                ClipboardCapture(text: "bank", failure: nil)
            })
            let result = try await pipeline.capture(isSafari: false, isBooks: true)
            #expect(result.target == "bank" && result.context == "bank")
            #expect(result.capture?.reliability == .targetOnly && result.containingSentence == nil)
        }
    }

    private func snapshot(_ target: String, prefix: String = "Earlier. ") -> CaptureReport {
        let sentence = "The \(target) is here."
        let context = prefix + sentence + " Later."
        let ns = (context as NSString).range(of: target)
        return CaptureReport(captured: CapturedContext(target: target, context: context, containingSentence: sentence,
            capture: .init(reliability: .anchored, method: .axRange,
                           range: .init(start: ns.location, end: NSMaxRange(ns)))), details: .init(strategy: .axRange))
    }
}
