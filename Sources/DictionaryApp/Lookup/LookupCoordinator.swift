import Foundation
import Combine

enum LookupOutcome {
    case success(LookupResult)
    case failure(String, rawOutput: String?)
    case cancelled

    var result: LookupResult? { if case .success(let result) = self { return result }; return nil }
    var isCancelled: Bool { if case .cancelled = self { return true }; return false }
}

enum LookupPhase {
    case idle
    // UI-only monotonic timing, freshly created for every submission (even the same request).
    case loading(LookupRequest, startedAt: ContinuousClock.Instant = .now)
    case finished(LookupRequest, LookupOutcome)

    var isLoading: Bool { if case .loading = self { return true }; return false }
    var result: LookupResult? { if case .finished(_, let outcome) = self { return outcome.result }; return nil }
    var isCancelled: Bool { if case .finished(_, let outcome) = self { return outcome.isCancelled }; return false }
}

/// A caller's terminal result is independent of whether the provider cooperates with cancellation.
@MainActor
final class LookupOperation {
    let id = UUID()
    let request: LookupRequest
    private(set) var providerTask: Task<Void, Never>?
    private var outcome: LookupOutcome?
    private var waiters: [CheckedContinuation<LookupOutcome, Never>] = []

    init(request: LookupRequest) { self.request = request }

    var value: LookupOutcome {
        get async {
            if let outcome { return outcome }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    fileprivate func start(_ task: Task<Void, Never>) { providerTask = task }

    fileprivate func resolve(_ outcome: LookupOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: outcome) }
    }
}

@MainActor
final class LookupCoordinator: ObservableObject {
    @Published private(set) var manual: LookupPhase = .idle
    @Published private(set) var selection: LookupPhase = .idle
    @Published private(set) var lastManualResult: LookupResult?
    @Published private(set) var primaryLabel = "原始 AI"
    @Published private(set) var primaryIsCloud = false
    let manualCloud: CloudAssistanceState
    let selectionCloud: CloudAssistanceState
    private var provider: TranslationProvider
    private let targetLanguage: String
    private var active: [LookupChannel: LookupOperation] = [:]

    // Selection intent includes native capture, before there is a validated request.
    private(set) var selectionIntent = UUID()

    init(provider: TranslationProvider, targetLanguage: String = "简体中文", cloudProvider: TranslationProvider? = nil) {
        manualCloud = CloudAssistanceState(provider: cloudProvider, language: targetLanguage)
        selectionCloud = CloudAssistanceState(provider: cloudProvider, language: targetLanguage)
        self.provider = provider
        self.targetLanguage = targetLanguage
    }

    @discardableResult
    func submit(_ request: LookupRequest, to channel: LookupChannel) -> LookupOperation {
        if channel == .selection { selectionIntent = UUID() }
        return start(request, to: channel)
    }

    func configureCloudProvider(_ provider: TranslationProvider?) {
        manualCloud.configure(provider: provider)
        selectionCloud.configure(provider: provider)
    }

    func configurePrimaryProvider(_ provider: TranslationProvider, label: String, isCloud: Bool) {
        shutdown()
        lastManualResult = nil
        manual = .idle
        self.provider = provider
        primaryLabel = label
        primaryIsCloud = isCloud
    }

    @discardableResult
    private func start(_ request: LookupRequest, to channel: LookupChannel) -> LookupOperation {
        cloud(for: channel).prepare(nil)
        cancelActive(channel)
        let operation = LookupOperation(request: request)
        active[channel] = operation
        publish(.loading(request), to: channel)
        let provider = self.provider
        let language = targetLanguage
        operation.start(Task { [weak self, weak operation] in
            let outcome: LookupOutcome
            do {
                try Task.checkCancellation()
                let translation = try await provider.translate(target: request.target, context: request.providerContext,
                                                               containingSentence: request.containingSentence, targetLanguage: language)
                outcome = .success(LookupResult(request: request, translation: translation))
            } catch {
                outcome = .failure(error.localizedDescription, rawOutput: (error as? TranslationError)?.rawOutput)
            }
            guard let self, let operation, self.active[channel]?.id == operation.id else { return }
            self.active[channel] = nil
            if channel == .manual, let result = outcome.result { self.lastManualResult = result }
            self.cloud(for: channel).prepare(request)
            self.publish(.finished(request, outcome), to: channel)
            operation.resolve(outcome)
        })
        return operation
    }

    func cancel(_ channel: LookupChannel) {
        cloud(for: channel).prepare(nil)
        if channel == .selection { selectionIntent = UUID() }
        guard let operation = active[channel] else { return }
        cancelActive(channel)
        publish(.finished(operation.request, .cancelled), to: channel)
    }

    func dismissSelection() {
        cancel(.selection)
        selection = .idle
    }

    func closeManual() {
        cancel(.manual)
        if let result = lastManualResult { manual = .finished(result.request, .success(result)) }
        else { manual = .idle }
    }

    func shutdown() {
        cancel(.manual)
        dismissSelection()
    }

    func beginCapture() -> UUID {
        // Supersede work without dismissing an existing pinned panel while capturing.
        selectionCloud.prepare(nil)
        cancelActive(.selection)
        selectionIntent = UUID()
        return selectionIntent
    }

    func isCurrentCapture(_ intent: UUID) -> Bool { selectionIntent == intent }

    func finishCapture(_ intent: UUID, request: LookupRequest) {
        guard isCurrentCapture(intent) else { return }
        // The translation continues the capture's intent; it is not a new lookup.
        start(request, to: .selection)
    }

    func failCapture(_ intent: UUID, message: String) {
        guard isCurrentCapture(intent) else { return }
        let request = LookupRequest(target: "", context: nil, containingSentence: nil, source: "Selection")
        selection = .finished(request, .failure(message, rawOutput: nil))
    }

    private func cloud(for channel: LookupChannel) -> CloudAssistanceState {
        channel == .manual ? manualCloud : selectionCloud
    }

    private func cancelActive(_ channel: LookupChannel) {
        guard let operation = active.removeValue(forKey: channel) else { return }
        operation.resolve(.cancelled)
        operation.providerTask?.cancel()
    }

    private func publish(_ phase: LookupPhase, to channel: LookupChannel) {
        if channel == .manual { manual = phase } else { selection = phase }
    }
}
