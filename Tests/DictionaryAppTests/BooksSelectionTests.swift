import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

struct BooksSelectionTests {
    private let page = "An earlier sentence. I called the bank while sitting on the bank of the river. Another sentence follows."

    @Test func repeatedWordRangeCannotEstablishTheSelectedOccurrence() throws {
        let fixture = Fixture(text: page)
        let result = try #require(fixture.extractor().extractReport().captured)
        #expect(result.target == "bank")
        #expect(result.capture?.reliability == .targetOnly)
        #expect(result.containingSentence == nil && result.context == "bank")
        #expect(result.capture?.reason == .ambiguousOccurrence)
    }

    @Test func scopeDoesNotChangeOtherApplications() {
        let fixture = Fixture(text: page)
        #expect(fixture.extractor(bundle: "other.reader").extractReport().captured == nil)
    }

    @MainActor
    @Test func copiedUniqueWordRecoversContextFromARepeatedNativeTarget() async throws {
        // Native attributes consistently point at "bank" twice, while copy
        // confirms the uniquely occurring "river". Do not reuse bank's offsets.
        let fixture = Fixture(text: page)
        let extractor = fixture.extractor()
        let pipeline = NativeCapturePipeline(isTrusted: { true }, safari: { nil },
            ax: { extractor.extractReport() }, clipboard: { ClipboardCapture(text: "river", failure: nil) })
        let result = try await pipeline.capture(isSafari: false, isBooks: true)
        #expect(result.target == "river")
        #expect(result.containingSentence == "I called the bank while sitting on the bank of the river.")
        #expect(result.capture?.reliability == .heuristic)
        #expect(result.capture?.range == nil && result.capture?.sentenceRange == nil)
    }

    @Test func ambiguityOutsideTheResultWindowIsStillRejected() throws {
        let fixture = Fixture(text: "The bank closed. " + String(repeating: "padding ", count: 400) +
                              "We sat on the bank. Another sentence follows.")
        let result = try #require(fixture.extractor().extractReport().captured)
        #expect(result.capture?.reason == .ambiguousOccurrence)
        #expect(result.context == "bank" && result.containingSentence == nil)
    }

    @Test func oversizedBooksNodeDoesNotGuessAContextWindow() throws {
        let fixture = Fixture(text: String(repeating: "padding ", count: 1100) + "The bank closed.")
        let result = try #require(fixture.extractor().extractReport().captured)
        #expect(result.capture?.reason == .budgetExceeded)
        #expect(result.context == "bank" && result.containingSentence == nil)
    }

    @Test func editableBooksFieldsKeepTheExistingNativeRangePath() {
        let fixture = Fixture(text: page)
        fixture.mode = "editableFocus"
        #expect(fixture.extractor().extractReport().captured?.capture?.reliability == .anchored)
    }

    @Test func headingRangeWithoutSelectedTextIsIgnored() {
        let fixture = Fixture(text: "Earlier. We sat on the bank. Later.")
        fixture.heading = true
        #expect(fixture.extractor().extractReport().captured?.capture?.reliability == .anchored)
    }

    @Test func invalidMissingAndAmbiguousRangesNeverSupplyContext() {
        for mode in ["wrongRange", "missingRange", "duplicate", "cycle", "unreadableChildren", "unreadableSelection"] {
            let fixture = Fixture(text: page)
            fixture.mode = mode
            #expect(fixture.extractor().extractReport().captured == nil, "Mode: \(mode)")
        }
    }

    @Test func changedSelectionPageOrFocusCannotReuseAnOldSnapshot() {
        for mode in ["changedText", "changedRange", "changedNode", "changedFocus", "changedApp"] {
            let fixture = Fixture(text: page)
            fixture.mode = mode
            #expect(fixture.extractor().extractReport().captured == nil, "Mode: \(mode)")
        }
    }

    @Test func pageEdgesRetainContextButNeverClaimACompleteSentence() throws {
        for text in ["We sat on the bank. Another sentence follows.",
                     "An earlier sentence. We sat on the bank.",
                     "  We sat on the bank.  "] {
            let fixture = Fixture(text: text)
            let result = try #require(fixture.extractor().extractReport().captured)
            #expect(result.capture?.reliability == .anchored)
            #expect(result.context.contains("bank"))
            #expect(result.containingSentence == nil)
            #expect(result.capture?.reason == .sentenceUnavailable)
        }
    }

    @Test func unicodeOffsetsRemainUTF16Based() throws {
        let fixture = Fixture(text: "🌊 An earlier sentence. We sat on the bank. Another sentence follows.")
        let result = try #require(fixture.extractor().extractReport().captured)
        #expect(result.capture?.range?.slice(in: result.context) == "bank")
        #expect(result.containingSentence == "We sat on the bank.")
    }

    @Test func depthAndNodeBudgetsRejectIncompleteTrees() {
        for mode in ["deep", "wide"] {
            let fixture = Fixture(text: page)
            fixture.mode = mode
            #expect(fixture.extractor().extractReport().captured == nil)
        }
    }

    private final class Fixture {
        let text: String
        var mode = ""
        var heading = false
        var passes = 0
        var focusReads = 0
        var appReads = 0
        let nodes = (0..<520).map { AXUIElementCreateApplication(Int32(20000 + $0)) }
        init(text: String) { self.text = text }

        func extractor(bundle: String = "com.apple.iBooksX") -> ContextExtractor {
            ContextExtractor(readAttribute: { [self] element, attribute in
                if attribute == .focusedApplication {
                    appReads += 1
                    return .value(nodes[mode == "changedApp" && appReads > 1 ? 519 : 0])
                }
                if attribute == .focusedUIElement {
                    focusReads += 1
                    return .value(nodes[mode == "changedFocus" && focusReads > 1 ? 519 : 1])
                }
                guard let index = nodes.firstIndex(where: { CFEqual($0, element) }) else { return .failure(.noValue) }
                let isText = mode == "deep" ? index == 20 : index == 2 || index == 3 || mode == "editableFocus" && index == 1
                switch attribute {
                case .role: return .value((mode == "editableFocus" && index == 1 ? "AXTextField" : isText ? "AXStaticText" : "AXGroup") as CFString)
                case .children:
                    if index == 1 { passes += 1 }
                    if mode == "unreadableChildren" { return .failure(.cannotComplete) }
                    if mode == "cycle" { return .value([nodes[1], nodes[2]] as CFArray) }
                    if mode == "deep" { return .value([nodes[index + 1]] as CFArray) }
                    if mode == "wide" { return .value(Array(nodes[2...519]) as CFArray) }
                    let children = mode == "duplicate" || heading ? [nodes[2], nodes[3]] :
                        [nodes[mode == "changedNode" && passes > 1 ? 3 : 2]]
                    return .value(children as CFArray)
                case .selectedText:
                    if mode == "unreadableSelection" { return .failure(.cannotComplete) }
                    return isText ? .value((heading && index == 3 ? "" : "bank") as CFString) : .failure(.attributeUnsupported)
                case .value:
                    return .value((mode == "changedText" && passes > 1 ? text + " Changed." : text) as CFString)
                case .selectedTextRange:
                    if mode == "missingRange" { return .failure(.attributeUnsupported) }
                    let ns = (text as NSString).range(of: "bank", options: mode == "changedRange" && passes > 1 ? [] : .backwards)
                    var range = CFRange(location: mode == "wrongRange" ? 0 : ns.location, length: 4)
                    return .value(AXValueCreate(.cfRange, &range)!)
                default: return .failure(.attributeUnsupported)
                }
            }, bundleIdentifier: { _ in bundle })
        }
    }
}
