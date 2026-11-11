import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts that work while Spotify (or anything else) is in front.
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.
/// Events arrive on the main thread.
final class GlobalHotKeys {
    struct Shortcut {
        let keyCode: Int
        let modifiers: Int
        let label: String

        /// ⌃⌥G — grab
        static let grab = Shortcut(keyCode: kVK_ANSI_G, modifiers: controlKey | optionKey, label: "⌃⌥G")
        /// ⌃⌥R — start/stop recording
        static let record = Shortcut(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey, label: "⌃⌥R")
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Returns false if another app already owns the shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        if handler == nil { installHandler() }
        let id = UInt32(Self.actions.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5353_5052), id: id) // 'SSPR'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        Self.actions[id] = action
        refs.append(ref)
        return true
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if err == noErr, let action = GlobalHotKeys.actions[hotKeyID.id] { action() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
