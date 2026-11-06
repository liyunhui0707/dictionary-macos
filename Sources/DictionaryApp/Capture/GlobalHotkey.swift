import AppKit
import Carbon.HIToolbox

final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    // Single shared handler — we only register one hotkey for v1.
    private static var handler: (() -> Void)?

    /// True iff the hotkey is currently bound at the system level. Allows
    /// the caller to skip redundant register/unregister calls.
    var isRegistered: Bool { hotKeyRef != nil }

    @discardableResult
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_D),
        modifiers: UInt32 = UInt32(optionKey),
        handler: @escaping () -> Void
    ) -> OSStatus {
        Self.handler = handler

        // Install the Carbon event handler exactly once; subsequent register()
        // calls only re-bind the hotkey, not the handler.
        if handlerRef == nil {
            // Fire on key *release* so the user has lifted ⌥ by the time we
            // simulate ⌘C — otherwise the synthetic event gets interpreted as
            // ⌥⌘C and the focused app ignores it.
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyReleased)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    GlobalHotkey.handler?()
                    return noErr
                },
                1,
                &eventType,
                nil,
                &handlerRef
            )
            guard status == noErr else { return status }
        }

        // Idempotent: if already registered, leave it alone.
        guard hotKeyRef == nil else { return noErr }

        let hkID = EventHotKeyID(signature: OSType(0x44494354), id: 1) // 'DICT'
        return RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    /// Removes the system-level binding but keeps the Carbon handler installed
    /// so a later `register()` is cheap. Safe to call when already unregistered.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = handlerRef { RemoveEventHandler(h) }
    }
}
