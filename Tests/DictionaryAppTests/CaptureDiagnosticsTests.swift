import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CaptureDiagnosticsTests {
    @Test func untrustedNativeCaptureDoesNotAttemptAXOrCopy() async {
        var axCalls = 0
        var copies = 0
        let pipeline = NativeCapturePipeline(isTrusted: { false }, safari: { nil }, ax: {
            axCalls += 1; return CaptureReport(captured: nil, details: .init())
        }, clipboard: { copies += 1; return ClipboardCapture(text: "bank", failure: nil) })
        do { _ = try await pipeline.capture(isSafari: false); Issue.record("Expected permission failure") }
        catch let failure as CaptureFailure { #expect(failure.details.issues.map(\.code) == [.accessibilityNotTrusted]) }
        catch { Issue.record("Expected typed capture failure") }
        #expect(axCalls == 0 && copies == 0)
    }

    @Test func independentSafariSuccessIsPreservedWithoutAXTrust() async throws {
        let pipeline = NativeCapturePipeline(isTrusted: { false }, safari: {
            CapturedContext(target: "bank", context: "We sat on the bank of the river.", containingSentence: nil)
        }, ax: { Issue.record("No AX needed"); return CaptureReport(captured: nil, details: .init()) },
        clipboard: { Issue.record("No copy needed"); return ClipboardCapture(text: nil, failure: .unchanged) })
        let captured = try await pipeline.capture(isSafari: true)
        #expect(captured.target == "bank")
        #expect(captured.diagnostics.strategy == .safariDOM)
    }

    @Test func distinguishesEmptyUnsupportedMissingIPCAndUnusableSelection() {
        let cases: [(AXRead, CaptureIssueCode)] = [
            (.value("  " as CFString), .noSelection),
            (.failure(.attributeUnsupported), .attributeUnsupported),
            (.failure(.noValue), .attributeNoValue),
            (.failure(.cannotComplete), .axCallFailed),
            (.value(NSNumber(value: 42)), .targetExtractionFailed)
        ]
        for (value, expected) in cases {
            let report = extractor(selection: value).extractReport()
            #expect(report.captured == nil)
            #expect(report.details.issues.contains { $0.code == expected && $0.attribute == .selectedText })
            #expect(!report.details.issues.contains { $0.code == .accessibilityNotTrusted })
        }
    }

    @Test func exactAXRangeKeepsTargetSentenceAndParagraph() throws {
        let sentence = "We sat on the bank of the river."
        let range = (sentence as NSString).range(of: "bank")
        let report = extractor(selection: .value("bank" as CFString), text: sentence, range: range).extractReport()
        let captured = try #require(report.captured)
        #expect(captured.target == "bank")
        #expect(captured.context == sentence)
        #expect(captured.containingSentence == sentence)
        #expect(report.details.strategy == .axRange)
    }

    @Test func treeWalkRetainsHeuristicReliabilityAndMalformedRangeCannotCrash() throws {
        let sentence = "We sat on the bank of the river."
        for range in [NSRange(location: -1, length: 4), NSRange(location: Int.max, length: 4)] {
            let report = extractor(selection: .value("bank" as CFString), text: sentence, range: range).extractReport()
            #expect(try #require(report.captured).context == sentence)
            #expect(report.details.strategy == .axTreeWalk)
            #expect(report.details.strategy?.reliability == "heuristicContext")
        }
    }

    @Test func malformedFocusAttributeIsDiagnosableWithoutForceUnwrapping() {
        let extractor = ContextExtractor(readAttribute: { _, _ in .value("unexpected type" as CFString) })
        let report = extractor.extractReport()
        #expect(report.captured == nil)
        #expect(report.details.issues.contains { $0.attribute == .focusedApplication && $0.code == .targetExtractionFailed })
    }

    @Test func validTargetWithoutContextStillReachesProvider() async throws {
        let report = extractor(selection: .value("bank" as CFString)).extractReport()
        #expect(report.details.strategy == .axSelectionOnly)
        #expect(report.details.issues.contains { $0.code == .contextUnavailable })
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { report }, clipboard: {
            Issue.record("Valid AX target must not invoke clipboard"); return ClipboardCapture(text: nil, failure: .unchanged)
        })
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let captures = SelectionCaptureController(coordinator: coordinator)
        captures.start(source: "TextEdit", isSourceCurrent: { true }) { try await pipeline.capture(isSafari: false) }
        let call = await provider.waitForCall("bank")
        #expect(try providerDocument(call.context)["context_text"] as? String == "bank")
        #expect(try providerDocument(call.context)["selection"] is NSNull && call.sentence == nil)
        await provider.succeed(call)
        await captures.task?.value
        coordinator.dismissSelection()
    }

    @Test func fallbackRetainsAXReasonAndDistinguishesClipboardFailure() async throws {
        let ax = extractor(selection: .failure(.attributeUnsupported)).extractReport()
        for succeeds in [false, true] {
            let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil }, ax: { ax }, clipboard: {
                ClipboardCapture(text: succeeds ? "bank" : nil, failure: succeeds ? nil : .unchanged)
            })
            do {
                let captured = try await pipeline.capture(isSafari: false)
                #expect(succeeds)
                #expect(captured.diagnostics.strategy == .clipboardOnly)
                #expect(captured.diagnostics.issues.contains { $0.code == .attributeUnsupported })
            } catch let failure as CaptureFailure {
                #expect(!succeeds)
                #expect(failure.details.issues.contains { $0.code == .attributeUnsupported })
                #expect(failure.details.issues.contains { $0.code == .clipboardFallbackFailed && $0.clipboardReason == .unchanged })
            }
        }
    }

    @Test func exactRangeMismatchNeverClaimsOriginalSentence() throws {
        let report = extractor(selection: .value("loan" as CFString), text: "The bank closed.", range: NSRange(location: 4, length: 4)).extractReport()
        let captured = try #require(report.captured)
        #expect(captured.target == "loan")
        #expect(captured.context == "loan" && captured.containingSentence == nil)
    }

    @Test func repeatedAXTreeDoesNotChooseFirstBank() throws {
        let report = extractor(selection: .value("bank" as CFString), text: "The bank closed. We sat on the bank.").extractReport()
        let captured = try #require(report.captured)
        #expect(captured.context == "bank" && captured.containingSentence == nil)
    }

    @Test func AXCrossSentenceSelectionDoesNotPublishAnIntersectingFragment() throws {
        let report = extractor(selection: .value("bank. We" as CFString), text: "Visit the bank. We are late.",
                               range: NSRange(location: 10, length: 8)).extractReport()
        #expect(report.captured?.containingSentence == nil)
    }

    @Test func sourceQualitySurvivesPipelineMergeWithoutLoggingCoordinatesOrSource() async throws {
        let source="We sat on the\nbank of the river."
        let location=captureMetadata(start:14,end:18,reason:.sentenceUnavailable)
        let pipeline=NativeCapturePipeline(isTrusted:{true},safari:{nil},ax:{
            CaptureReport(captured:CapturedContext(target:"bank",context:source,containingSentence:nil,capture:location),
                          details:CaptureDetails(strategy:.axRange))
        },clipboard:{Issue.record("No copy for valid target");return ClipboardCapture(text:nil,failure:.unchanged)})
        let captured=try await pipeline.capture(isSafari:false)
        #expect(captured.capture == location)
        #expect(captured.diagnostics.reliability == .anchored)
        #expect(captured.diagnostics.reason == .sentenceUnavailable)
        let encoded=String(decoding:try JSONEncoder().encode(captured.diagnostics),as:UTF8.self)
        #expect(!encoded.contains(source) && !encoded.contains("start") && !encoded.contains("range"))
    }

    @Test func nativeRangeKeepsTheSelectedParagraphWithoutUnrelatedParagraphs() {
        let text="Unrelated paragraph.\n\nWe sat on the bank of the river.\n\nAnother paragraph."
        let captured=extractor(selection:.value("bank" as CFString),text:text,range:NSRange(location:36,length:4)).extractReport().captured
        #expect(captured?.context == "We sat on the bank of the river.")
        #expect(captured?.containingSentence == "We sat on the bank of the river.")
        #expect(captured?.capture?.range == UTF16Span(start:14,end:18))
    }

    @Test func nativeSecondOccurrenceUnicodeAndSelectedWhitespaceKeepExactRanges() throws {
        let fixtures:[(String,String,Int,Int,Int)] = [
            ("The bank closed. We sat on the bank of the river.","bank",31,4,31),
            ("🌊 e\u{301} We sat on the bank of the river.","bank",20,4,20),
            ("  The bank closed.  "," bank ",5,6,4)]
        for (text,target,start,length,expected) in fixtures {
            let captured=try #require(extractor(selection:.value(target as CFString),text:text,range:NSRange(location:start,length:length)).extractReport().captured)
            #expect(captured.capture?.reliability == .anchored)
            #expect(captured.capture?.range == UTF16Span(start:expected,end:expected+4))
            #expect(captured.target == "bank")
            #expect(captured.containingSentence != nil)
        }
    }

    private func extractor(selection: AXRead, text: String? = nil, range: NSRange? = nil) -> ContextExtractor {
        let element = AXUIElementCreateApplication(123)
        return ContextExtractor(readAttribute: { _, attribute in
            switch attribute {
            case .focusedApplication, .focusedUIElement: return .value(element)
            case .selectedText: return selection
            case .value: return text.map { .value($0 as CFString) } ?? .failure(.attributeUnsupported)
            case .selectedTextRange:
                guard let range else { return .failure(.attributeUnsupported) }
                var value = CFRange(location: range.location, length: range.length)
                return .value(AXValueCreate(.cfRange, &value)!)
            case .role: return text == nil ? .failure(.attributeUnsupported) : .value("AXStaticText" as CFString)
            default: return .failure(.attributeUnsupported)
            }
        })
    }
}
