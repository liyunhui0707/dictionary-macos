import Foundation
import Testing
@testable import DictionaryApp

@MainActor
struct AppReadinessTests {
    @Test func diagnosticRefreshTracksPermissionChangesWithoutLoggingAppPathsOrExtraProbes() throws {
        var trusted = false
        var probes = 0
        var settingsOpened = 0
        let diagnostics = QADiagnostics()
        let readiness = AppReadiness(buildID: nil,
            appURL: URL(fileURLWithPath: "/Synthetic/PRIVATE_APP_PATH.app"),
            checkPermission: { probes += 1; return trusted },
            openPermissionSettings: { settingsOpened += 1; return true }, revealApp: { _ in },
            diagnostics: diagnostics)
        #expect(probes == 0 && diagnostics.events.isEmpty)
        readiness.refresh()
        trusted = true
        readiness.refresh()
        trusted = false
        readiness.refresh()
        #expect(probes == 3 && settingsOpened == 0)
        #expect(readiness.permission == .required)
        #expect(diagnostics.events.map(\.kind) == [.accessibilityChecked, .accessibilityChecked, .accessibilityChecked])
        #expect(diagnostics.events.map(\.trusted) == [false, true, false])
        #expect(!String(decoding: try diagnostics.encodedEvents(), as: UTF8.self).contains("PRIVATE_APP_PATH"))
    }

    @Test func constructionDoesNotProbeAndRefreshReflectsExactProcess() {
        var trusted = false
        var probes = 0
        let readiness = AppReadiness(buildID: "synthetic-build", appURL: URL(fileURLWithPath: "/tmp/Synthetic.app"),
            checkPermission: { probes += 1; return trusted }, openPermissionSettings: { true }, revealApp: { _ in })
        #expect(readiness.permission == .unchecked)
        #expect(probes == 0)
        readiness.refresh()
        #expect(readiness.permission == .required)
        trusted = true
        readiness.refresh()
        #expect(readiness.permission == .granted)
        trusted = false
        readiness.refresh()
        #expect(readiness.permission == .required)
        #expect(probes == 3)
    }

    @Test func settingsActionDoesNotClaimPermissionAndRevealUsesRunningBundle() {
        var opened = 0
        var revealed: URL?
        let url = URL(fileURLWithPath: "/tmp/Exact.app")
        let readiness = AppReadiness(buildID: nil, appURL: url, checkPermission: { false },
            openPermissionSettings: { opened += 1; return false }, revealApp: { revealed = $0 })
        readiness.openSettings()
        #expect(opened == 1)
        #expect(readiness.permission != .granted)
        #expect(readiness.settingsOpenFailed)
        #expect(readiness.buildLabel == "开发构建（无构建标识）")
        readiness.reveal()
        #expect(revealed == url)
    }

    @Test func openingSettingsSuccessfullyStillRequiresAnActualPermissionCheck() {
        let readiness = AppReadiness(buildID: "synthetic-build", appURL: URL(fileURLWithPath: "/tmp/Synthetic.app"),
            checkPermission: { false }, openPermissionSettings: { true }, revealApp: { _ in })
        readiness.refresh()
        readiness.openSettings()
        #expect(!readiness.settingsOpenFailed)
        #expect(readiness.permission == .required)
        #expect(readiness.buildLabel == "试用构建 · synthetic-build")
    }
}
