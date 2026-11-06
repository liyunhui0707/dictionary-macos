import Foundation
import Testing
@testable import DictionaryApp

/// Deliberately ignores task cancellation so tests can complete obsolete work.
actor ControlledProvider: TranslationProvider {
    struct Call: Sendable {
        let id = UUID()
        let target: String
        let context: String
        let sentence: String?
        let language: String
    }
    private(set) var calls: [Call] = []
    private var pending: [UUID: CheckedContinuation<Translation, Error>] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func translate(target: String, context: String, containingSentence: String?, targetLanguage: String) async throws -> Translation {
        let call = Call(target: target, context: context, sentence: containingSentence, language: targetLanguage)
        calls.append(call)
        return try await withCheckedThrowingContinuation { continuation in
            pending[call.id] = continuation
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    @discardableResult
    func waitForCall(_ target: String, occurrence: Int = 1) async -> Call {
        precondition(occurrence > 0)
        while calls.filter({ $0.target == target }).count < occurrence {
            await withCheckedContinuation { waiters.append($0) }
        }
        return calls.filter { $0.target == target }[occurrence - 1]
    }

    func succeed(_ target: String, meaning: String = "译文") {
        guard let call = uniquePendingCall(target) else { return }
        succeed(call, meaning: meaning)
    }

    func succeed(_ call: Call, meaning: String = "译文", example: String? = nil) {
        pending.removeValue(forKey: call.id)?.resume(returning: Translation(
            meaningInContext: meaning, literalGloss: nil, partOfSpeech: nil,
            exampleTranslation: example, alternatives: nil))
    }

    func fail(_ target: String) {
        guard let call = uniquePendingCall(target) else { return }
        fail(call)
    }

    func fail(_ call: Call) {
        pending.removeValue(forKey: call.id)?.resume(throwing: TranslationError.emptyResponse)
    }

    private func uniquePendingCall(_ target: String) -> Call? {
        let matches = calls.filter { $0.target == target && pending[$0.id] != nil }
        guard matches.count == 1 else {
            Issue.record("Expected exactly one pending call for \(target); use a Call identity for repeated targets")
            return nil
        }
        return matches[0]
    }
}
