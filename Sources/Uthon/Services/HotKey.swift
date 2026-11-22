import Carbon

/// Global shortcut: Control + Option + Space opens or closes the island.
final class HotKey {
    static let shared = HotKey()

    private var hotKeyRef: EventHotKeyRef?
    var isRegistered: Bool { hotKeyRef != nil }
    private var handlerInstalled = false

    func update() {
        if AppSettings.shared.hotkeyEnabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { IslandController.shared.toggleFromShortcut() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5554_484E), id: 1)   // "UTHN"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        // Another app may already use ⌃⌥Space: Settings says so instead of a dead switch.
        registrationFailed = status != noErr
        if registrationFailed { hotKeyRef = nil }
    }

    /// True when ⌃⌥Space could not be taken (another app has it).
    private(set) var registrationFailed = false

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
