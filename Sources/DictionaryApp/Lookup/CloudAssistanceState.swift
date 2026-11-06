import Foundation
import Combine

/// Separate, opt-in work. Never publishes into the original lookup channel or its HTTP outcome.
@MainActor
final class CloudAssistanceState: ObservableObject {
    enum AnswerSource { case original, cloud }
    @Published private(set) var selectedSource: AnswerSource = .original

    struct Offer {
        let id = UUID()
        let request: LookupRequest
    }
    @Published private(set) var offer: Offer?
    @Published private(set) var phase: LookupPhase = .idle
    @Published private(set) var isConfigured: Bool
    private var provider: TranslationProvider?
    private let language: String
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(provider: TranslationProvider?, language: String = "简体中文") {
        self.provider = provider
        self.language = language
        isConfigured = provider != nil
    }

    func prepare(_ request: LookupRequest?) {
        invalidate()
        selectedSource = .original
        phase = .idle
        offer = request.flatMap { $0.target.isEmpty ? nil : Offer(request: $0) }
    }

    func configure(provider: TranslationProvider?) {
        self.provider = provider
        isConfigured = provider != nil
        // Invalidates in-flight work and old buttons, but keeps the current input available.
        prepare(offer?.request)
    }

    /// One click per offer. A stale button cannot authorize sending a newer selection.
    @discardableResult
    func ask(offerID: UUID) -> Task<Void, Never>? {
        guard let provider, let offer, offer.id == offerID, case .idle = phase else { return nil }
        let request = offer.request, generation = self.generation, language = self.language
        selectedSource = .cloud
        phase = .loading(request)
        let operation = Task { [weak self] in
            let outcome: LookupOutcome
            do {
                try Task.checkCancellation()
                let translation = try await provider.translate(target: request.target, context: request.providerContext,
                    containingSentence: request.containingSentence, targetLanguage: language)
                outcome = .success(LookupResult(request: request, translation: translation))
            } catch {
                // Never surface arbitrary transport/provider bodies or credentials.
                outcome = .failure((error as? CloudAssistanceError)?.localizedDescription ??
                    "Cloud assistance failed. Your original answer is unchanged.", rawOutput: nil)
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.task = nil
            if outcome.result == nil { self.selectedSource = .original }
            self.phase = .finished(request, outcome)
        }
        task = operation
        return operation
    }

    func cancel() {
        guard case .loading(let request, _) = phase else { return }
        invalidate()
        selectedSource = .original
        phase = .finished(request, .cancelled)
    }

    func selectSource(_ source: AnswerSource) {
        guard source == .original || phase.isLoading || phase.result != nil else { return }
        selectedSource = source
    }

    func showsCloudAnswer(for original: LookupPhase) -> Bool {
        guard selectedSource == .cloud, let result = phase.result,
              case .finished(let request, let outcome) = original, !outcome.isCancelled else { return false }
        // Only display the corresponding snapshot; a new/loading request cannot inherit this answer.
        return request.target == result.request.target && request.providerContext == result.request.providerContext &&
            request.containingSentence == result.request.containingSentence
    }

    func displayedPhase(for original: LookupPhase) -> LookupPhase {
        showsCloudAnswer(for: original) ? phase : original
    }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
