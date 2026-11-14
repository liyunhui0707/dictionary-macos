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

    /// Preparing a sample is separate from submitting it, especially for paid providers.
    @discardableResult
    func prepareExample() -> Bool {
        guard target.isEmpty, context.isEmpty, !coordinator.manual.isLoading else {
            validationMessage = coordinator.manual.isLoading ? "正在查询，请完成或取消后再准备样例。" :
                "已保留现有输入。需要填入样例时，请先手动清空单词和语境。"
            return false
        }
        target = "bank"
        context = "They walked along the bank of the river."
        validationMessage = nil
        return true
    }

    func cancel() { coordinator.cancel(.manual) }
    func close() { coordinator.closeManual() }
}
