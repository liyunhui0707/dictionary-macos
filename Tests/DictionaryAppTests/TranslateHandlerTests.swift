import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranslateHandlerTests {
    // P03: existing HTTP input accepts unknown metadata, but baseline loses its position.
    @Test func sameSentenceSelectedOccurrencesReachProviderDistinctly() async throws {
        let (provider, _, handler, token) = setup()
        let text = "I called the bank while sitting on the bank of the river."
        var calls: [ControlledProvider.Call] = []
        for (ordinal, start) in [13, 39].enumerated() {
            let body: [String: Any] = ["target": "bank", "context": text, "containingSentence": text,
                "capture": ["version": 1, "unit": "utf16", "reliability": "anchored", "method": "domRange",
                            "range": ["start": start, "end": start + 4],
                            "sentenceRange": ["start": 0, "end": 57]]]
            let input = HTTPRequest(method: "POST", path: "/v1/translate", headers: ["authorization": "Bearer \(token)"],
                                    body: try JSONSerialization.data(withJSONObject: body))
            let response = Task { await handler.handle(input) }
            let call = await provider.waitForCall("bank", occurrence: ordinal + 1)
            calls.append(call)
            await provider.succeed(call)
            #expect(await response.value.status == 200)
        }
        #expect(calls[0].id != calls[1].id)
        #expect(calls[0].context != calls[1].context)
        for (call,start) in zip(calls,[13,39]) {
            let d = try providerDocument(call.context)
            let split = try #require(d["selection"] as? [String:Any])
            #expect(split["start"] as? Int == start)
            #expect(split["text"] as? String == "bank")
            #expect((split["before"] as? String ?? "") + "bank" + (split["after"] as? String ?? "") == text)
        }
    }

    @Test func malformedOptionalMetadataIsNonfatalAndSentenceDamageIsIsolated() async throws {
        let (provider, _, handler, token) = setup()
        let valid: [String:Any] = ["version":1,"unit":"utf16","method":"domRange","reliability":"anchored",
                                  "range":["start":14,"end":18],"sentenceRange":["start":0,"end":32]]
        var variants: [[String:Any]] = []
        for (key,value) in [("version",2 as Any),("unit","bytes"),("method","PRIVATE_UNKNOWN"),("reason","PRIVATE_UNKNOWN"),
                            ("range",["start":true,"end":18]),("range",["start":14.5,"end":18]),
                            ("range",["start":"14","end":18]),("range",["start":14,"end":99999])] {
            var bad=valid; bad[key]=value; variants.append(bad)
        }
        var sentenceDamage=valid; sentenceDamage["sentenceRange"]=["start":"bad","end":32]; variants.append(sentenceDamage)
        let claims:[Any] = [NSNull(),true,[],"not metadata"] + variants
        for (i,metadata) in claims.enumerated() {
            let body: [String:Any] = ["target":"bank","context":"We sat on the bank of the river.",
                                     "containingSentence":"We sat on the bank of the river.","capture":metadata]
            let response=Task { await handler.handle(HTTPRequest(method:"POST",path:"/v1/translate",
                headers:["authorization":"Bearer \(token)"],body:try! JSONSerialization.data(withJSONObject:body))) }
            let call=await provider.waitForCall("bank",occurrence:i+1)
            let document=try providerDocument(call.context)
            if i == claims.count-1 {
                #expect(document["mode"] as? String == "anchored")
                #expect(call.sentence == nil)
                #expect((document["selection"] as? [String:Any])?["start"] as? Int == 14)
            } else { #expect(document["selection"] is NSNull) }
            await provider.succeed(call)
            #expect(await response.value.status == 200)
        }
    }

    @Test func HTTPAliasesAndSelectedWhitespaceRebaseWithoutLosingTheRawSlice() async throws {
        let (provider,_,handler,token)=setup()
        for (i,target) in [" bank ","bank"].enumerated() {
            let metadata:[String:Any] = ["version":1,"unit":"utf16","reliability":"anchored","method":"domRange",
                                        "range":["start":5,"end":11],"sentence_range":["start":2,"end":18]]
            let body:[String:Any] = ["target":target,"context":"  The bank closed.  ","containing_sentence":"The bank closed.",
                                    "source_app":"Chromium","capture":metadata]
            let response=Task { await handler.handle(HTTPRequest(method:"POST",path:"/v1/translate",
                headers:["authorization":"Bearer \(token)"],body:try! JSONSerialization.data(withJSONObject:body))) }
            let call=await provider.waitForCall("bank",occurrence:i+1)
            let split=try #require(try providerDocument(call.context)["selection"] as? [String:Any])
            #expect(split["start"] as? Int == 4 && split["end"] as? Int == 8)
            #expect(call.sentence == "The bank closed.")
            await provider.succeed(call)
            #expect(await response.value.status == 200)
        }
    }

    private func setup() -> (ControlledProvider, LookupCoordinator, TranslateHandler, String) {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryTests-\(UUID().uuidString)")
        let tokens = TokenStore(directory: directory)
        return (provider, coordinator, TranslateHandler(tokenStore: tokens, coordinator: coordinator), tokens.token)
    }

    private func request(_ token: String, target: String = "bank") -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/translate", headers: ["authorization": "Bearer \(token)"],
                    body: try! JSONSerialization.data(withJSONObject: ["target": target]))
    }

    @Test func rejectedRequestsCannotCancelActiveLookup() async throws {
        let (provider, coordinator, handler, token) = setup()
        let active = coordinator.submit(try .manual(target: "active", context: ""), to: .selection)
        await provider.waitForCall("active")
        let invalid: [(HTTPRequest, Int)] = [
            (HTTPRequest(method: "GET", path: "/v1/translate", headers: [:], body: Data()), 404),
            (HTTPRequest(method: "POST", path: "/other", headers: [:], body: Data()), 404),
            (request("wrong"), 401),
            (HTTPRequest(method: "POST", path: "/v1/translate", headers: [:], body: Data()), 401),
            (HTTPRequest(method: "POST", path: "/v1/translate", headers: ["authorization": "Basic bad"], body: Data()), 401),
            (HTTPRequest(method: "POST", path: "/v1/translate", headers: ["authorization": "Bearer \(token)"], body: Data("{".utf8)), 400),
            (request(token, target: " \n"), 400)
        ]
        for (input, status) in invalid {
            #expect(await handler.handle(input).status == status)
            #expect(coordinator.selection.isLoading)
        }
        #expect(await provider.calls.count == 1)
        await provider.succeed("active")
        #expect(await active.value.result != nil)
    }

    @Test func successPreservesWireSchemaAndManualIndependence() async throws {
        let (provider, coordinator, handler, token) = setup()
        let response = Task { await handler.handle(request(token)) }
        await provider.waitForCall("bank")
        let manual = coordinator.submit(try .manual(target: "manual", context: ""), to: .manual)
        await provider.waitForCall("manual")
        #expect(coordinator.selection.isLoading)
        await provider.succeed("bank", meaning: "河岸")
        let result = await response.value
        #expect(result.status == 200)
        let json = try #require(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect(json["meaning_in_context"] as? String == "河岸")
        #expect(json["request"] == nil)
        #expect(coordinator.selection.result?.request.target == "bank")
        await provider.succeed("manual")
        #expect(await manual.value.result != nil)
    }

    @Test func cancelledHTTPRespondsBeforeProviderCompletes() async throws {
        let (provider, coordinator, handler, token) = setup()
        let response = Task { await handler.handle(request(token)) }
        await provider.waitForCall("bank")
        coordinator.dismissSelection()
        let result = await response.value
        #expect(result.status == 204)
        #expect(result.body.isEmpty)
        await provider.fail("bank")
        #expect(coordinator.selection.result == nil)
    }

    @Test func supersededHTTPResponds204AndProviderFailureRemains503() async throws {
        let (provider, _, handler, token) = setup()
        let old = Task { await handler.handle(request(token, target: "old")) }
        await provider.waitForCall("old")
        let new = Task { await handler.handle(request(token, target: "new")) }
        await provider.waitForCall("new")
        #expect(await old.value.status == 204)
        await provider.fail("new")
        #expect(await new.value.status == 503)
        await provider.succeed("old")
    }

    @Test func noContentWireResponseHasNoBodyOrLength() {
        let bytes = HTTPServer.serialize(.empty(status: 204))
        let wire = String(decoding: bytes, as: UTF8.self)
        #expect(wire.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(!wire.lowercased().contains("content-length"))
        #expect(wire.hasSuffix("\r\n\r\n"))
    }
}
