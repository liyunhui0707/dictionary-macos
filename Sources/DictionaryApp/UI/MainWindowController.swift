import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let lookupState: ManualLookupState

    init(coordinator: LookupCoordinator, readiness: AppReadiness? = nil, serviceSettings: LookupServiceSettings? = nil,
         onSettings: @escaping () -> Void = {}, onSetup: @escaping () -> Void = {}, onGettingStarted: @escaping () -> Void = {},
         onPermissionSettings: (() -> Void)? = nil) {
        lookupState = ManualLookupState(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Dictionary"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MainWindowView(state: lookupState, coordinator: coordinator,
            onSettings: onSettings, onGettingStarted: onGettingStarted, readiness: readiness ?? .preview(), serviceSettings: serviceSettings ?? .preview(),
            onSetup: onSetup, onPermissionSettings: onPermissionSettings))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func open() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { lookupState.close() }
}
