import Foundation
import Testing
@testable import DictionaryApp

struct TranslationDecodingTests {
    private func decode(_ json: String) throws -> Translation {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Translation.self, from: Data(json.utf8))
    }

    @Test func explicitUnknownMeaningUsesExistingEmptyPresentation() throws {
        let result = try decode(#"{"meaning_in_context":null,"part_of_speech":null,"example_translation":"标签写着 vqxtralen。","alternatives":[]}"#)
        #expect(result.meaningInContext.isEmpty)
        #expect(result.partOfSpeech == nil)
        #expect(result.exampleTranslation == "标签写着 vqxtralen。")
        let presentation = AIMeaningPresentation(target: "vqxtralen", answer: result.meaningInContext)
        #expect(presentation.text == "暂未获得释义")
        #expect(presentation.originalAnswer == nil)
    }

    @Test(arguments: [#"{}"#, #"{"meaning_in_context":42}"#, #"{"meaning_in_context":[]}"#,
                      #"{"meaning_in_context":{},"part_of_speech":"noun"}"#])
    func missingOrWronglyTypedMeaningIsStillRejected(_ json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test func ordinaryTranslationAndEncodingAreUnchanged() throws {
        let json = #"{"meaning_in_context":"经营","literal_gloss":"跑","part_of_speech":"verb","example_translation":"她经营一家店。","alternatives":["管理"]}"#
        let result = try decode(json)
        #expect(result.meaningInContext == "经营")
        #expect(result.literalGloss == "跑")
        #expect(result.partOfSpeech == "verb")
        #expect(result.alternatives == ["管理"])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let roundTrip = try decode(String(decoding: encoder.encode(result), as: UTF8.self))
        #expect(roundTrip.exampleTranslation == "她经营一家店。")
        #expect(roundTrip.meaningInContext == result.meaningInContext)
    }

    @Test func quotedNullMarkersAreNotDisplayedAsMeaningsButRawOutputIsPreserved() throws {
        let result = try decode(#"{"meaning_in_context":"null","literal_gloss":"null","part_of_speech":"null","example_translation":"null","alternatives":["null"," ","岸边"]}"#)
        let meaning = AIMeaningPresentation(target: "syntheticlabel", answer: result.meaningInContext)
        #expect(meaning.text == "暂未获得释义")
        #expect(meaning.originalAnswer == "null")
        #expect(result.additionalMeanings.literal == nil)
        #expect(result.additionalMeanings.alternatives == ["岸边"])
        let request = try LookupRequest.manual(target: "bank", context: "The bank closed.")
        #expect(LookupResultPresentation(request: request, translation: result).sentenceTranslation == nil)
        // This is presentation of malformed absence markers, not semantic rewriting.
        #expect(result.meaningInContext == "null" && result.partOfSpeech == "null")
        let restored = try JSONDecoder().decode(Translation.self, from: JSONEncoder().encode(result))
        #expect(restored.meaningInContext == "null" && restored.alternatives == result.alternatives)
        #expect(AIMeaningPresentation(target: "null", answer: "空值").text == "空值")
        #expect(AIMeaningPresentation(target: "word", answer: "null 表示空值").text == "null 表示空值")
        let partial = Translation(meaningInContext: "河岸", literalGloss: " null ", partOfSpeech: "null",
                                  exampleTranslation: nil, alternatives: ["null", "岸边"])
        #expect(partial.additionalMeanings.literal == nil)
        #expect(partial.additionalMeanings.alternatives == ["岸边"])
        #expect(Translation.displayText(partial.partOfSpeech) == nil)
    }

    @Test func additionalMeaningsRemoveBlankAndExactDuplicatesWithoutChangingAnswer() {
        let result = Translation(meaningInContext: "河岸", literalGloss: " 河岸 ", partOfSpeech: "noun",
                                 exampleTranslation: nil, alternatives: ["河岸", "岸边", " 岸边 ", "\n", "河滨"])
        #expect(result.additionalMeanings.literal == nil)
        #expect(result.additionalMeanings.alternatives == ["岸边", "河滨"])
        #expect(result.literalGloss == " 河岸 ")
        #expect(result.alternatives?.count == 5)
    }

    @Test func distinctMeaningsKeepOriginalOrderAndWording() {
        let result = Translation(meaningInContext: "河岸", literalGloss: "银行", partOfSpeech: "noun",
                                 exampleTranslation: nil, alternatives: ["银行", "岸边", "堤岸"])
        #expect(result.additionalMeanings.literal == "银行")
        #expect(result.additionalMeanings.alternatives == ["岸边", "堤岸"])
        let empty = Translation(meaningInContext: "河岸", literalGloss: " ", partOfSpeech: nil,
                                exampleTranslation: nil, alternatives: ["河岸", " "])
        #expect(empty.additionalMeanings.literal == nil)
        #expect(empty.additionalMeanings.alternatives.isEmpty)
    }

    @Test func alternativeDisplayBudgetAppliesAfterDeduplicationAndKeepsRawAnswer() throws {
        let alternatives = ["起飞", " ", "脱下", " 脱下 ", "移除", "减去", "模仿", "出发"]
        let answer = Translation(meaningInContext: "起飞", literalGloss: "起飞", partOfSpeech: "verb",
                                 exampleTranslation: nil, alternatives: alternatives)
        #expect(answer.additionalMeanings.alternatives == ["脱下", "移除", "减去"])
        #expect(answer.alternatives == alternatives)
        let restored = try JSONDecoder().decode(Translation.self, from: JSONEncoder().encode(answer))
        #expect(restored.alternatives == alternatives)
    }
}
