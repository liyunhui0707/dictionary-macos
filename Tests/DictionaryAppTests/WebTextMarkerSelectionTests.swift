import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct WebTextMarkerSelectionTests {
    @Test func knownSourceRecoversNativeSentenceWhenGlobalFocusIsUnavailable() async throws {
        let fixture = Fixture(); fixture.sourceBound = true; fixture.frameSearch = "direct"
        fixture.nativeSentence = "They walked along the bank of the river."
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.context == fixture.nativeSentence && result.containingSentence == fixture.nativeSentence)
        #expect(result.capture?.reliability == .heuristic)
        #expect(fixture.globalFocusReads == 0)
    }
    @Test(arguments: ["direct", "dictionary"])
    func nativeFrameDiscoveryDoesNotTraverseIrrelevantChapterNodes(format: String) async throws {
        let fixture = Fixture(); fixture.frameSearch = format; fixture.mode = "unreadable"
        fixture.nativeSentence = "They walked along the bank of the river."
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.containingSentence == fixture.nativeSentence)
        #expect(fixture.childReads == 0 && fixture.bodyReads == 0)
    }

    @Test(arguments: ["twoDocuments", "capped", "malformed", "wrongRole", "outsideRoot", "parentCycle", "searchFailure"])
    func incompleteNativeFrameDiscoveryCannotSupplyContext(mode: String) async throws {
        let fixture = Fixture(); fixture.frameSearch = mode
        fixture.nativeSentence = "They walked along the bank of the river."
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.context == "bank" && result.containingSentence == nil)
        #expect(result.capture?.reliability == .targetOnly)
    }

    @Test(arguments: ["unsupported", "parameterUnsupported", "notImplemented", "noValue"])
    func unavailableFrameSearchPreservesBoundedTreeFallback(mode: String) async throws {
        let fixture = Fixture(); fixture.frameSearch = mode
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.containingSentence == "They walked along the bank of the river.")
        #expect(fixture.childReads > 0)
    }

    @Test func longChapterAndRepeatedParagraphUseTheSelectedNativeSentence() async throws {
        let fixture = Fixture()
        fixture.nativeSentence = "Later, the company repaired the bridge after the storm."
        fixture.target = "company"
        fixture.text = "The company opened a laboratory. " + fixture.nativeSentence! +
            " The project ended on Friday. " + String(repeating: "Another company recorded the weather. ", count: 900)
        let result = try await capture(fixture) { ClipboardCapture(text: "company", failure: nil) }
        #expect(result.context == fixture.nativeSentence)
        #expect(result.containingSentence == fixture.nativeSentence)
        #expect(result.capture?.reliability == .heuristic)
        #expect(fixture.bodyReads == 0)
    }

    @Test func readableWordWithoutNumericRangeStillUsesTheNativeSentence() async throws {
        let fixture = Fixture(); fixture.ordinarySelection = true
        fixture.target = "company"
        fixture.nativeSentence = "Later, the company repaired the bridge."
        fixture.text = String(repeating: "Another company wrote a report. ", count: 500)
        let result = try await capture(fixture) { ClipboardCapture(text: "company", failure: nil) }
        #expect(result.context == fixture.nativeSentence && result.containingSentence == fixture.nativeSentence)
        #expect(result.capture?.reliability == .heuristic)
    }

    @Test(arguments: ["differentSentence", "oversizedSentence", "lengthMismatch", "missingEndpoint"])
    func invalidNativeSentenceDoesNotBypassLongDocumentLimits(mode: String) async throws {
        let fixture = Fixture(); fixture.mode = mode
        fixture.nativeSentence = "Later, the company repaired the bridge."
        fixture.target = "company"
        fixture.text = String(repeating: "Another company wrote a report. ", count: 500)
        let result = try await capture(fixture) { ClipboardCapture(text: "company", failure: nil) }
        #expect(result.context == "company" && result.containingSentence == nil)
        #expect(result.capture?.reliability == .targetOnly)
    }

    @Test func nativeSentenceMarkerChangeDuringCopyDiscardsTheSentence() async throws {
        let fixture = Fixture()
        fixture.nativeSentence = "Later, the company repaired the bridge."
        fixture.target = "company"
        let result = try await capture(fixture) {
            fixture.change = "sentenceMarker"
            return ClipboardCapture(text: "company", failure: nil)
        }
        #expect(result.context == "company" && result.containingSentence == nil)
        #expect(result.capture?.reason == .sourceChanged)
    }

    @Test func manyParagraphsDoNotRequireReadingAllTheirValues() async throws {
        let fixture = Fixture(); fixture.mode = "wide"
        fixture.nativeSentence = "Later, the company repaired the bridge."
        fixture.target = "company"
        let result = try await capture(fixture) { ClipboardCapture(text: "company", failure: nil) }
        #expect(result.context == fixture.nativeSentence && result.containingSentence == fixture.nativeSentence)
        #expect(fixture.bodyReads == 0)
    }
    @Test func iframeMarkerWorksWithoutNumericSelectionAttributes() async throws {
        let fixture = Fixture()
        var copies = 0
        let result = try await capture(fixture) { copies += 1; return ClipboardCapture(text: "bank", failure: nil) }
        #expect(copies == 1)
        #expect(result.target == "bank" && result.context.contains(fixture.text))
        #expect(result.containingSentence == "They walked along the bank of the river.")
        #expect(result.capture?.reliability == .heuristic && result.capture?.method == .axTreeWalk)
        #expect(result.capture?.range == nil && result.capture?.sentenceRange == nil)
        let encoded = String(decoding: try JSONEncoder().encode(result.diagnostics), as: UTF8.self)
        #expect(!encoded.contains("bank") && !encoded.contains(fixture.text) && !encoded.contains("opaque"))
    }

    @Test func repeatedWordsDoNotInventAnOccurrenceFromAnOpaqueMarker() async throws {
        let fixture = Fixture()
        fixture.text = "The bank approved a loan. Later, they rested on the bank of the river. The afternoon was warm."
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.target == "bank" && result.context == "bank")
        #expect(result.containingSentence == nil && result.capture?.reason == .ambiguousOccurrence)
    }

    @Test(arguments: ["marker", "text", "node", "focus", "application"], ["unsupported", "direct"])
    func sourceChangesDuringCopyCannotAttachOldContext(change: String, search: String) async throws {
        let fixture = Fixture(); fixture.frameSearch = search
        let result = try await capture(fixture) {
            fixture.change = change
            return ClipboardCapture(text: "bank", failure: nil)
        }
        #expect(result.target == "bank" && result.context == "bank")
        #expect(result.containingSentence == nil && result.capture?.reason == .sourceChanged)
    }

    @Test func copiedDifferentTargetDoesNotUseTheMarkerContext() async throws {
        let result = try await capture(Fixture()) { ClipboardCapture(text: "river", failure: nil) }
        #expect(result.target == "river" && result.context == "river")
        #expect(result.capture?.reliability == .targetOnly)
        #expect(result.capture?.reason == .rangeMismatch)
    }

    @Test func copyFailureCannotBeBypassedByAReadableMarker() async {
        do {
            _ = try await capture(Fixture()) { ClipboardCapture(text: nil, failure: .unchanged) }
            Issue.record("Expected independent confirmation failure")
        } catch let failure as CaptureFailure {
            #expect(failure.details.issues.contains { $0.clipboardReason == .unchanged })
        } catch { Issue.record("Expected typed capture failure") }
    }

    @Test(arguments: ["noMarker", "parameterFailure", "twoDocuments", "cycle", "unreadable", "oversized", "windowOnly"])
    func incompleteOrAmbiguousEvidenceStaysTargetOnly(mode: String) async throws {
        let fixture = Fixture(); fixture.mode = mode
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.target == "bank" && result.context == "bank")
        #expect(result.capture?.reliability == .targetOnly)
    }

    @Test func switchingDocumentsUsesOnlyTheNewIframe() async throws {
        let fixture = Fixture()
        _ = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        fixture.text = "The office was busy. She deposited her savings at the bank. The clerk handed her a receipt."
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.containingSentence == "She deposited her savings at the bank.")
        #expect(!result.context.contains("river"))
    }

    @Test func unicodeDoesNotNeedMarkerToNumericOffsetConversion() async throws {
        let fixture = Fixture()
        fixture.text = "An emoji 🌿 and a café. They walked along the bank of the river. The day ended."
        let result = try await capture(fixture) { ClipboardCapture(text: "bank", failure: nil) }
        #expect(result.containingSentence == "They walked along the bank of the river.")
        #expect(result.capture?.range == nil)
    }

    private func capture(_ fixture: Fixture, copy: @escaping () -> ClipboardCapture) async throws -> CapturedContext {
        let extractor = fixture.extractor()
        return try await NativeCapturePipeline(isTrusted: { true }, safari: { nil },
            ax: { extractor.extractReport() }, clipboard: { copy() }).capture(isSafari: false)
    }

    private final class Fixture {
        var text = "The morning was quiet. They walked along the bank of the river. The path ended near a bridge."
        var change = ""
        var mode = ""
        var target = "bank"
        var nativeSentence: String?
        var bodyReads = 0
        var childReads = 0
        var frameSearch = "unsupported"
        var ordinarySelection = false
        var sourceBound = false
        var globalFocusReads = 0
        private let nodes = (0..<640).map { AXUIElementCreateApplication(Int32(32000 + $0)) }

        func extractor() -> ContextExtractor {
            ContextExtractor(sourceApplication: sourceBound ? nodes[0] : nil, readAttribute: { [self] element, attribute in
                if attribute == .focusedApplication {
                    globalFocusReads += 1
                    return sourceBound ? .failure(.cannotComplete) : .value(nodes[change == "application" ? 10 : 0])
                }
                if attribute == .focusedUIElement { return .value(nodes[change == "focus" ? 9 : 1]) }
                guard let index = nodes.firstIndex(where: { CFEqual($0, element) }) else { return .failure(.noValue) }
                switch attribute {
                case .role:
                    let role = [0: "AXApplication", 1: "AXToolbar", 2: "AXWebArea", 3: "AXButton", 4: "AXWebArea",
                                5: "AXHeading", 6: "AXStaticText", 7: "AXStaticText", 8: "AXWindow", 9: "AXToolbar",
                                10: "AXApplication", 11: "AXWebArea", 12: "AXStaticText"][index] ?? "AXStaticText"
                    return .value(role as CFString)
                case .parent:
                    if index == 4 || index == 11 {
                        return .value(nodes[frameSearch == "outsideRoot" ? 8 : frameSearch == "parentCycle" ? index : 2])
                    }
                    return .value(nodes[index == 1 || index == 9 ? (mode == "windowOnly" ? 8 : 2) : 8])
                case .selectedText:
                    return ordinarySelection && index == 1 ? .value(target as CFString) : .failure(.noValue)
                case .selectedTextRange: return .failure(.noValue)
                case .selectedTextMarkerRange:
                    guard [4, 11].contains(index), mode != "noMarker" else { return .failure(.noValue) }
                    return .value((change == "marker" ? "opaque-changed" : "opaque-stable") as CFString)
                case .children:
                    childReads += 1
                    if mode == "unreadable", index == 5 { return .failure(.cannotComplete) }
                    if index == 2 { return .value((mode == "twoDocuments" ? [nodes[1], nodes[4], nodes[11]] : [nodes[1], nodes[change == "node" ? 11 : 4]]) as CFArray) }
                    if index == 1 { return .value([nodes[3]] as CFArray) }
                    if index == 4 || index == 11 {
                        return .value((mode == "wide" ? Array(nodes[13...630]) : [nodes[5], nodes[7]]) as CFArray)
                    }
                    if index == 5 { return .value([nodes[mode == "cycle" ? 5 : 6]] as CFArray) }
                    // Matches observed WebKit leaves which omit children.
                    return .failure(.noValue)
                case .value:
                    if index == 6 { return .value("Synthetic heading" as CFString) }
                    if index == 7 {
                        bodyReads += 1
                        return .value((mode == "oversized" ? String(repeating: "x", count: 8001) :
                            change == "text" ? text + " Changed." : text) as CFString)
                    }
                    return .failure(.noValue)
                default: return .failure(.attributeUnsupported)
                }
            }, readParameter: { [self] _, attribute, parameter in
                if mode == "parameterFailure" { return .failure(.cannotComplete) }
                switch attribute {
                case .elementsForSearchPredicate:
                    switch frameSearch {
                    case "unsupported": return .failure(.attributeUnsupported)
                    case "parameterUnsupported": return .failure(.parameterizedAttributeUnsupported)
                    case "notImplemented": return .failure(.notImplemented)
                    case "noValue": return .failure(.noValue)
                    case "searchFailure": return .failure(.cannotComplete)
                    case "malformed": return .value(["invalid"] as CFArray)
                    case "wrongRole": return .value([nodes[3]] as CFArray)
                    case "capped": return .value(Array(repeating: nodes[4], count: 65) as CFArray)
                    case "twoDocuments": return .value([nodes[4], nodes[11]] as CFArray)
                    case "dictionary": return .value([["AXSearchResultElement": nodes[4]]] as CFArray)
                    default: return .value([nodes[change == "node" ? 11 : 4]] as CFArray)
                    }
                case .stringForTextMarkerRange:
                    let isSentence = (parameter as? String)?.hasPrefix("sentence-range") == true
                    return .value((isSentence ? (mode == "lengthMismatch" ? "mismatch " : "") + nativeSentence! : target) as CFString)
                case .sentenceForTextMarker:
                    let key = mode == "differentSentence" && (parameter as? String) == "end" ? "other-sentence" :
                        change == "sentenceMarker" ? "sentence-range-changed" : "sentence-range"
                    return nativeSentence == nil ? .failure(.attributeUnsupported) : .value(key as CFString)
                case .uiElementForTextMarker: return .failure(.attributeUnsupported)
                case .lengthForTextMarkerRange:
                    return nativeSentence.map { .value(NSNumber(value: mode == "oversizedSentence" ? 8001 : $0.utf16.count)) } ?? .failure(.attributeUnsupported)
                }
            }, markerEndpoint: { [self] _, edge in
                nativeSentence == nil || mode == "missingEndpoint" ? nil : (edge == .start ? "start" : "end") as CFString
            }, bundleIdentifier: { _ in "synthetic.reader" })
        }
    }
}
