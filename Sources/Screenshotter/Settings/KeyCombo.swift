import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored with Carbon key code and modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Human readable key name, captured when the shortcut is recorded (e.g. "2", "A", "F5").
    var key: String

    static let `default` = KeyCombo(
        keyCode: UInt32(kVK_ANSI_2),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        key: "2"
    )

    init(keyCode: UInt32, carbonModifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isFunctionKey = Self.functionKeyNames[Int(event.keyCode)] != nil
        guard isFunctionKey || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }

        keyCode = UInt32(event.keyCode)
        carbonModifiers = Self.carbonFlags(from: flags)
        if let name = Self.specialKeyNames[Int(event.keyCode)] {
            key = name
        } else if let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty {
            key = chars.uppercased()
        } else {
            return nil
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var displayString: String {
        var s = ""
        let flags = modifierFlags
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    /// Key equivalent usable on an NSMenuItem (display only), or nil for keys menus can't show.
    var menuKeyEquivalent: String? {
        if key.count == 1 { return key.lowercased() }
        if let index = Self.functionKeyNames[Int(keyCode)],
           let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + index - 1)) {
            return String(Character(scalar))
        }
        return nil
    }

    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Function keys map to their number (F1 → 1).
    private static let functionKeyNames: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
        kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12,
        kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
        kVK_F19: 19, kVK_F20: 20,
    ]

    private static let specialKeyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (code, number) in functionKeyNames { names[code] = "F\(number)" }
        return names
    }()
}
