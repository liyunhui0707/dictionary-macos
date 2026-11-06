import Testing
@testable import DictionaryApp

struct LookupResultPresentationTests {
    @Test func unavailableSourceSentenceCannotBeCreatedByProviderOutput() throws {
        let request=try LookupRequest.captured(target:"bank",context:"We sat on the\nbank of the river.",sentence:nil,source:"Chromium",
            capture:captureMetadata(start:14,end:18,reason:.sentenceUnavailable))
        let translation=Translation(meaningInContext:"河岸",literalGloss:nil,partOfSpeech:nil,
                                    exampleTranslation:"An unsolicited fabricated source sentence",alternatives:nil)
        let presentation=LookupResultPresentation(request:request,translation:translation)
        #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil)
        #expect(presentation.notice == "已定位选词，但未能确认完整原句。")
        #expect(presentation.contextLabel == "捕获的语境")
        #expect(request.capture?.range == UTF16Span(start:14,end:18))
    }

    @Test func onlyAnchoredSentenceUsesOriginalLabel() throws {
        let source="We sat on the bank of the river."
        let anchored=try LookupRequest.captured(target:"bank",context:source,sentence:source,source:"Chromium",
            capture:captureMetadata(start:14,end:18,sentenceStart:0,sentenceEnd:32))
        let manual=try LookupRequest.manual(target:"bank",context:source)
        let heuristic=try LookupRequest.captured(target:"bank",context:source,sentence:source,source:"AX",
            capture:SelectionLocation(reliability:.heuristic,method:.axTreeWalk))
        let legacy=try LookupRequest.captured(target:"bank",context:source,sentence:source,source:"Legacy")
        #expect(LookupResultPresentation(request:anchored).sentenceLabel == "原句")
        for request in [manual,heuristic,legacy] {
            let p=LookupResultPresentation(request:request)
            #expect(p.sentence == source && p.sentenceLabel != "原句")
        }
    }

    private let source = "We sat on the bank of the river."
    private let translation = Translation(meaningInContext: "银行", literalGloss: "银行；河岸",
        partOfSpeech: "noun", exampleTranslation: "我们坐在河岸上。", alternatives: ["河岸"])

    @Test func anchoredSourceDoesNotClaimTheModelMeaningIsVerified() throws {
        let request = try LookupRequest.captured(target: "bank", context: source, sentence: source,
            source: "Chromium", capture: captureMetadata(start: 14, end: 18, sentenceStart: 0, sentenceEnd: 32))
        let presentation = LookupResultPresentation(request: request, translation: translation)
        #expect(presentation.meaningLabel == "AI 释义建议")
        #expect(presentation.context == source)
        #expect(presentation.contextLabel == "捕获的语境")
        #expect(presentation.sentenceLabel == "原句")
        #expect(presentation.sentence == source)
        #expect(presentation.sentenceTranslation == translation.exampleTranslation)
        #expect(presentation.notice == nil)
    }

    @Test func inferredContextHasANaturalCaveatAndNeverAnOriginalLabel() throws {
        let request = try LookupRequest.captured(target: "bank", context: source, sentence: source, source: "AX",
            capture: SelectionLocation(reliability: .heuristic, method: .axTreeWalk))
        let presentation = LookupResultPresentation(request: request, translation: translation)
        #expect(presentation.meaningLabel == "AI 释义建议")
        #expect(presentation.contextLabel == "可能的语境")
        #expect(presentation.notice == "语境来自推断，可能与选词不完全对应。")
        #expect(presentation.sentence == source)
        #expect(presentation.sentenceLabel == "可能的原句")
    }

    @Test func unverifiedContextIsNotPresentedAsCaptured() throws {
        let request = try LookupRequest.captured(target: "bank", context: source, sentence: source, source: "Legacy")
        let presentation = LookupResultPresentation(request: request)
        #expect(presentation.meaningLabel == "AI 释义建议")
        #expect(presentation.contextLabel == "未核实的语境")
        #expect(presentation.notice == "提供的语境尚未核实。")
        #expect(presentation.sentenceLabel != "原句")
    }

    @Test func wordOnlyHasOneContextCaveatAndNoSentenceTranslation() throws {
        let request = try LookupRequest.captured(target: "bank", context: nil, sentence: nil, source: "Selection",
            capture: SelectionLocation(reliability: .targetOnly, method: .clipboard))
        let presentation = LookupResultPresentation(request: request, translation: translation)
        #expect(presentation.meaningLabel == "AI 释义建议")
        #expect(presentation.context == nil)
        #expect(presentation.notice == "缺少完整语境，释义仅供一般参考。")
        #expect(presentation.sentence == nil)
        #expect(presentation.sentenceLabel == nil)
        #expect(presentation.sentenceTranslation == nil)
    }

    @Test func manualContextKeepsItsOwnSourceLabel() throws {
        let request = try LookupRequest.manual(target: "bank", context: source)
        let presentation = LookupResultPresentation(request: request, translation: translation)
        #expect(presentation.meaningLabel == "AI 释义建议")
        #expect(presentation.contextLabel == "你提供的语境")
        #expect(presentation.notice == nil)
        #expect(presentation.sentence == source)
        #expect(presentation.sentenceLabel != "原句")
        let noContext = LookupResultPresentation(request: try .manual(target: "bank", context: ""), translation: translation)
        #expect(noContext.notice == "缺少完整语境，释义仅供一般参考。")
        #expect(noContext.sentenceTranslation == nil)
    }

    @Test func explicitSentenceRejectionWinsOverStaleSourceAndModelOutput() {
        // A presentation consumer must also honor the rejection on a directly supplied snapshot.
        let request = LookupRequest(target: "bank", context: source, containingSentence: source, source: "Chromium",
            capture: captureMetadata(start: 14, end: 18, sentenceStart: 0, sentenceEnd: 32, reason: .sentenceUnavailable))
        let presentation = LookupResultPresentation(request: request, translation: translation)
        #expect(presentation.context == source)
        #expect(presentation.sentence == nil)
        #expect(presentation.sentenceLabel == nil)
        #expect(presentation.sentenceTranslation == nil)
        #expect(presentation.notice == "已定位选词，但未能确认完整原句。")
    }

    @Test func wordOnlyCannotExposeStaleContextOrSentence() {
        let request = LookupRequest(target: "bank", context: source, containingSentence: source, source: "Selection",
            capture: SelectionLocation(reliability: .targetOnly, method: .clipboard))
        let presentation = LookupResultPresentation(request: request, translation: translation)
        #expect(presentation.context == nil)
        #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil)
        #expect(presentation.notice == "缺少完整语境，释义仅供一般参考。")
    }
}

struct AIMeaningPresentationTests {
    @Test func repeatedOrEmptyAnswerIsNotPresentedAsAnExplanation() {
        for answer in ["zyxqvexample", " ZYXQVEXAMPLE \n"] {
            let meaning = AIMeaningPresentation(target: "zyxqvexample", answer: answer)
            #expect(meaning.text == "暂无进一步释义")
            #expect(meaning.notice == "AI 返回了原词，未提供进一步解释。")
            #expect(meaning.originalAnswer == answer)
        }
        let empty = AIMeaningPresentation(target: "bank", answer: " \n")
        #expect(empty.text == "暂未获得释义")
        #expect(empty.originalAnswer == nil)
    }

    @Test func doesNotGuessValidityFromDictionaryCoverageOrAnswerLanguage() {
        for (target, answer) in [("bank", "河岸"), ("bank", "银行"), ("zyxqvexample", "一种合成标记"),
                                 ("NASA", "NASA（美国国家航空航天局）"), ("bank", "a financial institution")] {
            let meaning = AIMeaningPresentation(target: target, answer: answer)
            #expect(meaning.text == answer && meaning.notice == nil && meaning.originalAnswer == nil)
        }
        let name = AIMeaningPresentation(target: "NASA", answer: "NASA")
        #expect(name.notice == "AI 返回了原词，未提供进一步解释。") // not a claim that NASA is invalid
    }
}
