import Foundation
import CryptoKit
import Security
import Testing
@testable import DictionaryApp

/// Synthetic-only opt-in evaluation. Normal tests never access the real Keychain or network.
struct CloudQualityEvaluationTests {
    static let samples: [DictionaryQualityCase] = [
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
        .init(id: "complete-sentence", target: "hard", context: "The rules sound simple, but they are hard to apply without practice.", rubric: "难的；adjective；句译包含前后两个分句及without practice"),
        .init(id: "validation-unknown-alone", target: "vqxtralen", context: "", rubric: "含义不明；词性和句译null；无编造备选"),
        .init(id: "validation-negation", target: "ready", context: "The food was ready, but nobody ate it because the guests had not arrived.", rubric: "准备好的；adjective；句译保留全部分句和两个否定"),
        .init(id: "verify-polysemy", target: "took", context: "The journey took three hours.", rubric: "花费/耗时；verb；句译保留三小时"),
        .init(id: "verify-locative", target: "there", context: "Please leave your bag there.", rubric: "那里；adverb；不能把所有there都当存在句"),
        .init(id: "word-liquid", target: "runs", context: "Cold water runs through the pipe.", rubric: "流动/流；verb；不是经营；保留冷水及管道"),
        .init(id: "holdout-seal-animal", target: "seal", context: "The seal swam back to the rocks.", rubric: "海豹；noun；保留游回岩石"),
        .init(id: "holdout-seal-close", target: "seal", context: "Please seal the envelope before mailing it.", rubric: "封好/密封；verb；不是海豹；保留寄出之前"),
        .init(id: "holdout-fine-penalty", target: "fine", context: "He paid a fine for parking here.", rubric: "罚款；noun；保留停车原因"),
        .init(id: "holdout-fine-well", target: "fine", context: "The machine works fine despite its age.", rubric: "正常/良好；adverb；保留虽然年旧"),
        .init(id: "holdout-bear-animal", target: "bear", context: "A bear crossed the trail at dawn.", rubric: "熊；noun；保留黎明与小路"),
        .init(id: "holdout-bear-endure", target: "bear", context: "I cannot bear the noise any longer.", rubric: "忍受；verb；保留不能与再也"),
        .init(id: "holdout-unknown", target: "zerniqava", context: "The box has the label zerniqava.", rubric: "含义未知；无编造词性或备选；句译保留原拼写"),
        .init(id: "holdout-dummy", target: "It", context: "It was raining when we left.", rubric: "天气表达形式主语；pronoun；不是它这个物体；保留我们离开时"),
    ]

    @Test func sampleIdentityAndNewPromptKeepUnknownsAndSourceStringsExplicit() throws {
        #expect(Self.samples.count == 24 && Set(Self.samples.map(\.id)).count == 24)
        #expect(Self.samples.suffix(8).allSatisfy { $0.id.hasPrefix("holdout-") })
        for sample in Self.samples {
            let request = try LookupRequest.manual(target: sample.target, context: sample.context)
            let prompt = CloudLookupPrompt.build(target: request.target, context: request.providerContext,
                sentence: request.containingSentence, language: "简体中文")
            #expect(prompt.userInstruction.contains(request.providerContext))
            #expect(!prompt.system.contains(sample.context.isEmpty ? "PRIVATE_SENTINEL" : sample.context))
            if sample.context.isEmpty { #expect(prompt.userInstruction.contains("SENTENCE: null")) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_CLOUD_QUALITY_LIVE"] == "1" ||
                     ProcessInfo.processInfo.environment["DICTIONARY_CLOUD_QUALITY_FINAL"] == "1"),
          .timeLimit(.minutes(10)))
    func recordApprovedCloudComparison() async throws {
        enum Stop: Error { case ledgerRequired, alreadyStarted, keyUnavailable, timeBudget }
        let environment = ProcessInfo.processInfo.environment
        let final = environment["DICTIONARY_CLOUD_QUALITY_FINAL"] == "1"
        let limit = final ? 24 : 48
        guard let path = environment["DICTIONARY_CLOUD_QUALITY_LEDGER"] else { throw Stop.ledgerRequired }
        let ledger = URL(fileURLWithPath: path).standardizedFileURL
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard ledger.path.hasPrefix(root.appendingPathComponent(".local/").path + "/") else { throw Stop.ledgerRequired }
        guard !FileManager.default.fileExists(atPath: path) else { throw Stop.alreadyStarted }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var calls = 0
        struct Entry: Codable {
            let purpose: String; let id: String; let answer: Translation?; let status: String; let seconds: Double
        }
        var entries: [Entry] = []
        func persist(_ status: String, initial: Bool = false) throws {
            struct Ledger: Encodable { let requests: Int; let limit: Int; let status: String; let entries: [Entry] }
            let data = try encoder.encode(Ledger(requests: calls, limit: limit, status: status, entries: entries))
            try data.write(to: ledger, options: initial ? .withoutOverwriting : .atomic)
        }
        try persist("started", initial: true)
        // Fail rather than trigger an unexpected credential-access dialog in a test process.
        let store = KeychainCloudCredentialStore(client: NonPromptingQualityKeychain())
        guard let key = try? await store.read(), DeepSeekProvider.validKey(key) else {
            try persist("credential-unavailable-no-requests")
            throw Stop.keyUnavailable
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        for purpose in (final ? [.lookup] : [DeepSeekProvider.Purpose.assistance, .lookup]) {
            let provider = DeepSeekProvider(apiKey: key, purpose: purpose)
            for sample in Self.samples {
                guard ContinuousClock.now.advanced(by: .seconds(30)) < deadline else {
                    try persist("time-budget-stop"); throw Stop.timeBudget
                }
                try Task.checkCancellation()
                guard calls < limit else { throw Stop.timeBudget }
                let request = try LookupRequest.manual(target: sample.target, context: sample.context)
                calls += 1; try persist("running") // reserve before a request; never retry
                let started = ContinuousClock.now
                do {
                    let answer = try await provider.translate(target: request.target, context: request.providerContext,
                        containingSentence: request.containingSentence, targetLanguage: "简体中文")
                    let elapsed = started.duration(to: .now).components
                    entries.append(.init(purpose: purpose.rawValue, id: sample.id, answer: answer,
                        status: "recorded-not-semantically-graded", seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
                } catch CloudAssistanceError.noMeaning {
                    entries.append(.init(purpose: purpose.rawValue, id: sample.id, answer: nil,
                        status: "assistance-abstention-fields-unavailable", seconds: 0))
                } catch {
                    try persist("transport-or-credential-error-stop")
                    throw error // provider errors are sanitized; no response/header/key logging
                }
                try persist("running")
                print("CLOUD_QUALITY_RESULT " + String(decoding: try encoder.encode(entries.last!), as: UTF8.self))
            }
        }
        try persist("recording-complete-semantic-review-required")
        print("CLOUD_QUALITY_NOTE recorded=\(entries.count) requests=\(calls); successful recording is not semantic acceptance")
    }
}

private struct NonPromptingQualityKeychain: CloudKeychainClient {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var query = query
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SystemCloudKeychainClient().copy(query)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
    func add(_ attributes: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
    func delete(_ query: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
}
