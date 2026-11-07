import Foundation

/// User-selected cloud lookup or explicit assistance; no automatic fallback or retries.
final class DeepSeekProvider: TranslationProvider, @unchecked Sendable {
    enum Purpose: String, Sendable { case assistance, lookup }
    private let apiKey: String
    private let configuration: URLSessionConfiguration
    private let purpose: Purpose

    init(apiKey: String, configuration: URLSessionConfiguration = .ephemeral, purpose: Purpose = .assistance) {
        self.apiKey = apiKey
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.purpose = purpose
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
        let prompt: PromptParts
        if purpose == .lookup, LocalDictionaryPrompt.applies(target: target, context: context, sentence: containingSentence) {
            prompt = LocalDictionaryPrompt.build(target: target, matches: [], targetLanguage: targetLanguage)
        } else if purpose == .lookup {
            prompt = CloudLookupPrompt.build(target: target, context: context, sentence: containingSentence, language: targetLanguage)
        } else {
            prompt = PromptBuilder.build(target: target, context: context, containingSentence: containingSentence, targetLanguage: targetLanguage)
        }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": "deepseek-flash", "max_tokens": 1024, "stream": false,
            "thinking": ["type": "disabled"], "system": prompt.system,
            "messages": [["role": "user", "content": prompt.userInstruction]]
        ]
        if purpose == .lookup { body["temperature"] = 0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
            guard purpose == .lookup || Translation.displayText(result.meaningInContext) != nil else {
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
        case .notConfigured: return "DeepSeek 尚未配置。请打开查词服务设置。"
        case .credentialUnavailable: return "无法读取已保存的 DeepSeek 密钥。请在设置中启用或重新保存密钥。"
        case .network: return "无法连接 DeepSeek。请检查网络后重试。"
        case .timeout: return "DeepSeek 在 30 秒内未响应，请稍后重试。"
        case .invalidResponse: return "DeepSeek 返回的内容不完整或格式无效，请重试。"
        case .noMeaning: return "DeepSeek 未提供进一步释义。"
        case .http(let status): return "DeepSeek 请求失败（HTTP \(status)）。请检查密钥、余额或服务状态。"
        }
    }
}
