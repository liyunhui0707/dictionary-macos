import Foundation

final class ClaudeProvider: TranslationProvider {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: String = "claude-haiku-4-5-20251001") {
        self.apiKey = apiKey
        self.model = model
    }

    func translate(
        target: String,
        context: String,
        containingSentence: String?,
        targetLanguage: String
    ) async throws -> Translation {
        guard !apiKey.isEmpty else {
            throw TranslationError.missingAPIKey(provider: "Anthropic")
        }

        let prompt = PromptBuilder.build(
            target: target,
            context: context,
            containingSentence: containingSentence,
            targetLanguage: targetLanguage
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Context block carries cache_control so repeated lookups in the
        // same paragraph hit the prompt cache.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": prompt.system,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "CONTEXT:\n\(context)",
                            "cache_control": ["type": "ephemeral"]
                        ],
                        [
                            "type": "text",
                            "text": prompt.userInstruction
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw TranslationError.apiError(status: status, body: raw)
        }

        let envelope = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            throw TranslationError.emptyResponse
        }

        let cleaned = JSONExtractor.extract(text)
        guard let jsonData = cleaned.data(using: .utf8) else {
            throw TranslationError.unparseableJSON(rawOutput: text)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Translation.self, from: jsonData)
        } catch {
            throw TranslationError.unparseableJSON(rawOutput: text)
        }
    }
}

private struct ClaudeMessageResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}
