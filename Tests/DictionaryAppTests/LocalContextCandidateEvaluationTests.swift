import Foundation
import CryptoKit
import Testing
@testable import DictionaryApp

/// Opt-in research only. This does not enable the single-word prompt in the app.
struct LocalContextCandidateEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_CONTEXT_CANDIDATE_LIVE"] == "1"),
          .timeLimit(.minutes(5)))
    func recordExistingContextPromptForSingleWords() async throws {
        let run=try DictionaryQualityRun(environment:ProcessInfo.processInfo.environment)
        let installed=try await OllamaModelListClient().models()
        try #require(run.isInstalledLocally(in:installed))
        let provider=OllamaProvider(model:run.model,disableThinking:run.disableThinking)
        let session=URLSession(configuration:.ephemeral,delegate:LocalModelRedirectGuard(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        print("CANDIDATE_META model=\(run.model) route=\(run.route) rounds=\(run.rounds) cases=\(run.samples.count) disableThinking=\(run.disableThinking)")
        for round in 1...run.rounds {
            for sample in run.samples {
                try Task.checkCancellation()
                let input=try run.request(for:sample)
                let started=ContinuousClock.now
                let result:Translation
                if let sentence=input.containingSentence {
                    let prompt=LocalContextPrompt.build(target:input.target,context:input.providerContext,
                        sentence:sentence,targetLanguage:"简体中文")
                    let digest=SHA256.hash(data:Data(prompt.system.utf8)).map { String(format:"%02x",$0) }.joined()
                    print("CANDIDATE_INPUT \(round) \(sample.id) promptSHA256=\(digest)")
                    var body:[String:Any]=["model":run.model,"stream":false,"keep_alive":"5m",
                        "format":LocalContextPrompt.responseFormat,"options":["temperature":0],
                        "messages":[["role":"system","content":prompt.system],["role":"user","content":prompt.userInstruction]]]
                    if run.disableThinking { body["think"]=false }
                    var request=URLRequest(url:URL(string:"http://localhost:11434/api/chat")!)
                    request.httpMethod="POST"; request.timeoutInterval=60
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                    request.httpBody=try JSONSerialization.data(withJSONObject:body)
                    let (data,response)=try await session.data(for:request)
                    try #require((response as? HTTPURLResponse)?.statusCode == 200)
                    struct Envelope:Decodable { struct Message:Decodable { let content:String }; let message:Message }
                    let content=try JSONDecoder().decode(Envelope.self,from:data).message.content
                    let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    result=try decoder.decode(Translation.self,from:Data(JSONExtractor.extract(content).utf8))
                } else {
                    // The candidate does not invent a missing sentence or change target-only lookup.
                    result=try await provider.translate(target:input.target,context:input.providerContext,
                        containingSentence:nil,targetLanguage:"简体中文")
                }
                print("CANDIDATE \(round) \(sample.id) " + String(decoding:try encoder.encode(result),as:UTF8.self))
                print("CANDIDATE_TIME \(round) \(sample.id) \(started.duration(to:.now))")
            }
        }
    }
}
