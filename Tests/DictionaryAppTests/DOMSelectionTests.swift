import AppKit
import Foundation
import Testing
import WebKit
@testable import DictionaryApp

/// Executes the deployed content script in WebKit, not a replacement DOM algorithm.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DOMSelectionTests {
    private let paragraph = "The bank approved my loan. We sat on the bank of the river."

    // R2 remediation: incoming layout state cannot be inferred from C0 alone.
    @Test(arguments: ["\u{202e}", "\u{202b}\u{202e}", "\u{2067}\u{202e}"], [false, true])
    func remediation2BidiBeforeAcquisitionCannotClaimExactSource(_ control: String, crossNode: Bool) async throws {
        let raw = control + String(repeating: "Earlier sentence. ", count: 1500) + "We sat on the bank of the river."
        let start = control.utf16.count + 27014
        let page = DOMCapturePage()
        try await page.load("<p id='p'></p>")
        if crossNode {
            let body = String(raw.dropFirst(control.count))
            _ = try await page.evaluate("var p=document.getElementById('p');p.appendChild(document.createTextNode(\(jsScalar(control))));var span=document.createElement('span');span.textContent=\(jsScalar(body));p.appendChild(span);void 0;")
        } else { _ = try await page.evaluate("document.getElementById('p').textContent = \(jsScalar(raw));") }
        try await observeBoundaryWork(page)
        let reply = try await page.capture(start: start, end: start + 4, reverse: true)
        // Each letter's actual layout is observed, not inferred from Range text.
        let geometry = try #require(try await page.evaluate("var base=getSelection().getRangeAt(0),n=base.startContainer,offset=base.startOffset;var b=document.createRange(),k=document.createRange();b.setStart(n,offset);b.setEnd(n,offset+1);k.setStart(n,offset+3);k.setEnd(n,offset+4);({b:b.getBoundingClientRect().x,k:k.getBoundingClientRect().x,text:getSelection().toString()});") as? [String: Any])
        #expect(geometry["text"] as? String == "bank")
        #expect((geometry["b"] as? Double ?? 0) > (geometry["k"] as? Double ?? 0))
        let work = try #require(try await page.evaluate("window.boundaryWork") as? [String: Int])
        #expect((work["maxString"] ?? 0) <= 8000 && (work["rects"] ?? 0) <= 8000)
        #expect((work["rects"] ?? 0) > 0)
        try await assertReviewFlow(page, reply: reply, target: "bank", source: nil, start: nil, sentence: nil)
        #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
    }

    @Test(arguments: [false, true])
    func remediation2OrdinaryLongLTRKeepsExactSentence(_ crossNode: Bool) async throws {
        let page = DOMCapturePage()
        let prefix = String(repeating: "Earlier sentence. ", count: 1500)
        let suffix = "We sat on the bank of the river."
        if crossNode {
            try await page.load("<p id='p'>\(prefix)We sat on the ba<strong>nk</strong> of the river.</p>")
        } else { try await page.load("<p id='p'>\(prefix + suffix)</p>") }
        try await observeBoundaryWork(page)
        let reply = try await page.capture(start: 27014, end: 27018)
        let work = try #require(try await page.evaluate("window.boundaryWork") as? [String: Int])
        #expect((work["maxString"] ?? 0) <= 8000 && (work["rects"] ?? 0) <= 8000 && (work["rects"] ?? 0) > 0)
        let context = try #require(reply["context"] as? String)
        #expect(context.utf16.count == 2000)
        try await assertReviewFlow(page, reply: reply, target: "bank", source: context, start: 1982, sentence: suffix)
    }

    @Test func remediation2UnobservableIncomingProjectionIsWordOnly() async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p'>" + String(repeating: "Earlier sentence. ", count: 1500) + "We sat on the bank of the river.</p>")
        // Negative API-seam control: no layout evidence cannot become positive proof.
        _ = try await page.evaluate("Range.prototype.getClientRects=function(){return []};void 0;")
        let reply = try await page.capture(start: 27014, end: 27018)
        #expect((reply["capture"] as? [String: Any])?["reliability"] as? String == "targetOnly")
        #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
    }

    @Test(arguments: ["pvt", "Pvt", "pVt", "amb", "aMb", "priv", "supt", "qzx"])
    func remediation2InternalPeriodNeedsBoundaryEvidence(_ abbreviation: String) async throws {
        for continuation in ["Smith.", "Smith visited the river.", "12 arrived."] {
            let raw = "The bank called " + abbreviation + ". " + continuation
            let page = DOMCapturePage()
            try await page.load("<p id='p'>\(raw)</p>")
            let reply = try await page.capture(start: 4, end: 8)
            try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: 4, sentence: nil)
        }
    }

    @Test func remediation2NormalPeriodsAndSourceEdgesRemainEligible() async throws {
        for (raw, start, sentence) in [
            ("The bank ran.", 4, "The bank ran."),
            ("The bank used 3.5 units.", 4, "The bank used 3.5 units."),
            ("The bank closed. We sat on the bank of the river.", 4, "The bank closed."),
            ("The bank closed. We sat on the bank of the river.", 31, "We sat on the bank of the river."),
            ("Capt. Smith visited the bank.", 24, "")
        ] {
            let page = DOMCapturePage()
            try await page.load("<p id='p'>\(raw)</p>")
            let reply = try await page.capture(start: start, end: start + 4)
            try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: start, sentence: sentence.isEmpty ? nil : sentence)
        }
    }

    private func observeBoundaryWork(_ page: DOMCapturePage) async throws {
        _ = try await page.evaluate("var nativeString=Range.prototype.toString,nativeRects=Range.prototype.getClientRects;window.boundaryWork={maxString:0,rects:0};Range.prototype.toString=function(){const text=nativeString.call(this);window.boundaryWork.maxString=Math.max(window.boundaryWork.maxString,text.length);return text;};Range.prototype.getClientRects=function(){window.boundaryWork.rects++;return nativeRects.call(this);};void 0;")
    }

    // B1-H1: execute the deployed entry point, not just the raw-text helper.
    @Test(arguments: [0, 1, 2, 3, 4])
    func reviewBidiLayoutsCannotPublishExactSource(_ variant: Int) async throws {
        let raw = "We sat on the bank of the river."
        let html = [
            "<p id='p' style='direction:rtl;unicode-bidi:bidi-override'>\(raw)</p>",
            "<p id='p'>We sat on the <span style='direction:rtl;unicode-bidi:bidi-override'>bank</span> of the river.</p>",
            "<div style='direction:rtl;unicode-bidi:bidi-override'><p id='p' style='direction:ltr'>\(raw)</p></div>",
            "<p id='p' style='direction:rtl;unicode-bidi:embed'>\(raw)</p>",
            "<p id='p' style='direction:rtl'>\(raw)</p>"
        ][variant]
        let page = DOMCapturePage()
        try await page.load(html)
        let reply = try await page.capture(start: 14, end: 18, reverse: variant == 1)
        // Logical Range identity alone is not a rendered-projection proof.
        #expect(try await page.evaluate("getSelection().toString()") as? String == "bank")
        #expect(try await page.evaluate("document.getElementById('p').textContent") as? String == raw)
        try await assertReviewFlow(page, reply: reply, target: "bank", source: nil, start: nil, sentence: nil)
        #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
    }

    @Test(arguments: ["\u{61c}", "\u{200e}", "\u{200f}", "\u{202a}", "\u{202b}", "\u{202c}", "\u{202d}", "\u{202e}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"])
    func reviewBidiControlsAreProjectionHazards(_ control: String) async throws {
        let page = DOMCapturePage(), raw = "We sat on the " + control + "bank of the river."
        try await page.load("<p id='p'></p>")
        _ = try await page.evaluate("document.getElementById('p').textContent = \(jsScalar(raw));")
        let reply = try await page.capture(start: 15, end: 19)
        #expect(reply["target"] as? String == "bank")
        #expect((reply["capture"] as? [String: Any])?["reliability"] as? String == "targetOnly")
        #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
        #expect(reply["context"] == nil || reply["context"] is NSNull)
        #expect((reply["capture"] as? [String: Any])?["range"] == nil || (reply["capture"] as? [String: Any])?["range"] is NSNull)
    }

    @Test(arguments: ["", "direction:ltr", "direction:ltr;unicode-bidi:isolate"])
    func reviewOrdinaryLTRAndUnicodeRemainSupported(_ css: String) async throws {
        let page = DOMCapturePage(), raw = "We sat on the bank near a café."
        try await page.load("<div style='display:grid'><p id='p' style='\(css)'>\(raw)</p></div>")
        let reply = try await page.capture(start: 14, end: 18)
        try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: 14, sentence: raw)
    }

    // B1-H2: common title classes plus a title absent from the old denylist.
    @Test(arguments: ["Capt.", "Rev.", "Gen.", "Gov.", "Sen.", "Hon.", "Pvt.", "Amb."])
    func reviewTitlesWithholdBothSidesOfAnAmbiguousPeriod(_ title: String) async throws {
        for beforeBoundary in [false, true] {
            let page = DOMCapturePage(), raw = title + " Smith visited the bank."
            try await page.load("<p id='p'>\(raw)</p>")
            let start = beforeBoundary ? 0 : title.utf16.count + 19
            let target = beforeBoundary ? String(title.dropLast()) : "bank"
            let reply = try await page.capture(start: start, end: start + target.utf16.count, reverse: !beforeBoundary)
            #expect(reply["context"] as? String == raw)
            try await assertReviewFlow(page, reply: reply, target: target, source: raw, start: start, sentence: nil)
        }
    }

    @Test func reviewRepeatedUnicodeTargetsKeepDistinctRangesAcrossTitleBoundary() async throws {
        let raw = "The 🌊 bank called Capt. Smith near the bank."
        for start in [7, 40] {
            let page = DOMCapturePage()
            try await page.load("<p id='p'>\(raw)</p>")
            let reply = try await page.capture(start: start, end: start + 4, reverse: start == 40)
            try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: start, sentence: nil)
        }
    }

    @Test func reviewNormalSentenceBoundariesSurviveNearbyTitles() async throws {
        let fixtures: [(String, Int, String)] = [
            // Title/name openings no longer prove an internal boundary. Keep
            // the source and location, but deliberately withhold the old claim.
            ("The bank closed. Capt. Smith visited the bank.", 4, ""),
            ("Capt. Smith visited the bank. We sat on the bank of the river.", 44, "We sat on the bank of the river."),
            ("The bank closed! We sat on the bank of the river.", 31, "We sat on the bank of the river.")]
        for (raw, start, sentence) in fixtures {
            let page = DOMCapturePage()
            try await page.load("<p id='p'>\(raw)</p>")
            let reply = try await page.capture(start: start, end: start + 4)
            try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: start, sentence: sentence.isEmpty ? nil : sentence)
        }
    }

    @Test(arguments: ["normal", "nowrap", "pre", "pre-wrap", "pre-line"])
    func reviewDistinctN03N04CSSShapesStaySentenceUnavailable(_ css: String) async throws {
        for (raw, start) in [("The bank closed.\nWe sat on the bank.", 4), ("The bank closed.\nWe sat on the bank.", 31), ("We sat on the bank\nof the river.", 14)] {
            let page = DOMCapturePage()
            try await page.load("<p id='p' style='white-space:\(css)'>\(raw)</p>")
            let reply = try await page.capture(start: start, end: start + 4)
            try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: start, sentence: nil)
        }
    }

    @Test func reviewNaturalWindowCannotEraseAcquiredNewlineProof() async throws {
        let raw = "Earlier line\n" + String(repeating: "Context word. ", count: 200) + "We sat on the bank of the river."
        #expect(raw.utf16.count == 2845)
        let page = DOMCapturePage()
        try await page.load("<p id='p'>\(raw)</p>")
        // Observe the real adapter's acquired candidate without changing its inputs
        // or forcing its window. This is not a direct captureRawText fixture.
        _ = try await page.evaluate("var observedRawCapture=captureRawText;captureRawText=(...args)=>{window.acquiredProof={raw:args[0],range:args[1],edges:args[3]};return observedRawCapture(...args);};void 0;")
        let reply = try await page.capture(start: 2827, end: 2831, reverse: true)
        let acquired = try #require(try await page.evaluate("window.acquiredProof") as? [String: Any])
        #expect(acquired["raw"] as? String == raw)
        #expect(acquired["range"] as? [String: Int] == ["start":2827,"end":2831])
        #expect((acquired["edges"] as? [String: Any])?["leftComplete"] as? Bool == true)
        let expected = String(decoding: Array(raw.utf16)[831..<2831], as: UTF16.self)
        #expect(!expected.contains("\n") && expected.utf16.count == 2000)
        try await assertReviewFlow(page, reply: reply, target: "bank", source: expected, start: 1996, sentence: nil)
        #expect(try await page.evaluate("document.getElementById('p').textContent") as? String == raw)
    }

    private func assertReviewFlow(_ page: DOMCapturePage, reply: [String: Any], target: String,
                                  source: String?, start: Int?, sentence: String?) async throws {
        let metadata = try #require(reply["capture"] as? [String: Any])
        #expect(reply["target"] as? String == target)
        #expect(metadata["reliability"] as? String == (source == nil ? "targetOnly" : "anchored"))
        #expect(reply["containingSentence"] as? String == sentence)
        if let start {
            #expect(metadata["range"] as? [String: Int] == ["start": start, "end": start + target.utf16.count])
            #expect(reply["context"] as? String == source)
            if sentence == nil { #expect(metadata["reason"] as? String == "sentenceUnavailable") }
        } else {
            #expect(reply["context"] == nil || reply["context"] is NSNull)
            #expect(metadata["range"] == nil || metadata["range"] is NSNull)
        }
        if sentence == nil { #expect(metadata["sentenceRange"] == nil || metadata["sentenceRange"] is NSNull) }
        let body = try await page.sendThroughWorker(reply)
        let provider = ControlledProvider()
        let active = LookupCoordinator(provider: provider)
        let tokens = TokenStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryRemediation-\(UUID())"))
        let handler = TranslateHandler(tokenStore: tokens, coordinator: active)
        let response = Task { await handler.handle(HTTPRequest(method: "POST", path: "/v1/translate",
            headers: ["authorization": "Bearer \(tokens.token)"], body: Data(body.utf8))) }
        let call = await provider.waitForCall(target)
        let document = try providerDocument(call.context)
        #expect(call.sentence == sentence)
        if let start {
            let split = try #require(document["selection"] as? [String: Any])
            #expect(split["start"] as? Int == start)
            #expect(split["text"] as? String == target)
            #expect(document["context_text"] as? String == source)
        } else { #expect(document["selection"] is NSNull) }
        let prompt = PromptBuilder.build(target: call.target, context: call.context, containingSentence: call.sentence, targetLanguage: call.language)
        if sentence == nil { #expect(prompt.userInstruction.contains("SENTENCE: null\n")) }
        await provider.succeed(call, example: "Unsolicited model sentence")
        #expect(await response.value.status == 200)
        let result = try #require(active.selection.result)
        let presentation = LookupResultPresentation(request: result.request, translation: result.translation)
        #expect(presentation.sentence == sentence)
        if sentence == nil {
            #expect(presentation.sentenceLabel == nil && presentation.sentenceTranslation == nil)
        } else { #expect(presentation.sentenceLabel == "原句") }
    }

    @Test(arguments: ["Dr. ","Mr. ","Prof. "])
    func abbreviationBoundaryCannotAuthorizeATrailingFragment(_ prefix: String) async throws {
        let page=DOMCapturePage(), raw=prefix + "Smith visited the bank."
        try await page.load("<p id='p'>\(raw)</p>")
        let reply=try await page.capture(start:prefix.utf16.count+18,end:prefix.utf16.count+22)
        #expect(reply["target"] as? String == "bank")
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "anchored")
        let sentence=reply["containingSentence"] as? String
        #expect(sentence == nil || sentence == raw)
        if sentence == nil { #expect((reply["capture"] as? [String:Any])?["reason"] as? String == "sentenceUnavailable") }
    }

    @Test func firstBankControl() async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p'>\(paragraph)</p>")
        let reply = try await page.capture(start: 4, end: 8)
        #expect(reply["target"] as? String == "bank")
        #expect(reply["containingSentence"] as? String == "The bank approved my loan.")
    }

    @Test func selectedSecondBankUsesRiverSentence() async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p'>\(paragraph)</p>")
        let reply = try await page.capture(start: 41, end: 45)
        #expect(reply["target"] as? String == "bank")
        #expect(reply["containingSentence"] as? String == "We sat on the bank of the river.")
    }
    @Test func thirdOccurrencePartialWordAndSelectedWhitespaceStayAtTheirSourceRanges() async throws {
        let page=DOMCapturePage()
        try await page.load("<p id='p'>The bank closed. I called the bank. We sat on the bank of the river.</p>")
        let third=try await page.capture(start:50,end:54,reverse:true)
        #expect(third["containingSentence"] as? String == "We sat on the bank of the river.")
        #expect((third["capture"] as? [String:Any])?["range"] as? [String:Int] == ["start":50,"end":54])
        try await page.load("<p id='p'>We sat on the bank of the river.</p>")
        for (start,end,target,expectedStart,expectedEnd) in [(13,19,"bank",14,18),(15,17,"an",15,17)] {
            let reply=try await page.capture(start:start,end:end)
            #expect(reply["target"] as? String == target)
            #expect((reply["capture"] as? [String:Any])?["range"] as? [String:Int] == ["start":expectedStart,"end":expectedEnd])
        }
    }

    @Test func mappingMismatchGuardNeverSearchesForAReplacementOccurrence() async throws {
        let page=DOMCapturePage()
        try await page.load("<p id='p'>The bank closed. I took a loan.</p>")
        _ = try await page.capture(start:4,end:8)
        // Inject a Selection/Range disagreement at the API seam; this does not
        // claim that this browser engine produces that mismatch for this HTML.
        let reply=try #require(try await page.evaluate("var actual=getSelection(); window.getSelection=()=>({rangeCount:1,isCollapsed:false,toString:()=> 'loan',getRangeAt:i=>actual.getRangeAt(i)});extractSelection();") as? [String:Any])
        #expect(reply["target"] as? String == "loan")
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
        #expect((reply["capture"] as? [String:Any])?["reason"] as? String == "rangeMismatch")
        #expect(reply["context"] == nil || reply["context"] is NSNull)
    }

    @Test(arguments: Array(1...16))
    func R2RawCoordinatesCompletenessAndDowngrade(_ number: Int) async throws {
        let f = newlineFixture(number)
        let lengths=[32,32,36,32,18,18,21,49,41,32,55,34,45,32,32,32]
        #expect(f.raw.utf16.count == lengths[number-1])
        #expect(String(decoding:Array(f.raw.utf16)[f.start..<(f.start+4)],as:UTF16.self) == "bank")
        let page = DOMCapturePage()
        try await page.load(f.html ?? "<p id='p'></p>")
        if f.html == nil { _ = try await page.evaluate("document.getElementById('p').textContent = \(jsScalar(f.raw));") }
        if number == 15 {
            let lines=try await page.evaluate("var wrapRange=document.createRange();wrapRange.selectNodeContents(document.getElementById('p'));wrapRange.getClientRects().length;") as? Int
            #expect((lines ?? 0) > 1)
        }
        let reply: [String: Any]
        if number == 5 || number == 6 || number == 13 {
            let edges = number == 5 ? "{leftComplete:false,rightComplete:true}" : number == 6 ? "{leftComplete:true,rightComplete:false}" : "{leftComplete:true,rightComplete:true}"
            let crop = number == 13 ? ",{start:13,end:45}" : ""
            reply = try #require(try await page.evaluate("captureRawText(\(jsScalar(f.raw)),{start:\(f.start),end:\(f.start+4)},'bank',\(edges)\(crop));") as? [String: Any])
        } else {
            reply = try await page.capture(start: f.start, end: f.start + 4, reverse: number == 8 || number == 10)
        }
        #expect(reply["target"] as? String == "bank")
        let metadata = try #require(reply["capture"] as? [String: Any])
        #expect(metadata["reliability"] as? String == (number == 11 ? "targetOnly" : "anchored"))
        if number == 11 {
            #expect(reply["context"] == nil || reply["context"] is NSNull)
            #expect(metadata["range"] == nil || metadata["range"] is NSNull)
            #expect(metadata["reason"] as? String == "unsupportedStructure")
            #expect(reply["containingSentence"] == nil || reply["containingSentence"] is NSNull)
            #expect(metadata["sentenceRange"] == nil || metadata["sentenceRange"] is NSNull)
        } else {
            let context = try #require(reply["context"] as? String)
            let expectedContext = number == 12 || number == 13 ? "We sat on the bank of the river." : f.raw
            #expect(context.utf16.elementsEqual(expectedContext.utf16))
            let range = try #require(metadata["range"] as? [String: Int])
            let start = number == 12 || number == 13 ? 14 : f.start
            #expect(range == ["start":start,"end":start+4])
            #expect(UTF16Span(start: start, end: start+4).slice(in: context) == "bank")
            if [1,14,15].contains(number) {
                #expect(reply["containingSentence"] as? String == "We sat on the bank of the river.")
                #expect(metadata["sentenceRange"] as? [String:Int] == ["start":0,"end":32])
                #expect(metadata["reason"] == nil || metadata["reason"] is NSNull)
            } else {
                #expect(reply["containingSentence"] == nil || reply["containingSentence"] is NSNull)
                #expect(metadata["sentenceRange"] == nil || metadata["sentenceRange"] is NSNull)
                #expect(metadata["reason"] as? String == "sentenceUnavailable")
            }
        }
    }

    @Test(arguments: [3,8])
    func firstRepeatedOccurrenceWithLFAlsoRemainsAnchoredWithoutSentence(_ number: Int) async throws {
        let f=newlineFixture(number), page=DOMCapturePage()
        try await page.load("<p id='p'>\(f.raw)</p>")
        let reply=try await page.capture(start:4,end:8,reverse:true)
        let metadata=try #require(reply["capture"] as? [String:Any])
        #expect(metadata["range"] as? [String:Int] == ["start":4,"end":8])
        #expect(metadata["reason"] as? String == "sentenceUnavailable")
        #expect(metadata["reliability"] as? String == "anchored")
        #expect(reply["containingSentence"] == nil || reply["containingSentence"] is NSNull)
    }

    @Test(arguments: ["\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}", "\u{b}", "\u{c}"])
    func everySourceSeparatorRemainsUnqualified(_ separator: String) async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p'></p>")
        let raw = "We sat on the" + separator + "bank of the river."
        _ = try await page.evaluate("document.getElementById('p').textContent = \(jsScalar(raw));")
        let reply = try await page.capture(start: 13 + separator.utf16.count, end: 17 + separator.utf16.count)
        let metadata = try #require(reply["capture"] as? [String: Any])
        #expect(metadata["reliability"] as? String == "anchored")
        #expect(metadata["reason"] as? String == "sentenceUnavailable")
        #expect(reply["containingSentence"] == nil || reply["containingSentence"] is NSNull)
    }

    @Test(arguments: ["normal", "nowrap", "pre", "pre-wrap", "pre-line"])
    func CSSWhitespaceNeverUpgradesSourceLF(_ css: String) async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p' style='white-space: \(css)'>We sat on the\nba<strong>nk</strong> of the river.</p>")
        let reply = try await page.capture(start: 14, end: 18, reverse: true)
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "anchored")
        #expect((reply["capture"] as? [String:Any])?["reason"] as? String == "sentenceUnavailable")
    }

    @Test(arguments: ["hidden", "style='display:none'", "style='visibility:hidden'", "style='opacity:0'", "style='-webkit-user-select:none;user-select:none'"])
    func hiddenOrUnselectableContextIsWordOnly(_ attribute: String) async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p'>The <span \(attribute)>loan </span>bank closed.</p>")
        let reply = try await page.capture(start: 9, end: 13)
        #expect(reply["target"] as? String == "bank")
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
        #expect(reply["context"] == nil || reply["context"] is NSNull)
    }

    @Test(arguments: [1,2,4,8,11,12,13])
    func actualCaptureSenderHandlerProviderAndPresentation(_ number: Int) async throws {
        let f=newlineFixture(number), page=DOMCapturePage()
        try await page.load(f.html ?? "<p id='p'></p>")
        if f.html == nil { _ = try await page.evaluate("document.getElementById('p').textContent = \(jsScalar(f.raw));") }
        let reply: [String:Any]
        if number == 13 {
            reply=try #require(try await page.evaluate("captureRawText(\(jsScalar(f.raw)),{start:27,end:31},'bank',{leftComplete:true,rightComplete:true},{start:13,end:45});") as? [String:Any])
        } else { reply=try await page.capture(start:f.start,end:f.start+4) }
        let body=try await page.sendThroughWorker(reply)
        let provider=ControlledProvider()
        let active=LookupCoordinator(provider:provider)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryTests-\(UUID())")
        let tokens=TokenStore(directory:directory)
        let handler=TranslateHandler(tokenStore:tokens,coordinator:active)
        let pending=Task { await handler.handle(HTTPRequest(method:"POST",path:"/v1/translate",
            headers:["authorization":"Bearer \(tokens.token)"],body:Data(body.utf8))) }
        let call=await provider.waitForCall("bank")
        let document=try providerDocument(call.context)
        if number == 11 {
            #expect(document["mode"] as? String == "targetOnly")
            #expect(document["context_text"] as? String == "bank")
            #expect(document["selection"] is NSNull)
        } else {
            #expect(document["mode"] as? String == "anchored")
            let split=try #require(document["selection"] as? [String:Any])
            #expect(split["text"] as? String == "bank")
            #expect(split["start"] as? Int == (number == 12 || number == 13 ? 14 : f.start))
            #expect((split["before"] as? String ?? "") + "bank" + (split["after"] as? String ?? "") == reply["context"] as? String)
        }
        #expect(call.sentence == (number == 1 ? f.raw : nil))
        await provider.succeed(call, example:"Unsolicited model sentence")
        #expect(await pending.value.status == 200)
        let result=try #require(active.selection.result)
        let presentation=LookupResultPresentation(request:result.request,translation:result.translation)
        if number == 1 { #expect(presentation.sentenceLabel == "原句") }
        else { #expect(presentation.sentence == nil && presentation.sentenceTranslation == nil) }
        if number != 1 && number != 11 {
            #expect(result.request.capture?.reliability == .anchored && result.request.capture?.reason == .sentenceUnavailable)
            #expect(presentation.notice == "已定位选词，但未能确认完整原句。")
            #expect(PromptBuilder.build(target:call.target,context:call.context,containingSentence:call.sentence,
                targetLanguage:call.language).userInstruction.contains("SENTENCE: null\n"))
        }
    }

    @Test func missingEngineRetainsPositionAndOversizedSentenceIsWordOnly() async throws {
        for oversized in [false,true] {
            let page=DOMCapturePage()
            let raw=oversized ? "The bank " + String(repeating:"word ",count:500) + "closed." : "We sat on the bank of the river."
            try await page.load("<p id='p'>\(raw)</p>")
            if !oversized { _ = try await page.evaluate("Intl.Segmenter=undefined; void 0;") }
            let reply=try await page.capture(start:oversized ? 4 : 14,end:oversized ? 8 : 18)
            #expect(reply["target"] as? String == "bank")
            let metadata=try #require(reply["capture"] as? [String:Any])
            #expect(metadata["reliability"] as? String == (oversized ? "targetOnly" : "anchored"))
            #expect(metadata["reason"] as? String == (oversized ? "budgetExceeded" : "sentenceUnavailable"))
        }
    }

    @Test(arguments: [1,2,8,10])
    func forwardReverseAndChildBoundariesKeepTheSameOccurrence(_ number: Int) async throws {
        let f=newlineFixture(number), units=Array(f.raw.utf16), page=DOMCapturePage()
        let before=String(decoding:units[..<f.start],as:UTF16.self)
        let after=String(decoding:units[(f.start+4)...],as:UTF16.self)
        try await page.load("<p id='p'>\(before)<span>ba<strong>nk</strong></span>\(after)</p>")
        let forward=try await page.capture(start:f.start,end:f.start+4)
        let reverse=try await page.capture(start:f.start,end:f.start+4,reverse:true)
        let child=try #require(try await page.evaluate("var p=document.getElementById('p');getSelection().setBaseAndExtent(p,2,p,1);extractSelection();") as? [String:Any])
        for reply in [forward,reverse,child] {
            #expect((reply["capture"] as? [String:Any])?["range"] as? [String:Int] == ["start":f.start,"end":f.start+4])
            #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "anchored")
            #expect(reply["containingSentence"] as? String == (number == 1 ? f.raw : nil))
        }
    }

    @Test(arguments: ["aria-hidden='true'", "style='width:0;height:0'", "style='position:relative;left:-10000px'"])
    func renderedInlineTextIsNotRemovedSolelyForARIAOrGeometry(_ attribute: String) async throws {
        let page=DOMCapturePage()
        try await page.load("<div style='display:grid'><p id='p'>We sat on the <span \(attribute)>bank</span> of the river.</p></div>")
        let reply=try await page.capture(start:14,end:18)
        #expect(reply["containingSentence"] as? String == "We sat on the bank of the river.")
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "anchored")
    }

    @Test(arguments: ["<script>loan</script>","<style>p {}</style>","<span style='content-visibility:hidden'>loan</span>","<span style='display:block'>loan</span>","<input value='loan'>"])
    func nonReadingStructuresCannotProveAnOriginalSentence(_ middle: String) async throws {
        let page=DOMCapturePage()
        try await page.load("<div id='p'>The bank closed. \(middle)</div>")
        let reply=try await page.capture(start:4,end:8)
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
    }

    @Test func pseudoContentAndInternalAlternateFlowAreUnsupported() async throws {
        for extra in ["<style>#p::before {content:'Missing sentence';}</style>","<style>#p {display:flex;}</style>"] {
            let page=DOMCapturePage()
            try await page.load(extra + "<div id='p'>The bank closed.</div>")
            let reply=try await page.capture(start:4,end:8)
            #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
        }
    }

    @Test func scanLimitCannotPublishASentenceFragmentAsBoundedContext() async throws {
        let page=DOMCapturePage()
        try await page.load("<p id='p'>The bank " + String(repeating:"word ",count:2000) + "closed.</p>")
        let reply=try await page.capture(start:4,end:8)
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
        #expect((reply["capture"] as? [String:Any])?["reason"] as? String == "budgetExceeded")
        #expect(reply["target"] as? String == "bank")
    }

    @Test func hugeTargetIsPreservedAndNodeLimitCannotPublishAPrefix() async throws {
        for hugeTarget in [false,true] {
            let page=DOMCapturePage()
            try await page.load("<p id='p'></p>")
            if hugeTarget {
                _ = try await page.evaluate("document.getElementById('p').textContent='x'.repeat(2001); void 0;")
            } else {
                _ = try await page.evaluate("document.getElementById('p').innerHTML='The bank closed.'+'<span></span>'.repeat(4100); void 0;")
            }
            let reply=try await page.capture(start:hugeTarget ? 0 : 4,end:hugeTarget ? 2001 : 8)
            #expect((reply["target"] as? String)?.utf16.count == (hugeTarget ? 2001 : 4))
            #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
            #expect((reply["capture"] as? [String:Any])?["reason"] as? String == "budgetExceeded")
            #expect(reply["context"] == nil || reply["context"] is NSNull)
        }
    }

    @Test(arguments: ["<br>","<span style='display:inline-block'>loan </span>","<span style='position:absolute'>loan </span>","<span style='display:contents'>loan </span>","<span style='font-size:0'>loan </span>","<span style='visibility:hidden'><span style='visibility:visible'>loan </span></span>"])
    func unsupportedProjectionNeverReturnsContaminatedContext(_ middle: String) async throws {
        let page=DOMCapturePage()
        try await page.load("<p id='p'>The bank closed. \(middle)</p>")
        let reply=try await page.capture(start:4,end:8)
        #expect((reply["capture"] as? [String:Any])?["reliability"] as? String == "targetOnly")
        #expect(reply["context"] == nil || reply["context"] is NSNull)
    }

    @Test func lateSelectionIsBoundedAndDoesNotSerializeTheWholeBlock() async throws {
        let page=DOMCapturePage()
        try await page.load("<div style='display:flex'><p id='p'></p></div>")
        let prefix="The bank closed. " + String(repeating:"Earlier sentence. ",count:1500)
        let raw=prefix + "We sat on the bank of the river."
        _ = try await page.evaluate("document.getElementById('p').textContent = \(jsScalar(raw)); Object.defineProperty(document.getElementById('p'),'textContent',{get(){throw Error('unbounded block serialization');}}); void 0;")
        let reply=try await page.capture(start:prefix.utf16.count+14,end:prefix.utf16.count+18)
        let context=try #require(reply["context"] as? String)
        #expect(context.utf16.count <= 2000)
        #expect(reply["containingSentence"] as? String == "We sat on the bank of the river.")
        let location=try #require((reply["capture"] as? [String:Any])?["range"] as? [String:Int])
        #expect(UTF16Span(start:location["start"]!,end:location["end"]!).slice(in:context) == "bank")
    }

    @Test func captureDoesNotMutateSourceOrSelectionAndMultipleSentencesStayUnqualified() async throws {
        let page=DOMCapturePage()
        try await page.load("<p id='p'>The bank closed. We sat on the bank.</p>")
        let reply=try await page.capture(start:4,end:20,reverse:true)
        #expect(reply["target"] as? String == "bank closed. We")
        #expect(reply["containingSentence"] == nil || reply["containingSentence"] is NSNull)
        let state=try #require(try await page.evaluate("({text:document.getElementById('p').textContent,anchor:getSelection().anchorOffset,focus:getSelection().focusOffset})") as? [String:Any])
        #expect(state["text"] as? String == "The bank closed. We sat on the bank.")
        #expect(state["anchor"] as? Int == 20 && state["focus"] as? Int == 4)
    }

    @Test func elementEndpointsInlineAndReversePreserveTheSelectedSpan() async throws {
        let page = DOMCapturePage()
        try await page.load("<p id='p'>We sat on the <span>ba<strong>nk</strong></span> of the river.</p>")
        let reply = try #require(try await page.evaluate("var p=document.getElementById('p'); getSelection().setBaseAndExtent(p,2,p,1); extractSelection();") as? [String:Any])
        #expect(reply["target"] as? String == "bank")
        #expect((reply["capture"] as? [String:Any])?["range"] as? [String:Int] == ["start":14,"end":18])
        #expect(reply["containingSentence"] as? String == "We sat on the bank of the river.")
    }

    @Test func batch2ReadingUsesActiveDOMInsteadOfStaleEditor() async throws {
        for (raw, start, sentence) in [(paragraph,41,"We sat on the bank of the river."),
            ("I called the bank while sitting on the bank of the river.",39,"I called the bank while sitting on the bank of the river.")] {
            let page=DOMCapturePage()
            try await page.load("<div id='reading-root'><p id='p'>\(raw)</p></div>",adapter:"obsidian")
            let reply=try await page.capture(start:start,end:start+4,reverse:true)
            #expect(reply["target"] as? String == "bank")
            #expect(reply["containingSentence"] as? String == sentence)
            try await assertReviewFlow(page,reply:reply,target:"bank",source:raw,start:start,sentence:sentence)
            #expect((reply["capture"] as? [String:Any])?["method"] as? String == "domRange")
        }
    }

    @Test(arguments: [1,2,3,4,7,8,9,10,11,12,14,15,16])
    func batch2ReadingR2ActualAcquisition(_ n:Int) async throws {
        let f=newlineFixture(n),page=DOMCapturePage()
        try await page.load("<div id='reading-root'>\(f.html ?? "<p id='p'></p>")</div>",adapter:"obsidian")
        if f.html == nil { _ = try await page.evaluate("document.getElementById('p').textContent=\(jsScalar(f.raw));") }
        let reply=try await page.capture(start:f.start,end:f.start+4,reverse:true)
        let source=n==11 ? nil : n==12 ? "We sat on the bank of the river." : f.raw
        try await assertReviewFlow(page,reply:reply,target:"bank",source:source,start:n==11 ? nil : n==12 ? 14 : f.start,
                                   sentence:[1,14,15].contains(n) ? f.raw : nil)
    }

    @Test func batch2ReadingRejectsUnrelatedPaneAndInactiveMode() async throws {
        for mode in ["preview","other"] {
            let page=DOMCapturePage()
            try await page.load("<div id='reading-root'><p>Active note.</p></div><p id='p'>We sat on the bank of the river.</p>",adapter:"obsidian")
            _ = try await page.evaluate("activeMarkdownView.getMode=()=>\(jsScalar(mode));void 0;")
            let reply=try await page.capture(start:14,end:18)
            #expect(reply["empty"] as? Bool == true)
            #expect(try await page.evaluate("window.postedBody === null") as? Bool == true)
        }
    }

    @Test(arguments: ["<span hidden>loan </span>","<br>","<span style='unicode-bidi:bidi-override;direction:rtl'>loan </span>"])
    func batch2ReadingUnsupportedProjectionIsWordOnly(_ middle:String) async throws {
        let page=DOMCapturePage()
        try await page.load("<div id='reading-root'><p id='p'>The bank closed. \(middle)</p></div>",adapter:"obsidian")
        let reply=try await page.capture(start:4,end:8)
        try await assertReviewFlow(page,reply:reply,target:"bank",source:nil,start:nil,sentence:nil)
    }

    @Test func batch2ReadingSharesBidiAndBoundaryRepairs() async throws {
        for (raw,start) in [("Capt. Smith visited the bank.",24),("The bank called pvt. Smith.",4),
                            ("\u{202e}"+String(repeating:"Earlier sentence. ",count:1500)+"We sat on the bank of the river.",27015)] {
            let page=DOMCapturePage()
            try await page.load("<div id='reading-root'><p id='p'></p></div>",adapter:"obsidian")
            _ = try await page.evaluate("document.getElementById('p').textContent=\(jsScalar(raw));")
            let reply=try await page.capture(start:start,end:start+4)
            try await assertReviewFlow(page,reply:reply,target:"bank",source:start==27015 ? nil : raw,start:start==27015 ? nil : start,sentence:nil)
        }
    }

    @Test func batch2ReadingCrossNodeAndLongNormalRemainExact() async throws {
        let page=DOMCapturePage()
        try await page.load("<div id='reading-root' style='display:flex'><p id='p'>We sat on the ba<strong>nk</strong> of the river.</p></div>",adapter:"obsidian")
        let cross=try await page.capture(start:14,end:18,reverse:true)
        try await assertReviewFlow(page,reply:cross,target:"bank",source:"We sat on the bank of the river.",start:14,sentence:"We sat on the bank of the river.")
        let long=DOMCapturePage(),raw=String(repeating:"Earlier sentence. ",count:1500)+"We sat on the bank of the river."
        try await long.load("<div id='reading-root'><p id='p'>\(raw)</p></div>",adapter:"obsidian")
        let reply=try await long.capture(start:27014,end:27018)
        #expect(reply["containingSentence"] as? String == "We sat on the bank of the river.")
        #expect((reply["capture"] as? [String:Any])?["range"] as? [String:Int] == ["start":1982,"end":1986])
    }

    @Test(arguments: [false, true], ["visible", "hidden"])
    func obsidianO8VisibleCrossNodeInsideClippedPane(_ reverse: Bool, _ overflow: String) async throws {
        let page = DOMCapturePage(), raw = "We sat on the bank of the river."
        try await page.load("""
        <div style='overflow:\(overflow);width:700px;height:180px;border:3px solid;padding:8px'>
          <div style='overflow:\(overflow);width:660px;height:140px'>
            <div id='reading-root'><p id='p'>We sat on the ba<strong>nk</strong> of the river.</p></div>
          </div>
        </div>
        """, adapter: "obsidian")
        let reply = try await page.capture(start: 14, end: 18, reverse: reverse)
        let selected = try #require(try await page.evaluate("""
        (()=>{const s=getSelection(),r=s.getRangeAt(0),p=document.getElementById('p'),pane=document.getElementById('reading-root').parentElement;
        const all=document.createRange();all.selectNodeContents(p);const box=pane.getBoundingClientRect();
        return {text:s.toString(),crossNode:r.startContainer!==r.endContainer,start:r.startOffset,end:r.endOffset,
          clipped:getComputedStyle(pane).overflowX==='hidden',
          fullyVisible:[...all.getClientRects()].every(b=>b.left>=box.left&&b.right<=box.right&&b.top>=box.top&&b.bottom<=box.bottom)};})()
        """) as? [String: Any])
        #expect(selected["text"] as? String == "bank")
        #expect(selected["crossNode"] as? Bool == true)
        #expect(selected["start"] as? Int == 14 && selected["end"] as? Int == 2)
        #expect(selected["clipped"] as? Bool == (overflow == "hidden"))
        #expect(selected["fullyVisible"] as? Bool == true)
        #expect((reply["capture"] as? [String: Any])?["method"] as? String == "domRange")
        try await assertReviewFlow(page, reply: reply, target: "bank", source: raw, start: 14, sentence: raw)
    }

    @Test(arguments: ["hidden", "style='display:none'", "style='visibility:hidden'", "style='opacity:0'", "style='user-select:none;-webkit-user-select:none'"])
    func obsidianO8HiddenContextInsideClippedPaneStaysWordOnly(_ attribute: String) async throws {
        let page = DOMCapturePage()
        try await page.load("<div style='overflow:hidden;width:700px;height:180px'><div id='reading-root'><p id='p'>We sat on the ba<strong>nk</strong> of the river.<span \(attribute)> Hidden context.</span></p></div></div>", adapter: "obsidian")
        let reply = try await page.capture(start: 14, end: 18)
        #expect(try await page.evaluate("getSelection().toString()") as? String == "bank")
        try await assertReviewFlow(page, reply: reply, target: "bank", source: nil, start: nil, sentence: nil)
        #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
    }

    @Test(arguments: [40, 150], [false, true])
    func obsidianO8ActuallyClippedTargetOrContextStaysWordOnly(_ width: Int, _ vertical: Bool) async throws {
        let page = DOMCapturePage()
        let pane = vertical ? "width:150px;height:\(width == 40 ? 8 : 20)px" : "width:\(width)px;height:100px"
        let paragraph = vertical ? "width:150px;line-height:20px;margin:0" : "width:600px"
        try await page.load("<div style='overflow:hidden;width:700px;height:180px'><div style='overflow:hidden;\(pane)'><div id='reading-root'><p id='p' style='\(paragraph)'>We sat on the ba<strong>nk</strong> of the river.</p></div></div></div>", adapter: "obsidian")
        let reply = try await page.capture(start: 14, end: 18)
        let geometry = try #require(try await page.evaluate("""
        (()=>{const root=document.getElementById('reading-root'),pane=root.parentElement,box=pane.getBoundingClientRect(),all=document.createRange();
        all.selectNodeContents(document.getElementById('p'));return {targetVisible:[...getSelection().getRangeAt(0).getClientRects()].every(b=>b.left>=box.left&&b.right<=box.right&&b.top>=box.top&&b.bottom<=box.bottom),
          contextClipped:[...all.getClientRects()].some(b=>b.right>box.right||b.bottom>box.bottom)};})()
        """) as? [String: Any])
        #expect(geometry["contextClipped"] as? Bool == true)
        #expect(geometry["targetVisible"] as? Bool == (width == 150))
        try await assertReviewFlow(page, reply: reply, target: "bank", source: nil, start: nil, sentence: nil)
        #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
    }

    @Test func obsidianO8MissingGeometryAndLocalClippingRemainUnsupported() async throws {
        for missingGeometry in [false, true] {
            let page = DOMCapturePage()
            try await page.load("<div style='overflow:hidden;width:700px;height:180px'><div id='reading-root'><p id='p' style='\(missingGeometry ? "" : "overflow:hidden")'>We sat on the ba<strong>nk</strong> of the river.</p></div></div>", adapter: "obsidian")
            if missingGeometry { _ = try await page.evaluate("Range.prototype.getClientRects=()=>[];void 0;") }
            let reply = try await page.capture(start: 14, end: 18)
            try await assertReviewFlow(page, reply: reply, target: "bank", source: nil, start: nil, sentence: nil)
            #expect((reply["capture"] as? [String: Any])?["reason"] as? String == "unsupportedStructure")
        }
    }

    @Test func batch2EditorActualCommandCarriesSourceEvidenceThroughProviderAndUI() async throws {
        for (raw,start,sentence) in [("I called the bank while sitting on the bank of the river.",39,"I called the bank while sitting on the bank of the river." as String?),
                                      ("The **bank** closed.",6,nil),("We sat on the\nbank of the river.",14,nil)] {
            let page=DOMCapturePage()
            try await page.load("<div id='reading-root'><p id='p'></p></div>",adapter:"obsidian")
            _ = try await page.evaluate("""
            document.getElementById('p').textContent=\(jsScalar(raw));
            var editorRaw=\(jsScalar(raw)),editorLines=editorRaw.split('\\n'),starts=[0];
            for(const l of editorLines.slice(0,-1))starts.push(starts.at(-1)+l.length+1);
            function pos(i){let line=0;while(line+1<starts.length&&starts[line+1]<=i)line++;return {line,ch:i-starts[line]};}
            var from=pos(\(start)),to=pos(\(start+4));
            activeMarkdownView.getMode=()=> 'source';
            activeMarkdownView.editor={hasFocus:()=>true,getSelection:()=> 'bank',lineCount:()=>editorLines.length,
                listSelections:()=>[{anchor:to,head:from}],getCursor:s=>s==='from'?from:to,
                getLine:i=>editorLines[i],getRange:(a,b)=>editorRaw.slice(starts[a.line]+a.ch,starts[b.line]+b.ch)};
            void 0;
            """)
            let reply=try await page.capture(start:start,end:start+4)
            #expect((reply["capture"] as? [String:Any])?["method"] as? String == "editorRange")
            try await assertReviewFlow(page,reply:reply,target:"bank",source:raw,start:start,sentence:sentence)
        }
    }

    @Test func batch2ReadingNaturalWindowRetainsRejectedBoundaryEvidence() async throws {
        let raw="Earlier line\n"+String(repeating:"Context word. ",count:200)+"We sat on the bank of the river.",page=DOMCapturePage()
        try await page.load("<div id='reading-root'><p id='p'>\(raw)</p></div>",adapter:"obsidian")
        let reply=try await page.capture(start:2827,end:2831,reverse:true)
        let source=String(decoding:Array(raw.utf16)[831..<2831],as:UTF16.self)
        #expect(!source.contains("\n") && source.utf16.count==2000)
        try await assertReviewFlow(page,reply:reply,target:"bank",source:source,start:1996,sentence:nil)
    }
}

@MainActor
final class DOMCapturePage: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }())
    private var navigation: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private(set) var adapter = "chromium"

    func load(_ html: String, adapter: String = "chromium") async throws {
        self.adapter = adapter
        _ = NSApplication.shared
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                self?.finish(.failure(DOMTestError.navigationDeadline))
            }
            view.loadHTMLString("<!doctype html><html lang='en'><body>\(html)</body></html>", baseURL: nil)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if adapter == "obsidian" {
            let script = try String(contentsOf: root.appendingPathComponent("extensions/obsidian/main.js"), encoding: .utf8)
            _ = try await evaluate("""
            window.module={exports:{}};window.pluginNotices=[];
            window.require=()=>({MarkdownView:class{},Plugin:class{
                async loadData(){return {tokenSecretId:'disposable-reading-only'};}addSettingTab(){}addCommand(c){window.pluginCommand=c;}
            },PluginSettingTab:class{},Setting:class{},Notice:class{constructor(m){pluginNotices.push(m);}},
            requestUrl:async(r)=>{window.postedBody=r.body;return {status:204};}});
            """ + script + "\nvoid 0;")
            _ = try await evaluate("""
            window.activeMarkdownView={getMode:()=> 'preview',previewMode:{containerEl:document.getElementById('reading-root')},editor:{getSelection:()=> 'stale editor bank'}};
            window.plugin=new module.exports();plugin.app={secretStorage:{getSecret:()=> 'disposable-reading-only',setSecret(){throw Error('unexpected credential write');}},workspace:{getActiveViewOfType:()=>window.activeMarkdownView,activeEditor:{editor:activeMarkdownView.editor}}};
            void 0;
            """)
            _ = try await asyncEvaluate("await plugin.onload();return null;")
        } else if adapter == "safari" {
            // The injected IIFE runs after the fixture selection, just as Safari does.
        } else {
            let script = try String(contentsOf: root.appendingPathComponent("extensions/chromium/content.js"), encoding: .utf8)
            _ = try await evaluate("window.chrome = {runtime:{onMessage:{addListener(){}}}};\n" + script)
        }
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await view.evaluateJavaScript(script)
    }

    func asyncEvaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
    }

    func capture(start: Int, end: Int, reverse: Bool = false) async throws -> [String: Any] {
        let value = try await evaluate("""
        var walker = document.createTreeWalker(document.getElementById('p'), NodeFilter.SHOW_TEXT);
        var texts = []; while(walker.nextNode()) texts.push(walker.currentNode);
        function endpoint(offset) { for(const n of texts) { if(offset <= n.length) return [n,offset]; offset-=n.length; } throw Error('bad fixture endpoint'); }
        var a=endpoint(\(start)), b=endpoint(\(end));
        window.getSelection().setBaseAndExtent(...\(reverse ? "b" : "a"), ...\(reverse ? "a" : "b"));
        \(adapter == "chromium" ? "extractSelection();" : "void 0;")
        """)
        if adapter == "obsidian" {
            return try #require(try await asyncEvaluate("window.postedBody=null;await pluginCommand.callback();return postedBody?JSON.parse(postedBody):{empty:true};") as? [String: Any])
        }
        if adapter == "safari" {
            let reply = try #require(try await evaluate(SafariContextExtractor.injectionScript) as? String)
            return try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        }
        return try #require(value as? [String: Any])
    }

    func sendThroughWorker(_ payload: [String:Any]) async throws -> String {
        if adapter == "obsidian" { return try #require(try await evaluate("window.postedBody") as? String) }
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=try String(contentsOf:root.appendingPathComponent("extensions/chromium/service-worker.js"),encoding:.utf8)
        let payloadJSON=String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)
        _ = try await evaluate("""
        chrome.tabs={sendMessage:async()=> (\(payloadJSON))};
        chrome.storage={local:{get:async()=>({token:'disposable-test-only'})}};
        chrome.commands={onCommand:{addListener(){}}};
        window.workerNotices=[]; chrome.notifications={create(n){window.workerNotices.push(n.message);}};
        window.fetch=async(_url,init)=>{window.postedBody=init.body; return {status:204,ok:true};};
        """ + source)
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("await lookup(1); return {body:window.postedBody,notices:window.workerNotices};",arguments:[:],in:nil,in:.page) {
                continuation.resume(with:$0)
            }
        }
        let outcome=try #require(value as? [String:Any])
        #expect((outcome["notices"] as? [String])?.isEmpty == true)
        return try #require(outcome["body"] as? String)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = navigation else { return }
        navigation = nil
        deadline?.cancel()
        continuation.resume(with: result)
    }
}

private enum DOMTestError: Error { case navigationDeadline }

private func jsScalar(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }
struct NewlineFixture { let raw: String; let start: Int; var html: String? = nil }
func newlineFixture(_ n: Int) -> NewlineFixture {
    switch n {
    case 1: return .init(raw:"We sat on the bank of the river.", start:14)
    case 2: return .init(raw:"We sat on the\nbank of the river.", start:14)
    case 3: return .init(raw:"The bank closed.\nWe sat on the bank.", start:31)
    case 4: return .init(raw:"We sat on the bank\nof the river.", start:14)
    case 5: return .init(raw:"bank of the river.", start:0)
    case 6: return .init(raw:"We sat on the bank", start:14)
    case 7: return .init(raw:"A bank near the river", start:2)
    case 8: return .init(raw:"The bank closed.\nWe sat on the bank of the river.", start:31)
    case 9: return .init(raw:"🌊 e\u{301} — We sat on the\r\nbank of the river.", start:23)
    case 10: return .init(raw:"We sat on the\nbank of the river.", start:14, html:"<p id='p'>We sat on the\nba<strong>nk</strong> of the river.</p>")
    case 11: return .init(raw:"We sat on the\nbank approved my loan. bank of the river.", start:37, html:"<p id='p'>We sat on the\n<span hidden>bank approved my loan. </span>bank of the river.</p>")
    case 12: return .init(raw:"\nWe sat on the bank of the river.\n", start:15)
    case 13: return .init(raw:"Earlier line\nWe sat on the bank of the river.", start:27)
    case 14: return .init(raw:"We sat on the bank of the river.", start:14, html:"<p>The bank closed.</p><p id='p'>We sat on the bank of the river.</p>")
    case 15: return .init(raw:"We sat on the bank of the river.", start:14, html:"<p id='p' style='width:65px'>We sat on the bank of the river.</p>")
    default: return .init(raw:"We sat on the\u{85}bank of the river.", start:14)
    }
}
