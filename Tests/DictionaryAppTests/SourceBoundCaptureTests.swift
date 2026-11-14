import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct SourceBoundCaptureTests {
    @Test(arguments: [AXError.noValue, AXError.cannotComplete])
    func knownSourceDoesNotDependOnTheSystemFocusedApplication(error: AXError) throws {
        let app = AXUIElementCreateApplication(41001)
        let element = AXUIElementCreateApplication(41002)
        let sentence = "They walked along the bank of the river."
        var globalReads = 0, wrongAppReads = 0
        let extractor = ContextExtractor(sourceApplication: app, readAttribute: { node, attribute in
            switch attribute {
            case .focusedApplication: globalReads += 1; return .failure(error)
            case .focusedUIElement:
                if !CFEqual(node, app) { wrongAppReads += 1 }
                return .value(element)
            case .selectedText: return .value("bank" as CFString)
            case .value: return .value(sentence as CFString)
            case .selectedTextRange:
                let range = (sentence as NSString).range(of: "bank")
                var span = CFRange(location: range.location, length: range.length)
                return .value(AXValueCreate(.cfRange, &span)!)
            case .role: return .value("AXStaticText" as CFString)
            default: return .failure(.attributeUnsupported)
            }
        }, bundleIdentifier: { _ in "synthetic.source" })
        let captured = try #require(extractor.extractReport().captured)
        #expect(captured.target == "bank" && captured.containingSentence == sentence)
        #expect(globalReads == 0 && wrongAppReads == 0)
    }

    @Test(arguments: ["beforeCapture", "duringAX", "duringCopy", "interruptedCopy", "duringConfirmation", "duringSafari"])
    func sourceChangesStopCaptureWithoutUsingAnotherApplication(change: String) async {
        var current = change != "beforeCapture"
        var axCalls = 0, copies = 0, safariCalls = 0
        let captured = CapturedContext(target: "bank", context: "They walked along the bank of the river.",
            containingSentence: "They walked along the bank of the river.",
            capture: .init(reliability: .anchored, method: .axRange,
                           range: .init(start: 22, end: 26), sentenceRange: .init(start: 0, end: 40)))
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: {
            safariCalls += 1
            if change == "duringSafari" { current = false }
            return captured
        }, ax: {
            axCalls += 1
            if change == "duringAX" || change == "duringConfirmation" && axCalls == 2 { current = false }
            return CaptureReport(captured: ["duringCopy", "interruptedCopy"].contains(change) ? nil : captured, details: .init())
        }, clipboard: {
            copies += 1
            if change == "interruptedCopy" { current = false; throw CancellationError() }
            if change == "duringCopy" { current = false }
            return ClipboardCapture(text: "bank", failure: nil)
        }, isSourceCurrent: { current })
        do {
            _ = try await pipeline.capture(isSafari: change == "duringSafari", isBooks: change == "duringConfirmation")
            Issue.record("Changed source must not produce a lookup")
        } catch let failure as CaptureFailure {
            #expect(failure.details.reason == .sourceChanged)
        } catch { Issue.record("Expected a typed source-change failure") }
        if change == "beforeCapture" { #expect(axCalls == 0 && copies == 0 && safariCalls == 0) }
        if change == "duringAX" { #expect(copies == 0) }
        if ["duringCopy", "interruptedCopy"].contains(change) { #expect(copies == 1) }
        if change == "duringConfirmation" { #expect(axCalls == 2 && copies == 1) }
    }

    @Test func clipboardRestorationFailureRemainsVisibleWhenSourceAlsoChanges() async {
        var current = true
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil },
            ax: { CaptureReport(captured: nil, details: .init()) }, clipboard: {
                current = false
                return ClipboardCapture(text: nil, failure: .restorationFailed)
            }, isSourceCurrent: { current })
        do { _ = try await pipeline.capture(isSafari: false); Issue.record("Expected failure") }
        catch let failure as CaptureFailure {
            #expect(failure.details.reason == .sourceChanged)
            #expect(failure.details.issues.contains { $0.clipboardReason == .restorationFailed })
            #expect(failure.errorDescription?.contains("原剪贴板") == true)
        } catch { Issue.record("Expected capture failure") }
    }
}
