import AppKit
import SwiftUI
import Combine

@MainActor
final class PopupState: ObservableObject {
    @Published var phase: LookupPhase = .idle
    @Published var isPinned: Bool = false
    @Published var availableSize = CGSize(width: 420, height: 560)
    @Published var contentHeight: CGFloat = 1
    @Published var cloudControlsHeight: CGFloat = 1
}

/// Lets the user drag the window by clicking anywhere on the background.
/// SwiftUI controls (buttons, text views) consume their hit-tests first, so
/// this `mouseDown` only fires for clicks that fall through to the panel.
private final class DraggablePanel: NSPanel {
    override func mouseDown(with event: NSEvent) {
        self.performDrag(with: event)
    }
}

@MainActor
final class PopupController {
    private var window: NSPanel?
    private let state = PopupState()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var observation: AnyCancellable?
    private var geometryObservation: AnyCancellable?
    private let coordinator: LookupCoordinator
    private let diagnostics: QADiagnostics?
    private var displayedIntent: UUID?

    init(coordinator: LookupCoordinator, diagnostics: QADiagnostics? = nil) {
        self.coordinator = coordinator
        self.diagnostics = diagnostics
        observation = coordinator.$selection.sink { [weak self] phase in self?.render(phase) }
    }

    private func render(_ phase: LookupPhase) {
        state.phase = phase
        switch phase {
        case .idle: hide()
        case .finished(_, .cancelled): hide()
        default:
            displayedIntent = coordinator.selectionIntent
            present()
            diagnostics?.presentation(intent: coordinator.selectionIntent, visible: window?.isVisible == true,
                                      expectedVisible: true, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
    }

    func close() {
        coordinator.dismissSelection()
        hide()
    }

    /// Capture the action at event receipt; delivery may happen after a lookup update.
    func outsideClickAction() -> @MainActor () -> Void {
        let intent = coordinator.selectionIntent
        return { [weak self] in
            guard let self, self.coordinator.selectionIntent == intent, !self.state.isPinned else { return }
            self.close()
        }
    }

    private func hide() {
        window?.orderOut(nil)
        if let displayedIntent {
            diagnostics?.presentation(intent: displayedIntent, visible: window?.isVisible == true,
                                      expectedVisible: false, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            self.displayedIntent = nil
        }
        removeOutsideClickMonitor()
        state.isPinned = false
    }

    // A global monitor only fires for clicks that go to *other* apps, so any
    // click it sees is by definition outside our popup → safe to dismiss,
    // unless the user has pinned the popup.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            let dismiss = self?.outsideClickAction()
            Task { @MainActor in dismiss?() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.window, !self.state.isPinned { self.close() }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    private func present() {
        let screen = window?.isVisible == true ? window?.screen :
            NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        if let visible = (screen ?? NSScreen.main)?.visibleFrame { updateAvailableSize(visible) }
        if window == nil {
            let view = CoordinatorPopupView(state: state, coordinator: coordinator,
                                            onClose: { [weak self] in self?.close() })
            let hosting = NSHostingController(rootView: view)
            // Panel auto-resizes to fit the SwiftUI view's preferred size, so a
            // long translation no longer gets clipped by a fixed frame.
            hosting.sizingOptions = .preferredContentSize
            let panel = DraggablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hosting
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hasShadow = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovable = true
            window = panel
            let center = NotificationCenter.default
            geometryObservation = Publishers.MergeMany([
                center.publisher(for: NSWindow.didResizeNotification, object: panel),
                center.publisher(for: NSWindow.didChangeScreenNotification, object: panel),
                center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            ])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.keepOnScreen() }
        }
        guard let window else { return }
        // Reposition only when the window was hidden — preserve the user's
        // drag-position if they pinned it and triggered another lookup.
        if !window.isVisible {
            positionNearCursor(window)
        }
        keepOnScreen()
        window.orderFrontRegardless()
        installOutsideClickMonitor()
    }

    private func positionNearCursor(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        var frame = window.frame
        frame.origin = NSPoint(x: mouse.x + 12, y: mouse.y - frame.height - 12)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame = PopupScreenBounds.clamp(frame, to: visible)
        }
        window.setFrame(frame, display: true)
    }

    private func updateAvailableSize(_ visible: NSRect) {
        let size = PopupScreenBounds.available(in: visible).size
        if state.availableSize != size { state.availableSize = size }
    }

    private func keepOnScreen() {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        updateAvailableSize(visible)
        let frame = PopupScreenBounds.clamp(window.frame, to: visible)
        // A fitting pinned panel keeps its user-chosen position.
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}

private struct CoordinatorPopupView: View {
    @ObservedObject var state: PopupState
    @ObservedObject var coordinator: LookupCoordinator
    let onClose: () -> Void
    var body: some View {
        TranslationPopupView(state: state, onClose: onClose, cloud: coordinator.selectionCloud,
            primaryLabel: coordinator.primaryLabel, primaryIsCloud: coordinator.primaryIsCloud)
    }
}

enum PopupScreenBounds {
    static func available(in visible: NSRect) -> NSRect { visible.insetBy(dx: 8, dy: 8) }

    static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let bounds = available(in: visible)
        let size = NSSize(width: min(frame.width, bounds.width), height: min(frame.height, bounds.height))
        return NSRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - size.width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
