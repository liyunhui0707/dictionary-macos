import AppKit
import Combine

struct QABuildIdentity: Decodable {
    let buildID: String
    let sourceFingerprint: String

    static var current: QABuildIdentity? {
        guard let url = Bundle.main.url(forResource: "qa-build", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum QAEventKind: String, Codable {
    case processStarted, accessibilityChecked, hotkeyRegistration
    case captureStarted, captureSucceeded, captureFailed, staleCaptureDiscarded, sourceChanged
    case submissionRejected, lookupSubmitted, providerSucceeded, providerFailed, lookupCancelled, lookupSuperseded
    case popupPresented, popupNotVisible, popupDismissed
}

/// An allowlist, deliberately incapable of accepting error descriptions or text payloads.
struct QAEvent: Codable {
    let kind: QAEventKind
    var attemptID: UUID? = nil
    var sourcePID: Int32? = nil
    var sourceBundleID: String? = nil
    var frontmostPID: Int32? = nil
    var details: CaptureDetails? = nil
    var targetLength: Int? = nil
    var contextLength: Int? = nil
    var sentenceLength: Int? = nil
    var elapsedMilliseconds: Int? = nil
    var trusted: Bool? = nil
    var statusCode: Int32? = nil
    var visible: Bool? = nil
    var buildID: String? = nil
    var runID: String? = nil
    var processID = ProcessInfo.processInfo.processIdentifier
    var timestamp = Date()
}

/// QA opt-in only. Disk failures are visible in the QA menu, never lookup failures.
@MainActor
final class QADiagnostics {
    private(set) var events: [QAEvent] = []
    private(set) var latestAttempt: UUID?
    private(set) var writeFailed = false
    private(set) var limitReached = false
    let logURL: URL?
    private let buildID: String?
    private let runID: String?
    private var handle: FileHandle?
    private var observation: AnyCancellable?
    private var knownAttempts: Set<UUID> = []
    private var observedLookup: UUID?
    private var terminal: Set<UUID> = []
    private var writtenCount = 0

    init(logURL: URL? = nil, buildID: String? = nil, runID: String? = nil) {
        self.logURL = logURL; self.buildID = buildID; self.runID = runID
        if let logURL {
            do {
                try Data().write(to: logURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
                handle = try FileHandle(forWritingTo: logURL)
            } catch { writeFailed = true }
        }
    }

    static func forCurrentProcess() -> QADiagnostics? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DICTIONARY_QA_LOG"], !path.isEmpty else { return nil }
        return QADiagnostics(logURL: URL(fileURLWithPath: path), buildID: QABuildIdentity.current?.buildID,
                             runID: env["DICTIONARY_QA_RUN_ID"])
    }

    func record(_ event: QAEvent) {
        guard writtenCount < 10_000 else { limitReached = true; return }
        var event = event; event.buildID = buildID; event.runID = runID
        events.append(event); writtenCount += 1
        if events.count > 2_000 { events.removeFirst() }
        guard let handle else { return }
        do {
            var data = try JSONEncoder().encode(event); data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch { writeFailed = true }
    }

    func encodedEvents() throws -> Data { try JSONEncoder().encode(events) }

    func begin(_ intent: UUID, sourcePID: Int32?, sourceBundleID: String?) {
        if let old = observedLookup { finish(old, .lookupSuperseded) }
        latestAttempt = intent
        knownAttempts.insert(intent)
        record(QAEvent(kind: .captureStarted, attemptID: intent, sourcePID: sourcePID, sourceBundleID: sourceBundleID))
    }

    func observe(_ coordinator: LookupCoordinator) {
        guard observation == nil else { return }
        observation = coordinator.$selection.sink { [weak self, weak coordinator] phase in
            guard let self, let coordinator else { return }
            switch phase {
            case .loading:
                let intent = coordinator.selectionIntent
                if let old = self.observedLookup, old != intent { self.finish(old, .lookupSuperseded) }
                guard self.knownAttempts.contains(intent) else { self.observedLookup = nil; return }
                self.observedLookup = intent
                self.record(QAEvent(kind: .lookupSubmitted, attemptID: intent))
            case .finished(_, let outcome):
                guard let intent = self.observedLookup else { return }
                if outcome.isCancelled { self.finish(intent, .lookupCancelled) }
                else if intent == coordinator.selectionIntent {
                    self.finish(intent, outcome.result == nil ? .providerFailed : .providerSucceeded)
                }
            case .idle:
                if let intent = self.observedLookup { self.finish(intent, .lookupCancelled) }
            }
        }
    }

    private func finish(_ intent: UUID, _ kind: QAEventKind) {
        guard !terminal.contains(intent) else { return }
        terminal.insert(intent)
        record(QAEvent(kind: kind, attemptID: intent))
    }

    func presentation(intent: UUID, visible: Bool, expectedVisible: Bool, frontmostPID: Int32?) {
        guard knownAttempts.contains(intent) else { return }
        let kind: QAEventKind = expectedVisible ? (visible ? .popupPresented : .popupNotVisible) : .popupDismissed
        record(QAEvent(kind: kind, attemptID: intent, frontmostPID: frontmostPID, visible: visible))
    }
}
