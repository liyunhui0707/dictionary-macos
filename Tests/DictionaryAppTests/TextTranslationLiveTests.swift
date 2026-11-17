import Foundation
import Testing
@testable import DictionaryApp

/// Opt-in, fixed synthetic data and one model per invocation. Never reads credentials.
/// Schema/transport results do not constitute semantic acceptance; review every saved answer.
@MainActor
struct TextTranslationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_TEXT_QUALITY_OUTPUT"] != nil), .timeLimit(.minutes(16)))
    func frozenSyntheticTranslationBatch() async throws {
        struct Sample: Decodable { let id: String; let source: String; let review: String }
        struct Record: Codable { let id: String; let source: String; let review: String; let translation: String?; let elapsedSeconds: Double; let transportPassed: Bool }
        let env = ProcessInfo.processInfo.environment
        let model = try #require(env["DICTIONARY_TEXT_QUALITY_MODEL"])
        try #require(["qwen2.5:7b", "qwen3.5:9b-q4_K_M"].contains(model))
        let output = URL(fileURLWithPath: try #require(env["DICTIONARY_TEXT_QUALITY_OUTPUT"]))
        try #require(output.lastPathComponent.hasPrefix("translation-quality-"))
        try #require(!FileManager.default.fileExists(atPath: output.path))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/text-translation-quality.json")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: fixture))
        try #require(samples.count == 12 && Set(samples.map(\.id)).count == 12)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 90; config.timeoutIntervalForRequest = 90
        let provider = OllamaProvider(model: model, session: URLSession(configuration: config))
        let deadline = Date().addingTimeInterval(15 * 60)
        var records: [Record] = []
        for sample in samples {
            guard Date().addingTimeInterval(90) < deadline else { break }
            let started = Date()
            let answer = try? await provider.translateText(sample.source, targetLanguage: "简体中文")
            records.append(Record(id: sample.id, source: sample.source, review: sample.review,
                translation: answer?.translatedText, elapsedSeconds: Date().timeIntervalSince(started), transportPassed: answer != nil))
            // Persist after each call; no retry and no private service error/output in test logs.
            try JSONEncoder().encode(records).write(to: output, options: .atomic)
            print("SYNTHETIC_TRANSLATION \(sample.id) response=\(answer != nil)")
        }
        #expect(records.count == 12 && records.allSatisfy(\.transportPassed))
    }
}
