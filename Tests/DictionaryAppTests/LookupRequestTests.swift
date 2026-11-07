import Foundation
import Testing
@testable import DictionaryApp

struct LookupRequestTests {
    @Test func anchoredWhitespaceRebasesAndSentenceCopyIsValidatedNumerically() throws {
        let text = "  The bank closed. The bank closed.  "
        let request = try LookupRequest.captured(target: " bank ", context: text, sentence: "The bank closed.", source: "Test",
            capture: captureMetadata(start: 23, end: 27, sentenceStart: 19, sentenceEnd: 35))
        #expect(request.target == "bank")
        #expect(request.capture?.range == UTF16Span(start: 21, end: 25))
        #expect(request.capture?.sentenceRange == UTF16Span(start: 17, end: 33))
        #expect(request.containingSentence == "The bank closed.")
        let wrong = try LookupRequest.captured(target: "bank", context: text, sentence: "The bank closed.", source: "Test",
            capture: captureMetadata(start: 23, end: 27, sentenceStart: 2, sentenceEnd: 18))
        #expect(wrong.capture?.reliability == .anchored)
        #expect(wrong.capture?.reason == .sentenceUnavailable)
        #expect(wrong.containingSentence == nil)
    }

    @Test func rangeMismatchDoesNotSearchForAnotherOccurrenceOrUseCanonicalEquality() throws {
        for (target, context, span) in [("loan", "The bank closed.", UTF16Span(start: 4, end: 8)),
                                        ("é", "e\u{301} bank.", UTF16Span(start: 0, end: 2))] {
            let request = try LookupRequest.captured(target: target, context: context, sentence: context, source: "Test",
                capture: captureMetadata(start: span.start, end: span.end))
            #expect(request.capture?.reliability == .legacyUnverified)
            #expect(try providerDocument(request.providerContext)["selection"] is NSNull)
        }
    }

    @Test func targetOnlyClearsUntrustedSurroundingsAndAnchoredNilStaysNil() throws {
        let only = try LookupRequest.captured(target: "bank", context: "Hidden private text bank.", sentence: "Hidden private text bank.",
            source: "Test", capture: SelectionLocation(reliability: .targetOnly, method: .domRange, reason: .unsupportedStructure))
        #expect(only.context == nil && only.containingSentence == nil && only.capture?.range == nil)
        #expect(try providerDocument(only.providerContext)["selection"] is NSNull)
        let located = try LookupRequest.captured(target: "bank", context: "We sat on the\nbank of the river.", sentence: nil,
            source: "Test", capture: captureMetadata(start: 14, end: 18, reason: .sentenceUnavailable))
        #expect(located.capture?.reliability == .anchored && located.containingSentence == nil)
        let split = try #require(try providerDocument(located.providerContext)["selection"] as? [String: Any])
        #expect(split["text"] as? String == "bank")
        #expect(split["start"] as? Int == 14)
    }

    @Test func invalidOptionalClaimUsesLegacyTargetNormalization() throws {
        let request=try LookupRequest.captured(target:"\u{feff}",context:nil,sentence:nil,source:"Manual",
            capture:SelectionLocation(reliability:.legacyUnverified,method:.clipboard,reason:.metadataInvalid))
        #expect(request.target == "\u{feff}")
        #expect(!request.isManual)
    }

    @Test func trimsTargetAndMarksBlankContextUnavailable() throws {
        let request = try LookupRequest.manual(target: " bank \n", context: " \n")
        #expect(request.target == "bank")
        #expect(try providerDocument(request.providerContext)["context_text"] as? String == "bank")
        #expect(try providerDocument(request.providerContext)["selection"] is NSNull)
        #expect(request.context == nil)
        #expect(request.containingSentence == nil)
    }

    @Test func rejectsEmptyTarget() {
        #expect(throws: (any Error).self) { try LookupRequest.manual(target: " \n", context: "river") }
    }

    @Test func preservesInternalWhitespaceAndLineBreaks() throws {
        let request = try LookupRequest.manual(target: " first  line\nsecond line ", context: " surrounding\ntext ")
        #expect(request.target == "first  line\nsecond line")
        #expect(request.context == "surrounding\ntext")
    }

    @Test func targetAloneDoesNotCountAsContext() throws {
        let request = try LookupRequest.manual(target: "bank", context: " bank ")
        #expect(request.context == nil)
        #expect(request.containingSentence == nil)
    }

    @Test func uniqueOccurrenceDerivesSentence() throws {
        let request = try LookupRequest.manual(target: "bank", context: "It was sunny. We sat on the bank of the river.")
        #expect(request.containingSentence == "We sat on the bank of the river.")
    }

    @Test func manualSentenceRequiresAWholeTargetRatherThanAPrefix() throws {
        for context in ["The bankruptcy hearing ended.", "We read about embankments.",
                        "The bank2 record changed.", "The bank_name record changed."] {
            let request = try LookupRequest.manual(target: "bank", context: context)
            #expect(request.context == context)
            #expect(request.containingSentence == nil)
        }
        let context = "The bankruptcy hearing ended. We rested by the bank."
        let request = try LookupRequest.manual(target: "bank", context: context)
        #expect(request.containingSentence == "We rested by the bank.")
        let phrase = try LookupRequest.manual(target: "look up", context: "We look upward. Please look up the word.")
        #expect(phrase.containingSentence == "Please look up the word.")
    }

    @Test func wholeTargetMatchingKeepsAmbiguityAndUnicodeBoundaries() throws {
        let ambiguous = try LookupRequest.manual(target: "bank", context: "The bankruptcy ended. The bank closed. We sat by the bank.")
        #expect(ambiguous.containingSentence == nil)
        let quoted = try LookupRequest.manual(target: "bank", context: "😀 She wrote ‘bank’ on the card.")
        #expect(quoted.containingSentence == "😀 She wrote ‘bank’ on the card.")
        let absent = try LookupRequest.manual(target: "bank", context: "The bank\u{301} note changed.")
        #expect(absent.containingSentence == nil)
    }

    @Test func missingOrRepeatedOccurrenceDoesNotInventSentence() throws {
        for context in ["We sat by the river.", "The bank closed. We sat on the bank."] {
            let request = try LookupRequest.manual(target: "bank", context: context)
            #expect(request.context == context)
            #expect(request.containingSentence == nil)
        }
    }

    @Test func selectionSpanningSentencesHasNoPartialSentence() throws {
        let request = try LookupRequest.manual(target: "bank. We", context: "Visit the bank. We are late.")
        #expect(request.containingSentence == nil)
    }

    @Test func capturedSentenceIsPreservedWithoutReinterpretingRepeatedWords() throws {
        let request = try LookupRequest.captured(target: "bank", context: "The bank closed. We sat on the bank.", sentence: "We sat on the bank.", source: "Notes")
        #expect(request.containingSentence == "We sat on the bank.")
        #expect(request.source == "Notes")
    }
}
