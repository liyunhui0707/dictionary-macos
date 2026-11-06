import Foundation
import Testing
@testable import DictionaryApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SelectionCaptureTests {
    @Test func anchoredUnavailableSentenceSurvivesNativeController() async throws {
        let provider=ControlledProvider()
        let active=LookupCoordinator(provider:provider)
        let captures=SelectionCaptureController(coordinator:active)
        captures.start(source:"Synthetic AX",isSourceCurrent:{true}) {
            CapturedContext(target:"bank",context:"We sat on the\nbank of the river.",containingSentence:nil,
                            capture:captureMetadata(start:14,end:18,reason:.sentenceUnavailable))
        }
        let call=await provider.waitForCall("bank")
        #expect(call.sentence == nil)
        #expect((try providerDocument(call.context)["selection"] as? [String:Any])?["start"] as? Int == 14)
        await captures.task?.value
        active.dismissSelection()
        await provider.succeed(call)
    }

    @Test func newerCaptureWaitsForCleanupAndDiscardsOldResult() async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let captures = SelectionCaptureController(coordinator: coordinator)
        let gate = CaptureGate()
        captures.start(source: "Notes", isSourceCurrent: { true }) { await gate.capture("old") }
        await gate.waitForStart("old")
        captures.start(source: "Notes", isSourceCurrent: { true }) { await gate.capture("new") }
        #expect(gate.started == ["old"])
        gate.finish("old")
        await gate.waitForStart("new")
        #expect(await provider.calls.isEmpty)
        gate.finish("new")
        await provider.waitForCall("new")
        await captures.task?.value
        #expect(await provider.calls.map(\.target) == ["new"])
        coordinator.dismissSelection()
        await provider.succeed("new")
    }

    @Test(arguments: [false, true])
    func dismissalOrHTTPInvalidatesPendingCapture(http: Bool) async throws {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let captures = SelectionCaptureController(coordinator: coordinator)
        let gate = CaptureGate()
        captures.start(source: "Notes", isSourceCurrent: { true }) { await gate.capture("old") }
        await gate.waitForStart("old")
        var operation: LookupOperation?
        if http { operation = coordinator.submit(try .manual(target: "http", context: ""), to: .selection) }
        else { coordinator.dismissSelection() }
        gate.finish("old")
        await captures.task?.value
        if http {
            await provider.waitForCall("http")
            await provider.succeed("http")
            #expect(await operation?.value.result?.request.target == "http")
        }
        #expect(await provider.calls.contains { $0.target == "old" } == false)
    }

    @Test func changedSourceIsNotTranslated() async {
        let provider = ControlledProvider()
        let coordinator = LookupCoordinator(provider: provider)
        let captures = SelectionCaptureController(coordinator: coordinator)
        let gate = CaptureGate()
        var sourceCurrent = true
        captures.start(source: "Notes", isSourceCurrent: { sourceCurrent }) { await gate.capture("old") }
        await gate.waitForStart("old")
        sourceCurrent = false
        gate.finish("old")
        await captures.task?.value
        #expect(await provider.calls.isEmpty)
    }
}

@MainActor
private final class CaptureGate {
    var started: [String] = []
    private var pending: [String: CheckedContinuation<CapturedContext, Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    func capture(_ target: String) async -> CapturedContext {
        await withCheckedContinuation {
            pending[target] = $0
            started.append(target)
            waiters.removeValue(forKey: target)?.resume()
        }
    }
    func waitForStart(_ target: String) async {
        if started.contains(target) { return }
        await withCheckedContinuation { waiters[target] = $0 }
    }
    func finish(_ target: String) {
        pending.removeValue(forKey: target)?.resume(returning: CapturedContext(target: target, context: target, containingSentence: nil))
    }
}
