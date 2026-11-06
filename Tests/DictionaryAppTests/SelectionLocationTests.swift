import Foundation
import Testing
@testable import DictionaryApp

struct SelectionLocationTests {
    @Test func exactUTF16BoundsRejectOverflowSurrogatesAndCanonicalMismatch() {
        let text = "🌊 e\u{301} bank."
        #expect(UTF16Span(start: 6, end: 10).slice(in: text) == "bank")
        for span in [UTF16Span(start: -1, end: 4), .init(start: 0, end: Int.max),
                     .init(start: 1, end: 2), .init(start: 4, end: 4)] {
            #expect(span.slice(in: text) == nil)
        }
        #expect(!SelectionLocation.sameUnits("é", "e\u{301}"))
        #expect(SelectionLocation.trim("\u{85}\u{feff}\tbank\r\n") == "bank")
    }

    @Test func contextWindowRetainsTargetAndWholeSentenceWithRebasedCoordinates() throws {
        let text = String(repeating: "x", count: 2100) + ". We sat on the bank of the river."
        let selected = UTF16Span(start: 2116, end: 2120)
        let sentence = UTF16Span(start: 2102, end: 2134)
        let window = try #require(SelectionLocation.window(text: text, target: selected, sentence: sentence))
        #expect(window.context.utf16.count <= 2000)
        #expect(window.range.slice(in: window.context) == "bank")
        #expect(window.sentenceRange?.slice(in: window.context) == "We sat on the bank of the river.")
        #expect(window.range.start == selected.start - window.sourceStart)
    }

    @Test func contextWindowDoesNotStartInsideAComposedSequence() throws {
        let window=try #require(SelectionLocation.window(text:"xx e\u{301} bank zz",target:.init(start:6,end:10),sentence:nil,limit:8))
        #expect(window.context == "bank z")
        #expect(window.range == UTF16Span(start:0,end:4))
        #expect(window.sourceStart == 6 && window.cutLeft && window.cutRight)
    }

    @Test func oversizedSentenceCannotBeClippedIntoAnOriginalSentence() {
        let text = "The bank " + String(repeating: "x", count: 2000) + "."
        #expect(SelectionLocation.window(text: text, target: .init(start: 4, end: 8),
                                        sentence: .init(start: 0, end: text.utf16.count)) == nil)
    }
}

func captureMetadata(start: Int, end: Int, sentenceStart: Int? = nil, sentenceEnd: Int? = nil,
                     reason: CaptureReason? = nil) -> SelectionLocation {
    SelectionLocation(reliability: .anchored, method: .domRange, range: .init(start: start, end: end),
                      sentenceRange: sentenceStart.flatMap { s in sentenceEnd.map { UTF16Span(start: s, end: $0) } },
                      reason: reason)
}

func providerDocument(_ value: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
}
