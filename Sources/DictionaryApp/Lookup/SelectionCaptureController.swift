import Foundation

/// Serializes capture (especially simulated copy) without canceling its cleanup.
@MainActor
final class SelectionCaptureController {
    private struct Attempt {
        let id: UUID
        let source: String
        let isSourceCurrent: () -> Bool
        let capture: () async throws -> CapturedContext
    }
    private let coordinator: LookupCoordinator
    private let diagnostics: QADiagnostics?
    private var pending: Attempt?
    private(set) var task: Task<Void, Never>?

    init(coordinator: LookupCoordinator, diagnostics: QADiagnostics? = nil) {
        self.coordinator = coordinator
        self.diagnostics = diagnostics
        diagnostics?.observe(coordinator)
    }

    func start(source: String, sourcePID: Int32? = nil, sourceBundleID: String? = nil,
               isSourceCurrent: @escaping () -> Bool,
               capture: @escaping () async throws -> CapturedContext) {
        pending = Attempt(id: coordinator.beginCapture(), source: source, isSourceCurrent: isSourceCurrent, capture: capture)
        if let pending { diagnostics?.begin(pending.id, sourcePID: sourcePID, sourceBundleID: sourceBundleID) }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { task = nil }
        while let attempt = pending {
            pending = nil
            guard coordinator.isCurrentCapture(attempt.id) else {
                diagnostics?.record(QAEvent(kind: .staleCaptureDiscarded, attemptID: attempt.id)); continue
            }
            guard attempt.isSourceCurrent() else {
                diagnostics?.record(QAEvent(kind: .sourceChanged, attemptID: attempt.id))
                coordinator.failCapture(attempt.id, message: "The source app changed. Select the text and try again.")
                continue
            }
            let started = ProcessInfo.processInfo.systemUptime
            var captureReturned = false
            do {
                let captured = try await attempt.capture()
                captureReturned = true
                guard coordinator.isCurrentCapture(attempt.id) else {
                    diagnostics?.record(QAEvent(kind: .staleCaptureDiscarded, attemptID: attempt.id)); continue
                }
                guard attempt.isSourceCurrent() else {
                    diagnostics?.record(QAEvent(kind: .sourceChanged, attemptID: attempt.id))
                    coordinator.failCapture(attempt.id, message: "The source app changed. Select the text and try again.")
                    continue
                }
                var captureDetails = captured.diagnostics
                captureDetails.includeQuality(captured.capture)
                diagnostics?.record(QAEvent(kind: .captureSucceeded, attemptID: attempt.id, details: captureDetails,
                                            targetLength: captured.target.utf16.count, contextLength: captured.context.utf16.count,
                                            sentenceLength: captured.containingSentence?.utf16.count,
                                            elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)))
                let request = try LookupRequest.captured(target: captured.target, context: captured.context,
                                                         sentence: captured.containingSentence, source: attempt.source, capture: captured.capture)
                coordinator.finishCapture(attempt.id, request: request)
            } catch {
                guard coordinator.isCurrentCapture(attempt.id) else {
                    diagnostics?.record(QAEvent(kind: .staleCaptureDiscarded, attemptID: attempt.id)); continue
                }
                diagnostics?.record(QAEvent(kind: captureReturned ? .submissionRejected : .captureFailed,
                                            attemptID: attempt.id, details: (error as? CaptureFailure)?.details,
                                            elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)))
                coordinator.failCapture(attempt.id, message: error.localizedDescription)
            }
        }
    }
}
