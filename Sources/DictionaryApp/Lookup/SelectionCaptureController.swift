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
    private let allowAutomaticScreenContext: () -> Bool
    private var pending: Attempt?
    private(set) var task: Task<Void, Never>?

    init(coordinator: LookupCoordinator, diagnostics: QADiagnostics? = nil,
         allowAutomaticScreenContext: @escaping () -> Bool = { false }) {
        self.coordinator = coordinator
        self.diagnostics = diagnostics
        self.allowAutomaticScreenContext = allowAutomaticScreenContext
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
                coordinator.failCapture(attempt.id, message: "来源窗口已变化，请重新选中文字后再试。", issue: .sourceChanged)
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
                    coordinator.failCapture(attempt.id, message: "来源窗口已变化，请重新选中文字后再试。", issue: .sourceChanged)
                    continue
                }
                var captureDetails = captured.diagnostics
                let automatic = allowAutomaticScreenContext() && captured.screenContextCanAutoUse
                if automatic, captured.capture?.method == .screenOCR { captureDetails.screenContext = .automaticallyUsed }
                captureDetails.includeQuality(captured.capture)
                diagnostics?.record(QAEvent(kind: .captureSucceeded, attemptID: attempt.id, details: captureDetails,
                                            targetLength: captured.target.utf16.count, contextLength: captured.context.utf16.count,
                                            sentenceLength: captured.containingSentence?.utf16.count,
                                            elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)))
                let base = try LookupRequest.captured(target: captured.target, context: captured.context,
                                                         sentence: captured.containingSentence, source: attempt.source, capture: captured.capture)
                let request = LookupRequest(target: base.target, context: base.context, containingSentence: base.containingSentence,
                    source: base.source, capture: base.capture, screenContextCanAutoUse: captured.screenContextCanAutoUse)
                coordinator.finishCapture(attempt.id, request: request, allowAutomaticScreenContext: automatic)
            } catch {
                guard coordinator.isCurrentCapture(attempt.id) else {
                    diagnostics?.record(QAEvent(kind: .staleCaptureDiscarded, attemptID: attempt.id)); continue
                }
                diagnostics?.record(QAEvent(kind: captureReturned ? .submissionRejected : .captureFailed,
                                            attemptID: attempt.id, details: (error as? CaptureFailure)?.details,
                                            elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)))
                coordinator.failCapture(attempt.id, message: error.localizedDescription, issue: SupportIssue.classify(error))
            }
        }
    }
}
