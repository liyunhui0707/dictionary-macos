import Combine
import Foundation

/// Session-only evidence. Configuration, exports and permission checks never
/// count as a successful lookup. No source text, credential or progress is saved.
@MainActor
final class FirstLookupProgress: ObservableObject {
    static let readingSampleURL = URL(string: "http://127.0.0.1:49152/reading-sample")!
    enum Check: Equatable {
        case notStarted, querying, responseReceived, needsContext, needsReview, noMeaning, failed, cancelled
    }

    @Published private(set) var manual: Check = .notStarted
    @Published private(set) var reading: Check = .notStarted
    @Published private(set) var readingConfirmed = false
    @Published private(set) var lastResponseAt: Date?
    private let now: () -> Date
    private var observations = Set<AnyCancellable>()

    init(coordinator: LookupCoordinator? = nil, now: @escaping () -> Date = { .now }) {
        self.now = now
        guard let coordinator else { return }
        coordinator.$manual.sink { [weak self] in self?.receive($0, channel: .manual) }.store(in: &observations)
        coordinator.$selection.sink { [weak self] in self?.receive($0, channel: .selection) }.store(in: &observations)
        coordinator.$configurationID.dropFirst().sink { [weak self] _ in self?.reset() }.store(in: &observations)
    }

    var canConfirmReading: Bool { manual == .responseReceived && reading == .responseReceived && !readingConfirmed }
    var isComplete: Bool { manual == .responseReceived && readingConfirmed }

    @discardableResult
    func confirmReading() -> Bool {
        guard canConfirmReading else { return false }
        readingConfirmed = true
        return true
    }

    func rejectReading() { readingConfirmed = false; reading = .needsReview }

    func resetReading() { reading = .notStarted; readingConfirmed = false }

    private func reset() {
        manual = .notStarted; reading = .notStarted; readingConfirmed = false; lastResponseAt = nil
    }

    private func receive(_ phase: LookupPhase, channel: LookupChannel) {
        let check: Check
        switch phase {
        case .idle, .reviewingContext: return // A preview is not a completed lookup.
        case .loading: check = .querying
        case .finished(_, .cancelled): check = .cancelled
        case .finished(_, .failure): check = .failed
        case .finished(let request, .success(let result)):
            // The manual window can restore its previous result when closed.
            // Only a response following an observed submission is new evidence.
            guard (channel == .manual ? manual : reading) == .querying else { return }
            lastResponseAt = now()
            if AIMeaningPresentation(target: request.target, answer: result.translation.meaningInContext).notice != nil {
                check = .noMeaning
            }
            else if LookupResultPresentation(request: request).sentence == nil ||
                        (channel == .selection && request.isManual) { check = .needsContext }
            else { check = .responseReceived }
        }
        // Every new attempt replaces its previous evidence, including identical
        // requests, errors and cancellation. A model response is not a human check.
        readingConfirmed = false
        if channel == .manual { manual = check } else { reading = check }
    }
}
