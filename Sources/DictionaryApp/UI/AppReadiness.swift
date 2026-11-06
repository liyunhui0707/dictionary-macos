import AppKit
import ApplicationServices
import Combine

/// Read-only status of this running process. No permission requests, service calls or secrets.
@MainActor
final class AppReadiness: ObservableObject {
    enum Permission { case unchecked, required, granted }
    @Published private(set) var permission: Permission = .unchecked
    @Published private(set) var settingsOpenFailed = false
    let buildID: String?
    let appURL: URL
    private let checkPermission: () -> Bool
    private let openPermissionSettings: () -> Bool
    private let revealApp: (URL) -> Void

    init(buildID: String?, appURL: URL, checkPermission: @escaping () -> Bool,
         openPermissionSettings: @escaping () -> Bool, revealApp: @escaping (URL) -> Void) {
        self.buildID = buildID; self.appURL = appURL
        self.checkPermission = checkPermission
        self.openPermissionSettings = openPermissionSettings; self.revealApp = revealApp
    }

    static func live() -> AppReadiness {
        AppReadiness(buildID: QABuildIdentity.current?.buildID, appURL: Bundle.main.bundleURL,
            checkPermission: { AXIsProcessTrusted() }, openPermissionSettings: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }, revealApp: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    }

    // Default for isolated views/tests: never probes the host's actual permissions.
    static func preview() -> AppReadiness {
        AppReadiness(buildID: nil, appURL: URL(fileURLWithPath: "/Synthetic/Dictionary.app"),
            checkPermission: { false }, openPermissionSettings: { false }, revealApp: { _ in })
    }

    var buildLabel: String { buildID.map { "试用构建 · \($0)" } ?? "开发构建（无构建标识）" }
    var permissionLabel: String {
        switch permission {
        case .unchecked: "选词权限尚未检查"
        case .required: "选词需要授权"
        case .granted: "选词权限已开启"
        }
    }
    func refresh() { permission = checkPermission() ? .granted : .required }
    func openSettings() { settingsOpenFailed = !openPermissionSettings() }
    func reveal() { revealApp(appURL) }
}
