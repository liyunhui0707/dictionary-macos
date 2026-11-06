import Foundation

/// Explicit cloud assistance only; no automatic fallback, retries, tools or configuration import.
final class DeepSeekProvider: TranslationProvider, @unchecked Sendable {
    private let apiKey: String
    private let configuration: URLSessionConfiguration

    init(apiKey: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiKey = apiKey
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    static func configured(environment: [String: String]) -> DeepSeekProvider? {
        guard let key = environment["DICTIONARY_CLOUD_API_KEY"], validKey(key) else { return nil }
        return DeepSeekProvider(apiKey: key)
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 4096 && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> Translation {
        guard Self.validKey(apiKey) else { throw CloudAssistanceError.notConfigured }
        let prompt = PromptBuilder.build(target: target, context: context, containingSentence: containingSentence,
                                         targetLanguage: targetLanguage)
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "deepseek-flash", "max_tokens": 1024, "stream": false,
            "thinking": ["type": "disabled"], "system": prompt.system,
            "messages": [["role": "user", "content": prompt.userInstruction]]
        ])
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        request.timeoutInterval = 30
        let session = URLSession(configuration: config, delegate: CloudRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CloudAssistanceError.network }
            guard response.statusCode == 200 else { throw CloudAssistanceError.http(response.statusCode) }
            guard data.count <= 131_072 else { throw CloudAssistanceError.invalidResponse }
            let envelope = try JSONDecoder().decode(CloudMessage.self, from: data)
            guard envelope.stopReason == "end_turn", envelope.content.count == 1,
                  envelope.content[0].type == "text", let text = envelope.content[0].text else {
                throw CloudAssistanceError.invalidResponse
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(Translation.self, from: Data(JSONExtractor.extract(text).utf8))
            guard !result.meaningInContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudAssistanceError.noMeaning
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as CloudAssistanceError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? CloudAssistanceError.timeout : CloudAssistanceError.network
        } catch { throw CloudAssistanceError.invalidResponse }
    }
}

/// Refuse redirects even to the same host: no second destination can receive this credential/body.
final class CloudRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct CloudMessage: Decodable {
    struct Block: Decodable { let type: String; let text: String? }
    let content: [Block]
    let stopReason: String
    enum CodingKeys: String, CodingKey { case content; case stopReason = "stop_reason" }
}

enum CloudAssistanceError: LocalizedError {
    case notConfigured, credentialUnavailable, network, timeout, invalidResponse, noMeaning, http(Int)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud assistance is not configured."
        case .credentialUnavailable: return "Saved DeepSeek key is unavailable. Open Dictionary Settings to enable or replace it. Your original answer is unchanged."
        case .network: return "Could not reach DeepSeek. Your original answer is unchanged."
        case .timeout: return "DeepSeek did not respond within 30 seconds. Your original answer is unchanged."
        case .invalidResponse: return "DeepSeek returned an incomplete or invalid answer. Your original answer is unchanged."
        case .noMeaning: return "DeepSeek did not provide a further meaning. Your original answer is unchanged."
        case .http(let status): return "DeepSeek request failed (HTTP \(status)). Your original answer is unchanged."
        }
    }
}
