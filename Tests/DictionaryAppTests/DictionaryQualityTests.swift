import Foundation
import CryptoKit
import Testing
@testable import DictionaryApp

/// Synthetic examples only. Rubrics require semantic review, not substring scoring.
struct DictionaryQualityCase: Sendable {
    let id: String
    let target: String
    let context: String
    let rubric: String

    static let samples: [Self] = [
        .init(id: "plural", target: "Students", context: "Students learn by asking questions.", rubric: "学生；noun；完整翻译原句"),
        .init(id: "past-fee", target: "charged", context: "The shop charged me ten dollars for delivery.", rubric: "收取/收费；verb；不是收费的"),
        .init(id: "past-battery", target: "charged", context: "I charged the battery before leaving home.", rubric: "充电；verb；不是收费"),
        .init(id: "collocation", target: "making", context: "We learn by making mistakes and correcting them.", rubric: "犯/犯下；verb；不是制作；完整翻译两个并列动作"),
        .init(id: "existential", target: "There", context: "There are two books on the desk.", rubric: "存在句引导词；不是地点那里或noun；句译保留数量和位置"),
        .init(id: "bank-money", target: "bank", context: "The bank approved her loan yesterday.", rubric: "银行；noun；完整翻译时间和贷款"),
        .init(id: "bank-river", target: "bank", context: "They walked along the bank of the river.", rubric: "河岸；noun"),
        .init(id: "run-business", target: "runs", context: "She runs a small bakery near the station.", rubric: "经营；verb；不是跑步"),
        .init(id: "phrasal", target: "look up", context: "Please look up this word in a dictionary.", rubric: "查阅/查找；phrasal verb；不是向上看"),
        .init(id: "unknown", target: "zyxqvexample", context: "The sample was labelled zyxqvexample.", rubric: "标明未知含义，不编造词性或词源；句译保留标签"),
        .init(id: "no-context", target: "charged", context: "", rubric: "常见词义及合理备选；不声称已确定语境；句译为null"),
        .init(id: "complete-sentence", target: "hard", context: "The rules sound simple, but they are hard to apply without practice.", rubric: "难的；adjective；句译包含前后两个分句及without practice")
    ]

    // Locked before the candidate prompt: never copy these into few-shot examples.
    static let validation: [Self] = [
        .init(id: "validation-plural", target: "Readers", context: "Readers can borrow three books at a time.", rubric: "读者；noun；句译保留三本/每次"),
        .init(id: "validation-irregular", target: "bought", context: "She bought fresh bread before work.", rubric: "买；verb；保留上班前"),
        .init(id: "validation-collocation", target: "took", context: "He took a photo of the old bridge.", rubric: "拍摄/拍；verb；不是拿走"),
        .init(id: "validation-existential", target: "There", context: "There was no water in the bottle.", rubric: "存在句用法；非那里/noun；句译不丢失否定"),
        .init(id: "validation-phrasal", target: "give up", context: "She refused to give up despite the setbacks.", rubric: "放弃；phrasal verb；保留拒绝和尽管"),
        .init(id: "validation-idiom", target: "break the ice", context: "He told a joke to break the ice.", rubric: "打破僵局/缓和气氛；idiom；不是敲碎冰块"),
        .init(id: "validation-unknown", target: "vqxtralen", context: "The label reads vqxtralen.", rubric: "含义不明；不编造词性和解释；原句保留标签"),
        .init(id: "validation-name", target: "Ada", context: "Ada mailed the letter on Monday.", rubric: "艾达/人名；不能当无效词；原句保留名字和周一"),
        .init(id: "validation-unknown-alone", target: "vqxtralen", context: "", rubric: "含义不明；词性和句译null；无编造备选"),
        .init(id: "validation-negation", target: "ready", context: "The food was ready, but nobody ate it because the guests had not arrived.", rubric: "准备好的；adjective；句译保留全部分句和两个否定")
    ]

    // Final check, separate from the development set and evaluated after prompt selection.
    static let verification: [Self] = [
        .init(id: "verify-ing", target: "dancing", context: "They were dancing in the courtyard.", rubric: "跳舞；verb；保留庭院"),
        .init(id: "verify-phrasal", target: "put up with", context: "I cannot put up with this noise.", rubric: "忍受；phrasal verb；句译保留不能"),
        .init(id: "verify-polysemy", target: "took", context: "The journey took three hours.", rubric: "花费/耗时；verb；句译保留三小时"),
        .init(id: "verify-existential", target: "There", context: "There is a small cafe beside the library.", rubric: "存在句作用；pronoun；句译保留图书馆旁/小咖啡馆"),
        .init(id: "verify-locative", target: "there", context: "Please leave your bag there.", rubric: "那里；adverb；不能把所有there都当存在句"),
        .init(id: "verify-unknown", target: "mnzavex", context: "The identifier is mnzavex.", rubric: "无可靠释义；不编造；句译保留原标签"),
        .init(id: "verify-no-context", target: "open", context: "", rubric: "常见义（打开/开放的）与词性一致；句译null"),
        .init(id: "verify-name", target: "Liam", context: "Liam waited outside.", rubric: "利亚姆/人名；noun；句译保留在外等候")
    ]

    // Target-only development set. Includes common inflections, polysemy,
    // function words and gaps in the offline lexicon, not just charged.
    static let targetOnly: [Self] = [
        .init(id: "alone-charged", target: "charged", context: "", rubric: "常用义；释义与词性一致；不漏义"),
        .init(id: "alone-ran", target: "ran", context: "", rubric: "跑/奔跑；verb；保留不规则原形含义"),
        .init(id: "alone-children", target: "children", context: "", rubric: "孩子/儿童；noun"),
        .init(id: "alone-bank", target: "bank", context: "", rubric: "银行或河岸；noun；备选合理"),
        .init(id: "alone-give-up", target: "give up", context: "", rubric: "放弃；phrasal verb"),
        .init(id: "alone-making", target: "making", context: "", rubric: "制作（verb）或制造/形成（noun）；词性一致"),
        .init(id: "alone-careful", target: "careful", context: "", rubric: "小心的/仔细的；adjective"),
        .init(id: "alone-record", target: "record", context: "", rubric: "记录/纪录；noun或verb与释义一致"),
        .init(id: "alone-there", target: "there", context: "", rubric: "那里；adverb；不虚构存在句"),
        .init(id: "alone-although", target: "although", context: "", rubric: "虽然/尽管；conjunction；缺词典条目仍可释义"),
        .init(id: "alone-name", target: "Ada", context: "", rubric: "艾达/人名；noun；不因词典缺条目拒绝"),
        .init(id: "alone-unknown", target: "vqxtralen", context: "", rubric: "无可靠释义；无编造词性和备选")
    ]

    // Not used to tune the target-only prompt; run only after choosing a candidate.
    static let targetOnlyVerification: [Self] = [
        .init(id: "final-women", target: "women", context: "", rubric: "女人/妇女；noun；不是女人的"),
        .init(id: "final-left", target: "left", context: "", rubric: "左边/左的/离开等常用义；与词性一致"),
        .init(id: "final-set", target: "set", context: "", rubric: "放置/设置/一套等常用义；不堆砌互不相关定义"),
        .init(id: "final-take-off", target: "take off", context: "", rubric: "起飞/脱下；phrasal verb"),
        .init(id: "final-serene", target: "serene", context: "", rubric: "平静的/安详的；adjective"),
        .init(id: "final-oxygen", target: "oxygen", context: "", rubric: "氧/氧气；noun"),
        .init(id: "final-towards", target: "towards", context: "", rubric: "朝/向；preposition；缺条目不拒绝"),
        .init(id: "final-unknown", target: "plonqiv", context: "", rubric: "无可靠释义；无编造词性和备选")
    ]

    // Locked before the grounded single-word candidate's first evaluation.
    static let contextualWords: [Self] = [
        .init(id: "word-fee-negative", target: "charged", context: "The hotel charged us twenty euros, but did not charge for breakfast.", rubric: "收取；verb；保留二十欧元及早餐不收费"),
        .init(id: "word-decision", target: "made", context: "They made a decision after three meetings.", rubric: "作出；verb；不是制作；保留三次会议之后"),
        .init(id: "word-transport", target: "took", context: "She took the bus because her car was not ready.", rubric: "乘坐；verb；保留原因及否定"),
        .init(id: "word-liquid", target: "runs", context: "Cold water runs through the pipe.", rubric: "流动/流；verb；不是经营；保留冷水及管道"),
        .init(id: "word-left", target: "left", context: "He left the office before five.", rubric: "离开；verb；不是左边；保留五点之前"),
        .init(id: "word-existence", target: "There", context: "There are three cats under the table.", rubric: "存在句引导；pronoun；保留三只及桌子下面"),
        .init(id: "word-location", target: "there", context: "We waited there for two hours.", rubric: "那里；adverb；保留两小时"),
        .init(id: "word-light", target: "light", context: "The bag is light, but it is not empty.", rubric: "轻的；adjective；保留不是空的"),
        .init(id: "word-unknown", target: "vqzomel", context: "The tag says vqzomel.", rubric: "无可靠释义；不编造；标签保留原拼写"),
        .init(id: "word-name", target: "Maya", context: "Maya sent two letters on Friday.", rubric: "人名/玛雅；不当无效词；保留两封和周五")
    ]

    // Locked after narrowing the candidate to contextual expressions, before this
    // set's first live run. No examples below appear in the selected prompt.
    static let phrases: [Self] = [
        .init(id: "phrase-care", target: "looked after", context: "She looked after the children all evening.", rubric: "照顾；phrasal verb；保留整个晚上"),
        .init(id: "phrase-meeting", target: "ran into", context: "I ran into an old friend at the station.", rubric: "偶遇；phrasal verb；不是撞上；保留车站"),
        .init(id: "phrase-ill", target: "under the weather", context: "She felt under the weather and stayed home.", rubric: "身体不适；idiom；保留待在家"),
        .init(id: "phrase-easy", target: "a piece of cake", context: "The puzzle was a piece of cake for him.", rubric: "轻而易举/小菜一碟；idiom；不是蛋糕"),
        .init(id: "phrase-place", target: "in front of", context: "Two chairs stood in front of the desk.", rubric: "在……前面；preposition；保留两把椅子"),
        .init(id: "phrase-literal", target: "opened the door", context: "He opened the door quietly.", rubric: "打开门；verb；不是phrasal verb或idiom；保留轻轻地"),
        .init(id: "phrase-noise", target: "put up with", context: "I cannot put up with this noise.", rubric: "忍受；phrasal verb；保留不能"),
        .init(id: "phrase-omit", target: "leave out", context: "He did not leave out any names from the list.", rubric: "遗漏；phrasal verb；保留没有漏掉任何名字")
    ]
}

/// Evaluation settings only; never persisted to application preferences.
struct DictionaryQualityRun {
    enum SampleSet: String {
        case development, verification, phrases
        case targetOnly = "target-only", targetOnlyVerification = "target-only-verification"
        case contextualWords = "contextual-words", contextSmoke = "context-smoke"
    }
    enum InvalidConfiguration: Error { case rounds, sampleSet, model }
    let model: String
    let rounds: Int
    let sampleSet: SampleSet

    init(environment: [String: String]) throws {
        guard let rounds = Int(environment["DICTIONARY_QUALITY_ROUNDS"] ?? "3"), (1...3).contains(rounds) else {
            throw InvalidConfiguration.rounds
        }
        guard let sampleSet = SampleSet(rawValue: environment["DICTIONARY_QUALITY_SET"] ?? "development") else {
            throw InvalidConfiguration.sampleSet
        }
        let model = environment["DICTIONARY_QUALITY_MODEL"] ?? "qwen2.5:7b"
        guard LocalModelConfiguration.validModel(model) else { throw InvalidConfiguration.model }
        self.model = model
        self.rounds = rounds
        self.sampleSet = sampleSet
    }

    var samples: [DictionaryQualityCase] {
        switch sampleSet {
        case .development: DictionaryQualityCase.samples + DictionaryQualityCase.validation
        case .verification: DictionaryQualityCase.verification
        case .phrases: DictionaryQualityCase.phrases
        case .targetOnly: DictionaryQualityCase.targetOnly
        case .targetOnlyVerification: DictionaryQualityCase.targetOnlyVerification
        case .contextualWords: DictionaryQualityCase.contextualWords
        case .contextSmoke:
            DictionaryQualityCase.samples.filter { ["past-fee", "collocation", "existential", "complete-sentence"].contains($0.id) } +
            DictionaryQualityCase.validation.filter { $0.id == "validation-negation" }
        }
    }

    func isInstalledLocally(in names: [String]) -> Bool {
        names.contains { LocalModelConfiguration.matches(model, $0) }
    }
}

struct DictionaryQualityTests {
    @Test func samplesUseProductionRequestFraming() throws {
        let samples = DictionaryQualityCase.samples + DictionaryQualityCase.validation + DictionaryQualityCase.verification + DictionaryQualityCase.targetOnly + DictionaryQualityCase.targetOnlyVerification + DictionaryQualityCase.phrases + DictionaryQualityCase.contextualWords
        #expect(Set(samples.map(\.id)).count == samples.count)
        for sample in samples {
            let request = try LookupRequest.manual(target: sample.target, context: sample.context)
            let document = try providerDocument(request.providerContext)
            #expect(document["mode"] as? String == "manual")
            #expect(document["selection"] is NSNull)
            #expect(request.containingSentence == (sample.context.isEmpty ? nil : sample.context))
        }
    }

    @Test func evaluationConfigurationIsBoundedAndDoesNotSilentlyChangeSampleSet() throws {
        let defaults = try DictionaryQualityRun(environment: [:])
        #expect(defaults.model == "qwen2.5:7b" && defaults.rounds == 3 && defaults.samples.count == 22)
        let smoke = try DictionaryQualityRun(environment: ["DICTIONARY_QUALITY_MODEL": "qwen3:14b",
            "DICTIONARY_QUALITY_ROUNDS": "1", "DICTIONARY_QUALITY_SET": "context-smoke"])
        #expect(smoke.samples.count == 5 && smoke.rounds == 1)
        #expect(smoke.isInstalledLocally(in: ["qwen3:14b"]))
        #expect(!smoke.isInstalledLocally(in: ["qwen2.5:7b", "qwen3:14b-cloud"]))
        for value in ["0", "-1", "4", "99999", "", "bad"] {
            #expect(throws: DictionaryQualityRun.InvalidConfiguration.self) {
                try DictionaryQualityRun(environment: ["DICTIONARY_QUALITY_ROUNDS": value])
            }
        }
        #expect(throws: DictionaryQualityRun.InvalidConfiguration.self) {
            try DictionaryQualityRun(environment: ["DICTIONARY_QUALITY_SET": "contextual-word-typo"])
        }
        #expect(throws: DictionaryQualityRun.InvalidConfiguration.self) {
            try DictionaryQualityRun(environment: ["DICTIONARY_QUALITY_MODEL": ""])
        }
    }

    // Optional, local-only, sequential, no retries or cloud fallback. A successful
    // run means responses were recorded, NOT that dictionary quality passed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_QUALITY_LIVE"] == "1"),
          .timeLimit(.minutes(5)))
    func recordLocalQualityResponses() async throws {
        let run = try DictionaryQualityRun(environment: ProcessInfo.processInfo.environment)
        // Reuse the app's read-only listing, which excludes Ollama remote references.
        // A missing/nonlocal model stops here; never pull a model or use a cloud fallback.
        let installed = try await OllamaModelListClient().models()
        try #require(run.isInstalledLocally(in: installed), "Evaluation model must be installed locally")
        let provider = OllamaProvider(model: run.model)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let samples = run.samples
        let prompt = PromptBuilder.build(target: "", context: "", containingSentence: nil, targetLanguage: "简体中文")
        let digest = SHA256.hash(data: Data(prompt.system.utf8)).map { String(format: "%02x", $0) }.joined()
        print("QUALITY_META model=\(run.model) rounds=\(run.rounds) cases=\(samples.count) set=\(run.sampleSet.rawValue) promptSHA256=\(digest)")
        let ordinary = LocalDictionaryPrompt.build(target: "", matches: [], targetLanguage: "简体中文")
        let ordinaryDigest = SHA256.hash(data: Data(ordinary.system.utf8)).map { String(format: "%02x", $0) }.joined()
        print("QUALITY_META targetOnlyPromptSHA256=\(ordinaryDigest) reference=oewn-2025 maxSenses=24")
        let contextual = LocalContextPrompt.build(target: "", context: "", sentence: "", targetLanguage: "简体中文")
        let contextDigest = SHA256.hash(data: Data(contextual.system.utf8)).map { String(format: "%02x", $0) }.joined()
        let schemaData = try JSONSerialization.data(withJSONObject: LocalContextPrompt.responseFormat, options: [.sortedKeys])
        let schemaDigest = SHA256.hash(data: schemaData).map { String(format: "%02x", $0) }.joined()
        print("QUALITY_META expressionContextPromptSHA256=\(contextDigest) expressionTemperature=0 schemaSHA256=\(schemaDigest)")
        for round in 1...run.rounds {
            for sample in samples {
                try Task.checkCancellation()
                let request = try LookupRequest.manual(target: sample.target, context: sample.context)
                let started = ContinuousClock.now
                do {
                    let result = try await provider.translate(target: request.target, context: request.providerContext,
                        containingSentence: request.containingSentence, targetLanguage: "简体中文")
                    let json = String(decoding: try encoder.encode(result), as: UTF8.self)
                    print("QUALITY \(round) \(sample.id) \(json)")
                    print("QUALITY_TIME \(round) \(sample.id) \(started.duration(to: .now))")
                } catch TranslationError.unparseableJSON(let raw) {
                    // Keep malformed responses visible and finish other cases, without retrying this one.
                    let json = String(decoding: try encoder.encode(raw), as: UTF8.self)
                    print("QUALITY_ERROR \(round) \(sample.id) \(json)")
                    Issue.record("Invalid response for \(sample.id), round \(round)")
                }
            }
        }
    }
}
