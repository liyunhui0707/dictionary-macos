import CryptoKit
import Foundation
import Testing
@testable import DictionaryApp

/// Research is opt-in, local only and never changes a saved/default model.
/// Freeze the prompt and holdout before the first call; inspect every output.
struct LocalQualityRefinementTests {
    static let holdout: [DictionaryQualityCase] = [
        .init(id: "new-decision", target: "made", context: "After lunch, the committee made a decision.", rubric: "作出/做出决定中的作出；verb；不是制作；保留午饭后/委员会/决定"),
        .init(id: "new-break", target: "took", context: "The workers took a short break beside the gate.", rubric: "休息/进行；verb；不是拿走；保留工人/短暂/大门旁"),
        .init(id: "new-existence", target: "There", context: "There were at least three empty chairs near the door.", rubric: "存在句形式主语；pronoun；不是那里；至少三把/空/门旁完整"),
        .init(id: "new-location", target: "there", context: "We left both boxes there until Tuesday.", rubric: "那里；adverb；保留两个箱子/直到周二"),
        .init(id: "new-accused", target: "charged", context: "The driver was charged with theft, but denied it.", rubric: "指控；verb；保留司机/盗窃/否认；不是收费充电"),
        .init(id: "new-fee", target: "charged", context: "The museum charged each visitor four pounds.", rubric: "收取；verb；保留每名游客/四英镑"),
        .init(id: "new-animal", target: "seal", context: "A young seal slept beside the rocks.", rubric: "海豹；noun；保留幼小/睡/岩石旁"),
        .init(id: "new-close", target: "seal", context: "Please seal the envelope before you leave.", rubric: "封好；verb；保留信封/离开前"),
        .init(id: "new-organize", target: "runs", context: "Mina runs a small bakery near the station.", rubric: "经营；verb；保留人名/小面包店/车站附近"),
        .init(id: "new-flow", target: "runs", context: "Cold water runs through the narrow pipe.", rubric: "流/流过；verb；保留冷水/狭窄管道"),
        .init(id: "new-idiom", target: "hit the road", context: "We should hit the road before sunrise.", rubric: "动身/上路；idiom；保留日出前；不是击打道路"),
        .init(id: "new-phrasal", target: "take off", context: "The plane will take off in twenty minutes.", rubric: "起飞；phrasal verb；保留飞机/二十分钟后"),
        .init(id: "new-unknown", target: "qrvxelta", context: "The package bears the label qrvxelta.", rubric: "主释义及词性null；句译保留qrvxelta；不编造"),
        .init(id: "new-name", target: "Noor", context: "Noor sent two invitations on Friday.", rubric: "人名；noun；保留Noor/两份邀请/周五"),
        .init(id: "new-bank", target: "bank", context: "They waited on the bank of the stream while the rain stopped.", rubric: "河岸/溪岸；noun；句译必须有岸边/等候/雨停，不漏掉岸边"),
        .init(id: "new-negation", target: "ready", context: "The rooms were ready, but neither guest arrived before ten.", rubric: "准备好的；adjective；保留房间/两位客人都没有/十点前")
    ]

    static func refined(_ original: PromptParts) -> PromptParts {
        var system = original.system.replacingOccurrences(of: #""alternatives":\[[^\]]*\]"#, with: #""alternatives":[]"#, options: .regularExpression)
        system = system.replacingOccurrences(of: "alternatives may contain up to three other short translations valid in THIS context, or remain empty.", with: "literal_gloss must be null and alternatives must be empty. Generate only the one sense supported by this sentence.")
        system += "\nBefore returning JSON, verify the complete sentence translation preserves who does what, every predicate and its object/complement, place and time relations, quantities and negations. In particular, do not omit the phrase containing TARGET. A fluent summary is not a complete sentence translation. Verify the target gloss fits that translated sentence and its grammatical role; abstain with null rather than invent a meaning for an uninterpretable label. Do not output reasoning or additional fields."
        return PromptParts(system: system, userInstruction: original.userInstruction)
    }

    static var schema: [String: Any] {
        var result = LocalContextPrompt.responseFormat
        var properties = result["properties"] as! [String: Any]
        properties["alternatives"] = ["type": "array", "items": ["type": "string"], "maxItems": 0]
        result["properties"] = properties
        return result
    }

    @Test func candidateAndHoldoutAreFrozenWithoutChangingProductionRouting() throws {
        #expect(Self.holdout.count == 16 && Set(Self.holdout.map(\.id)).count == 16)
        let sample = try #require(Self.holdout.first)
        let input = try LookupRequest.manual(target: sample.target, context: sample.context)
        let original = LocalContextPrompt.build(target: input.target, context: input.providerContext,
            sentence: sample.context, targetLanguage: "简体中文")
        let candidate = Self.refined(original)
        #expect(candidate.system != original.system)
        #expect(candidate.userInstruction == original.userInstruction)
        for sample in Self.holdout { #expect(!candidate.system.contains(sample.context)) }
        let properties = try #require(Self.schema["properties"] as? [String: [String: Any]])
        #expect(properties["alternatives"]?["maxItems"] as? Int == 0)
        #expect(!LocalContextPrompt.applies(target: input.target, context: input.providerContext, sentence: sample.context))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_REFINEMENT_LIVE"] == "1"), .timeLimit(.minutes(15)))
    func recordFrozenCandidate() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = try #require(environment["DICTIONARY_REFINEMENT_MODEL"])
        try #require(["qwen2.5:7b", "qwen3.5:9b-q4_K_M"].contains(model))
        let set = try #require(environment["DICTIONARY_REFINEMENT_SET"])
        try #require(["acceptance", "holdout"].contains(set))
        let run = try DictionaryQualityRun(environment: ["DICTIONARY_QUALITY_MODEL": model,
            "DICTIONARY_QUALITY_SET": "acceptance", "DICTIONARY_QUALITY_ROUTE": set == "acceptance" ? "anchored" : "heuristic",
            "DICTIONARY_QUALITY_ROUNDS": "1"])
        let samples = set == "acceptance" ? run.samples : Self.holdout
        try #require(samples.count == 16)
        try #require(run.isInstalledLocally(in: try await OllamaModelListClient().models()))
        let session = URLSession(configuration: .ephemeral, delegate: LocalModelRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let provider = OllamaProvider(model: model, dictionary: EnglishDictionary(resourceURL: nil), session: session)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let started = ContinuousClock.now
        for sample in samples {
            try Task.checkCancellation()
            try #require(started.duration(to: .now) < .seconds(840))
            let input = try run.request(for: sample)
            let result: Translation
            let callStarted = ContinuousClock.now
            if let sentence = input.containingSentence {
                let prompt = Self.refined(LocalContextPrompt.build(target: input.target, context: input.providerContext,
                    sentence: sentence, targetLanguage: "简体中文"))
                let digest = SHA256.hash(data: Data(prompt.system.utf8)).map { String(format: "%02x", $0) }.joined()
                print("REFINEMENT_INPUT \(sample.id) promptSHA256=\(digest)")
                var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
                request.httpMethod = "POST"; request.timeoutInterval = 60
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": false,
                    "keep_alive": "5m", "think": false, "format": Self.schema, "options": ["temperature": 0],
                    "messages": [["role": "system", "content": prompt.system], ["role": "user", "content": prompt.userInstruction]]])
                let (data, response) = try await session.data(for: request)
                try #require((response as? HTTPURLResponse)?.statusCode == 200)
                struct Envelope: Decodable { struct Message: Decodable { let content: String }; let message: Message }
                let raw = try JSONDecoder().decode(Envelope.self, from: data).message.content
                print("REFINEMENT_RAW \(sample.id) " + String(decoding: try encoder.encode(raw), as: UTF8.self))
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                result = try decoder.decode(Translation.self, from: Data(JSONExtractor.extract(raw).utf8))
            } else {
                result = try await provider.translate(target: input.target, context: input.providerContext,
                    containingSentence: nil, targetLanguage: "简体中文")
            }
            print("REFINEMENT \(sample.id) " + String(decoding: try encoder.encode(result), as: UTF8.self))
            print("REFINEMENT_TIME \(sample.id) \(callStarted.duration(to: .now))")
        }
    }
}
