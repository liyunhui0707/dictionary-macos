import Foundation
import Combine

@MainActor
final class ManualLookupState: ObservableObject {
    @Published var target = ""
    @Published var context = ""
    @Published private(set) var validationMessage: String?
    let coordinator: LookupCoordinator

    init(coordinator: LookupCoordinator) { self.coordinator = coordinator }
    var canSubmit: Bool { !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    func submit() -> LookupOperation? {
        do {
            let request = try LookupRequest.manual(target: target, context: context)
            validationMessage = nil
            return coordinator.submit(request, to: .manual)
        } catch {
            validationMessage = error.localizedDescription
            return nil
        }
    }

    func cancel() { coordinator.cancel(.manual) }
    func close() { coordinator.closeManual() }
}
