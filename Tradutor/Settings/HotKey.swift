import AppKit
import Carbon.HIToolbox

/// Atalho de teclado global: tecla física (`keyCode`, independente do layout) + modificadores
/// no formato Carbon, que é o que `RegisterEventHotKey` recebe.
struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Nome da tecla tal como estava no teclado quando o atalho foi gravado (ex.: "L").
    var key: String

    static let defaultToggleCaptions = HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey), key: "L")
    static let defaultCycleDisplayMode = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), key: "M")

    /// Como no menu do macOS: ⌃⌥⇧⌘ por esta ordem, seguidos da tecla.
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + key
    }

    /// Para o VoiceOver, que lê mal os símbolos (ex.: "Control Option L").
    var spokenDescription: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        return (parts + [key]).joined(separator: " ")
    }
}

extension HotKey {
    /// Atalho a partir de uma tecla premida no gravador. Exige ⌃, ⌥ ou ⌘ (só ⇧ apanharia
    /// texto normal), exceto nas teclas de função.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let functionKey = Self.functionKeys[Int(event.keyCode)]
        guard functionKey != nil || !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }

        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        // `charactersIgnoringModifiers` dá a tecla do layout atual ("L"), mas com ⌥ e ⇧ pode
        // dar outro carácter; por isso as teclas especiais têm nome próprio.
        let name = functionKey ?? Self.specialKeys[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: name)
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Espaço", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}
