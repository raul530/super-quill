import AppKit
import Carbon.HIToolbox

/// One system-wide hotkey via Carbon's RegisterEventHotKey — the only
/// global-shortcut API that works without an Accessibility or Input
/// Monitoring grant, which matters for a permissionless menu-bar daemon.
///
/// Spec strings are "+"-joined: "cmd+f8" (the default), "cmd+shift+r",
/// "ctrl+alt+f5". Modifiers: cmd/command, shift, alt/option/opt,
/// ctrl/control. Keys: a–z, 0–9, f1–f20. A modifier is required — a bare
/// key would swallow normal typing system-wide.
@MainActor
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: @MainActor () -> Void

    init?(spec: String, onPress: @escaping @MainActor () -> Void) {
        guard let (keyCode, modifiers) = Self.parse(spec) else { return nil }
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon dispatches on the main event loop, so this holds.
            MainActor.assumeIsolated { hotkey.onPress() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef) == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5149_4C4C) /* QILL */, id: 1)
        guard RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef
        ) == noErr, hotKeyRef != nil else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    // No deinit: the hotkey is registered once and lives until the process
    // exits, at which point the system tears it down. (Swift 6 also forbids
    // touching these non-Sendable Carbon refs from a nonisolated deinit.)

    private static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "alt", "option", "opt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case let name:
                guard key == nil, let code = keyCodes[name] else { return nil }
                key = code
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
        "f18": 79, "f19": 80, "f20": 90,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
    ]
}
