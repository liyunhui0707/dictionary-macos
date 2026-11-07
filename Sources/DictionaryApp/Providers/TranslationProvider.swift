import Foundation

struct Translation: Codable, Sendable {
    let meaningInContext: String
    let literalGloss: String?
    let partOfSpeech: String?
    let exampleTranslation: String?
    let alternatives: [String]?

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
    }
}

protocol TranslationProvider: Sendable {
    func translate(
        target: String,
        context: String,
        containingSentence: String?,
        targetLanguage: String
    ) async throws -> Translation
}

enum TranslationError: LocalizedError {
    case missingAPIKey(provider: String)
    case apiError(status: Int, body: String)
    case emptyResponse
    case unparseableJSON(rawOutput: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key not set. Export it in your shell and relaunch the app."
        case .apiError(let status, let body):
            return "API error \(status): \(body)"
        case .emptyResponse:
            return "Model returned no text."
        case .unparseableJSON(let raw):
            return "Could not parse JSON. Raw model output:\n\(raw)"
        }
    }

    /// The raw model output, when available. Used by the popup to show the
    /// user *something* useful even when parsing failed.
    var rawOutput: String? {
        if case .unparseableJSON(let raw) = self { return raw }
        return nil
    }
}
