import Foundation

protocol OllamaModelListing: Sendable {
    func models() async throws -> [String]
}

enum OllamaServiceError: Error { case unreachable, timedOut, invalidResponse }

/// Explicit, read-only service check. Never loads a model or submits translation text.
struct OllamaModelListClient: OllamaModelListing {
    var configuration: URLSessionConfiguration = .ephemeral

    func models() async throws -> [String] {
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: LocalModelRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else {
                throw OllamaServiceError.invalidResponse
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let entries = try decoder.decode(ModelList.self, from: data).models
            // /api/tags can also list remote references. Never offer them as local choices.
            let names = entries.filter { ($0.remoteHost ?? "").isEmpty && ($0.remoteModel ?? "").isEmpty }.map(\.name)
            guard names.allSatisfy(LocalModelConfiguration.validModel) else { throw OllamaServiceError.invalidResponse }
            return Array(Set(names)).sorted()
        } catch is CancellationError { throw CancellationError() }
        catch let error as OllamaServiceError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? OllamaServiceError.timedOut : OllamaServiceError.unreachable
        } catch { throw OllamaServiceError.invalidResponse }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let name: String
            let remoteHost: String?
            let remoteModel: String?
        }
        let models: [Model]
    }
}

/// A local status check must not follow redirects to another service.
final class LocalModelRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
