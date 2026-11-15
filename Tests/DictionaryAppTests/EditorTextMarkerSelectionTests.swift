import ApplicationServices
import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct EditorTextMarkerSelectionTests {
    @Test(arguments: [false, true])
    func inconsistentEditorOffsetsUseOnlyTheOwnedNativeSentence(longDocument: Bool) async throws {
        let fixture = Fixture()
        if longDocument { fixture.text += String(repeating: " Another bank closed.", count: 900) }
        var copies = 0
        let result = try await fixture.capture {
            copies += 1
            return ClipboardCapture(text: "bank", failure: nil)
        }
        #expect(copies == 1)
        #expect(result.target == "bank" && result.context == fixture.sentence)
        #expect(result.containingSentence == fixture.sentence)
        #expect(result.capture?.reliability == .heuristic)
        #expect(result.capture?.range == nil && result.capture?.sentenceRange == nil)
        #expect(fixture.childReads == 0)
    }

    @Test func unavailableNumericRangeCanUseTheSameIndependentEvidence() async throws {
        let fixture = Fixture(); fixture.numericRange = false
        let result = try await fixture.capture()
        #expect(result.containingSentence == fixture.sentence)
        #expect(result.capture?.reliability == .heuristic)
    }

    @Test(arguments: ["selection-start", "selection-end", "sentence-start", "sentence-end"])
    func everyEndpointMustBelongToTheFocusedEditor(endpoint: String) async throws {
        let fixture = Fixture(); fixture.wrongOwner = endpoint
        let result = try await fixture.capture()
        #expect(result.context == "bank" && result.containingSentence == nil)
        #expect(result.capture?.reason == .rangeMismatch)
    }

    @Test(arguments: ["missingOwner", "ownerCycle", "noMarker", "noSentence", "missingEndpoint", "field", "oversized", "lengthMismatch", "wrongTarget"])
    func incompleteEvidenceCannotRecoverContext(mode: String) async throws {
        let fixture = Fixture(); fixture.mode = mode
        let result = try await fixture.capture()
        #expect(result.context == "bank" && result.containingSentence == nil)
        #expect(result.capture?.reliability == .targetOnly)
    }

    @Test(arguments: ["marker", "sentenceMarker", "sentence", "focus", "target", "ownership"])
    func changesDuringIndependentCopyDiscardTheContext(change: String) async throws {
        let fixture = Fixture()
        let result = try await fixture.capture {
            fixture.change = change
            return ClipboardCapture(text: "bank", failure: nil)
        }
        #expect(result.context == "bank" && result.containingSentence == nil)
        #expect(result.capture?.reason == .sourceChanged)
    }

    @Test func copiedDifferentWordDoesNotInheritEditorSentence() async throws {
        let result = try await Fixture().capture { ClipboardCapture(text: "river", failure: nil) }
        #expect(result.target == "river" && result.context == "river")
        #expect(result.containingSentence == nil && result.capture?.reason == .rangeMismatch)
    }

    @Test func copyFailureCannotBeBypassed() async {
        do {
            _ = try await Fixture().capture { ClipboardCapture(text: nil, failure: .unchanged) }
            Issue.record("Expected independent confirmation failure")
        } catch let failure as CaptureFailure {
            #expect(failure.details.issues.contains { $0.clipboardReason == .unchanged })
        } catch { Issue.record("Expected typed capture failure") }
    }

    @Test func repeatedWordInsideOneNativeSentenceRemainsAmbiguous() async throws {
        let fixture = Fixture(); fixture.sentence = "The bank closed beside another bank."
        let result = try await fixture.capture()
        #expect(result.context == "bank" && result.containingSentence == nil)
        #expect(result.capture?.reason == .ambiguousOccurrence)
    }

    @Test func validNumericSelectionPreservesExistingPathWithoutCopy() async throws {
        let fixture = Fixture(); fixture.validRange = true
        var copies = 0
        let result = try await fixture.capture {
            copies += 1; return ClipboardCapture(text: "bank", failure: nil)
        }
        #expect(result.capture?.reliability == .anchored && copies == 0)
        #expect(fixture.markerReads == 0)
    }

    private final class Fixture {
        var text = "Heading. The bank approved a loan. Later, they rested on the bank of the river. The day ended."
        var sentence = "Later, they rested on the bank of the river."
        var mode = ""
        var change = ""
        var wrongOwner = ""
        var numericRange = true
        var validRange = false
        var childReads = 0
        var markerReads = 0
        let nodes = (0..<6).map { AXUIElementCreateApplication(Int32(42000 + $0)) }

        func capture(copy: @escaping () -> ClipboardCapture = { ClipboardCapture(text: "bank", failure: nil) }) async throws -> CapturedContext {
            let extractor = ContextExtractor(sourceApplication: nodes[0], readAttribute: { [self] element, attribute in
                let editor = CFEqual(element, nodes[1])
                switch attribute {
                case .focusedUIElement: return .value(nodes[change == "focus" ? 4 : 1])
                case .role: return .value((editor ? (mode == "field" ? "AXTextField" : "AXTextArea") : "AXStaticText") as CFString)
                case .selectedText: return editor ? .value((change == "target" ? "river" : "bank") as CFString) : .failure(.noValue)
                case .value: return editor ? .value(text as CFString) : .failure(.noValue)
                case .selectedTextRange:
                    guard editor && numericRange else { return .failure(.noValue) }
                    var range = CFRange(location: validRange ? (text as NSString).range(of: "bank").location : 0, length: 4)
                    return .value(AXValueCreate(.cfRange, &range)!)
                case .selectedTextMarkerRange:
                    markerReads += 1
                    return editor && mode != "noMarker" ? .value((change == "marker" ? "changed-selection" : "selection") as CFString) : .failure(.noValue)
                case .parent:
                    if CFEqual(element, nodes[2]) { return .value(nodes[mode == "ownerCycle" ? 2 : 1]) }
                    return .failure(.noValue)
                case .children: childReads += 1; return .failure(.noValue)
                default: return .failure(.attributeUnsupported)
                }
            }, readParameter: { [self] _, attribute, value in
                let key = value as? String ?? ""
                switch attribute.rawValue {
                case "AXUIElementForTextMarker":
                    if mode == "missingOwner" { return .failure(.noValue) }
                    return .value(nodes[wrongOwner == key || change == "ownership" ? 3 : 2])
                case "AXStringForTextMarkerRange":
                    return .value((key.contains("sentence") ? (change == "sentence" ? sentence + " Changed." : sentence) :
                        mode == "wrongTarget" ? "river" : "bank") as CFString)
                case "AXSentenceTextMarkerRangeForTextMarker":
                    return mode == "noSentence" ? .failure(.attributeUnsupported) :
                        .value((change == "sentenceMarker" ? "changed-sentence" : "sentence") as CFString)
                case "AXLengthForTextMarkerRange":
                    return .value(NSNumber(value: mode == "oversized" ? 8001 : sentence.utf16.count + (mode == "lengthMismatch" ? 1 : change == "sentence" ? 9 : 0)))
                default: return .failure(.attributeUnsupported)
                }
            }, markerEndpoint: { [self] marker, edge in
                if mode == "missingEndpoint" { return nil }
                let prefix = (marker as? String ?? "").contains("sentence") ? "sentence" : "selection"
                return (prefix + (edge == .start ? "-start" : "-end")) as CFString
            }, bundleIdentifier: { _ in "synthetic.editor" })
            return try await NativeCapturePipeline(isTrusted: { true }, safari: { nil },
                ax: { extractor.extractReport() }, clipboard: { copy() }).capture(isSafari: false)
        }
    }
}
