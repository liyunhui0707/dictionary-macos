import Foundation

/// Authenticates and validates before admitting a request to the shared selection channel.
/// Presentation belongs to the coordinator; the handler only returns the HTTP outcome.
@MainActor
final class TranslateHandler {
    private let tokenStore: TokenStore
    private let coordinator: LookupCoordinator

    init(tokenStore: TokenStore, coordinator: LookupCoordinator) {
        self.tokenStore = tokenStore
        self.coordinator = coordinator
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // 1. Method + path check.
        guard request.method == "POST", request.path == "/v1/translate" else {
            return .empty(status: 404)
        }

        // 2. Auth.
        guard let authHeader = request.header("Authorization") else {
            return .json(status: 401, ["error": "missing Authorization header"])
        }
        let prefix = "Bearer "
        guard authHeader.hasPrefix(prefix) else {
            return .json(status: 401, ["error": "Authorization must be Bearer"])
        }
        let provided = String(authHeader.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let expected = tokenStore.token
        guard !provided.isEmpty, provided == expected else {
            return .json(status: 401, ["error": "invalid token"])
        }

        // 3. Decode body.
        let payload: TranslatePayload
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            payload = try decoder.decode(TranslatePayload.self, from: request.body)
        } catch {
            return .json(status: 400, ["error": "malformed JSON body: \(error.localizedDescription)"])
        }

        // 4. Validate.
        let target = payload.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return .json(status: 400, ["error": "target is required"])
        }
        // Authentication and validation must finish before selection supersession.
        let input: LookupRequest
        do {
            input = try .captured(target: payload.target, context: payload.context, sentence: payload.containingSentence,
                                  source: payload.sourceApp ?? "Extension", capture: payload.capture)
        } catch {
            return .json(status: 400, ["error": error.localizedDescription])
        }
        let outcome = await coordinator.submit(input, to: .selection).value
        let translation: Translation
        switch outcome {
        case .success(let result): translation = result.translation
        case .cancelled: return .empty(status: 204)
        case .failure(let message, _): return .json(status: 503, ["error": message])
        }

        // 6. Encode.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            let data = try encoder.encode(translation)
            return .json(status: 200, raw: data)
        } catch {
            return .json(status: 500, ["error": "could not encode translation: \(error.localizedDescription)"])
        }
    }
}

private struct TranslatePayload: Decodable {
    let target: String
    let context: String?
    let containingSentence: String?
    let sourceApp: String?
    let capture: SelectionLocation?

    private enum CodingKeys: String, CodingKey { case target, context, containingSentence, sourceApp, capture }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        containingSentence = try c.decodeIfPresent(String.self, forKey: .containingSentence)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        if c.contains(.capture), !(try c.decodeNil(forKey: .capture)) {
            capture = (try? c.decode(SelectionLocation.self, forKey: .capture)) ??
                .init(reliability: .legacyUnverified, method: .clipboard, reason: .metadataInvalid)
        } else { capture = nil }
    }
}
