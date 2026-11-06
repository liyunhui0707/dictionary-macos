import Foundation

final class OllamaProvider: TranslationProvider {
    private let model: String
    private let endpoint: URL
    private let keepAlive: String
    private let dictionary: EnglishDictionary
    private let session: URLSession

    init(
        model: String = "qwen2.5:7b",
        host: String = "http://localhost:11434",
        keepAlive: String = "30m",
        dictionary: EnglishDictionary = .shared,
        session: URLSession = .shared
    ) {
        self.model = model
        self.endpoint = URL(string: "\(host)/api/chat")!
        self.keepAlive = keepAlive
        self.dictionary = dictionary
        self.session = session
    }

    func preparePrompt(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> PromptParts {
        try Task.checkCancellation()
        if let sentence = containingSentence, LocalContextPrompt.applies(target: target, context: context, sentence: sentence) {
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

    func translate(
        target: String,
        context: String,
        containingSentence: String?,
        targetLanguage: String
    ) async throws -> Translation {
        let prompt = try await preparePrompt(
            target: target,
            context: context,
            containingSentence: containingSentence,
            targetLanguage: targetLanguage
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        // Keep existing JSON generation settings unless the expression route below
        // supplies its evaluated response schema and temperature.
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
        if LocalContextPrompt.applies(target: target, context: context, sentence: containingSentence) {
            body["format"] = LocalContextPrompt.responseFormat
            body["options"] = ["temperature": 0]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranslationError.apiError(
                status: -1,
                body: "Could not reach Ollama at \(endpoint.absoluteString). Is `ollama serve` running? (\(error.localizedDescription))"
            )
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw TranslationError.apiError(status: status, body: raw)
        }

        let envelope = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let rawContent = envelope.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawContent.isEmpty else { throw TranslationError.emptyResponse }

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

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    let message: Message
}
