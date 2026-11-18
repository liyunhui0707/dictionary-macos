import Foundation

struct Translation: Codable, Sendable {
    let meaningInContext: String
    let literalGloss: String?
    let partOfSpeech: String?
    let exampleTranslation: String?
    let alternatives: [String]?
    let textTranslation: TextTranslation?

    init(meaningInContext: String, literalGloss: String?, partOfSpeech: String?, exampleTranslation: String?,
         alternatives: [String]?, textTranslation: TextTranslation? = nil) {
        self.meaningInContext = meaningInContext; self.literalGloss = literalGloss; self.partOfSpeech = partOfSpeech
        self.exampleTranslation = exampleTranslation; self.alternatives = alternatives; self.textTranslation = textTranslation
    }

    init(textTranslation: TextTranslation) {
        self.init(meaningInContext: "", literalGloss: nil, partOfSpeech: nil, exampleTranslation: nil,
                  alternatives: nil, textTranslation: textTranslation)
    }

    /// A quoted JSON absence marker is not usable display text. Do not infer
    /// semantic correctness or mutate the original model response here.
    static func displayText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "null" ? nil : text
    }

    /// Display-only cleanup: retain the original answer for encoding/history.
    var additionalMeanings: (literal: String?, alternatives: [String]) {
        var seen: Set<String> = [meaningInContext.trimmingCharacters(in: .whitespacesAndNewlines)]
        func distinct(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.displayText(value) != nil, seen.insert(value).inserted else { return nil }
            return value
        }
        let literal = literalGloss.flatMap(distinct)
        return (literal, Array((alternatives ?? []).compactMap(distinct).prefix(3)))
    }
}

extension Translation {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Explicit null is an abstention, not malformed JSON. decodeNil still
        // throws for a missing required key; non-string values remain invalid.
        meaningInContext = try values.decodeNil(forKey: .meaningInContext)
            ? "" : values.decode(String.self, forKey: .meaningInContext)
        literalGloss = try values.decodeIfPresent(String.self, forKey: .literalGloss)
        partOfSpeech = try values.decodeIfPresent(String.self, forKey: .partOfSpeech)
        exampleTranslation = try values.decodeIfPresent(String.self, forKey: .exampleTranslation)
        alternatives = try values.decodeIfPresent([String].self, forKey: .alternatives)
        textTranslation = try values.decodeIfPresent(TextTranslation.self, forKey: .textTranslation)
    }
}

protocol TranslationProvider: Sendable {
    func translateText(_ text: String, targetLanguage: String) async throws -> TextTranslation
    func translate(
        target: String,
        context: String,
        containingSentence: String?,
        targetLanguage: String
    ) async throws -> Translation
}

extension TranslationProvider {
    func translateText(_ text: String, targetLanguage: String) async throws -> TextTranslation {
        throw TranslationError.unsupportedTask
    }

    func translate(_ request: LookupRequest, targetLanguage: String) async throws -> Translation {
        if request.task == .translation {
            return Translation(textTranslation: try await translateText(request.target, targetLanguage: targetLanguage))
        }
        return try await translate(target: request.target, context: request.providerContext,
                                   containingSentence: request.containingSentence, targetLanguage: targetLanguage)
    }
}

enum TranslationError: LocalizedError {
    case missingAPIKey(provider: String)
    case apiError(status: Int, body: String)
    case emptyResponse
    case unparseableJSON(rawOutput: String)
    case unsupportedTask

    var errorDescription: String? {
        switch self {
        case .unsupportedTask: return "当前服务尚不支持句段翻译，请选择 Ollama 或 DeepSeek。"
        case .missingAPIKey(let provider):
            return "\(provider) 尚未配置密钥，请检查服务配置后重试。"
        case .apiError(let status, _):
            return "服务请求失败（HTTP \(status)），请检查服务配置后重试。"
        case .emptyResponse:
            return "模型未返回可用文字，可重试或更换服务。"
        case .unparseableJSON:
            return "服务返回的结果格式不完整，请重试或更换服务。"
        }
    }

    /// The raw model output, when available. Used by the popup to show the
    /// user *something* useful even when parsing failed.
    var rawOutput: String? {
        if case .unparseableJSON(let raw) = self { return raw }
        return nil
    }
}
