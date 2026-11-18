import Foundation

final class OllamaProvider: TranslationProvider {
    // Only this exact locally evaluated tag uses the optional reading profile.
    // Other quantizations, aliases and model families retain their accepted path.
    static let evaluatedReadingModel = "qwen3.5:9b-q4_K_M"
    private let model: String
    private let endpoint: URL
    private let keepAlive: String
    private let disableThinking: Bool
    private let dictionary: EnglishDictionary
    private let session: URLSession

    init(
        model: String = "qwen2.5:7b",
        host: String = "http://localhost:11434",
        keepAlive: String = "30m",
        disableThinking: Bool = false,
        dictionary: EnglishDictionary = .shared,
        session: URLSession = .shared
    ) {
        self.model = model
        self.endpoint = URL(string: "\(host)/api/chat")!
        self.keepAlive = keepAlive
        self.disableThinking = disableThinking || model == Self.evaluatedReadingModel
        self.dictionary = dictionary
        self.session = session
    }

    private func usesContextPrompt(target: String, context: String, sentence: String?) -> Bool {
        LocalContextPrompt.applies(target: target, context: context, sentence: sentence,
            scope: model == Self.evaluatedReadingModel ? .evaluatedReading : .expressions)
    }

    func preparePrompt(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> PromptParts {
        try Task.checkCancellation()
        if let sentence = containingSentence, usesContextPrompt(target: target, context: context, sentence: sentence) {
            return LocalContextPrompt.build(target: target, context: context, sentence: sentence, targetLanguage: targetLanguage)
        }
        if LocalDictionaryPrompt.applies(target: target, context: context, sentence: containingSentence) {
            // A missing/corrupt optional dictionary must not prevent an AI lookup.
            let matches = try? await dictionary.lookupEntries(target)
            try Task.checkCancellation()
            if let matches, !matches.isEmpty {
                return LocalDictionaryPrompt.build(target: target, matches: matches, targetLanguage: targetLanguage)
            }
        }
        return PromptBuilder.build(target: target, context: context, containingSentence: containingSentence, targetLanguage: targetLanguage)
    }

    func translateText(_ text: String, targetLanguage: String) async throws -> TextTranslation {
        let result = try await perform(target: text, context: "", containingSentence: nil, targetLanguage: targetLanguage, textTask: true)
        guard let translated = result.textTranslation else { throw TranslationError.emptyResponse }
        return translated
    }

    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> Translation {
        try await perform(target: target, context: context, containingSentence: containingSentence, targetLanguage: targetLanguage, textTask: false)
    }

    private func perform(
        target: String,
        context: String,
        containingSentence: String?,
        targetLanguage: String, textTask: Bool
    ) async throws -> Translation {
        let prompt = textTask ? TextTranslationPrompt.build(text: target, language: targetLanguage) : try await preparePrompt(
            target: target,
            context: context,
            containingSentence: containingSentence,
            targetLanguage: targetLanguage
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        // Keep existing generation settings unless the contextual route supplies
        // its compared response schema and temperature.
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "keep_alive": keepAlive,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.userInstruction]
            ]
        ]
        if textTask {
            body["options"] = ["temperature": 0, "num_predict": 4096]
        } else if usesContextPrompt(target: target, context: context, sentence: containingSentence) {
            body["format"] = LocalContextPrompt.responseFormat
            body["options"] = ["temperature": 0]
        }
        if disableThinking { body["think"] = false }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw (error as? URLError)?.code == .timedOut ? OllamaLookupError.timedOut : OllamaLookupError.unavailable
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaLookupError.rejected(status)
        }

        let envelope: OllamaChatResponse
        do { envelope = try JSONDecoder().decode(OllamaChatResponse.self, from: data) }
        catch { throw OllamaLookupError.invalidResponse }
        let rawContent = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawContent.isEmpty else { throw TranslationError.emptyResponse }

        if textTask { return Translation(textTranslation: try TextTranslation.decode(rawContent)) }
        let cleaned = JSONExtractor.extract(rawContent)
        guard let jsonData = cleaned.data(using: .utf8) else {
            throw TranslationError.unparseableJSON(rawOutput: rawContent)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Translation.self, from: jsonData)
        } catch {
            throw TranslationError.unparseableJSON(rawOutput: rawContent)
        }
    }
}

enum OllamaLookupError: LocalizedError {
    case unavailable, timedOut, rejected(Int), invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "无法连接 Ollama。请打开 Ollama，再到“开始使用”检查本地服务与模型后重试；无需调整选词权限。"
        case .timedOut:
            return "Ollama 查询超时。模型加载或生成可能较慢，请检查本地服务状态后重试；未自动重复查询。"
        case .rejected(404):
            return "Ollama 未找到当前模型或查询接口（404）。请在本地模型设置检查已安装模型与服务地址；保存模型后需重新打开 Dictionary。"
        case .rejected(let status):
            return "Ollama 拒绝本次查询（\(status)）。请检查服务状态与当前模型后重试；未自动重复查询。"
        case .invalidResponse:
            return "Ollama 已响应，但响应格式无效。请检查服务地址与版本后重试；模型选择未改变。"
        }
    }
}

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    let message: Message
}
