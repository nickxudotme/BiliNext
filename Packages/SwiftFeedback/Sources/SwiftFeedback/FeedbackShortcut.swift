import AppKit
import SwiftUI

/// An application-local shortcut. Modifier values use `NSEvent.ModifierFlags`.
public struct FeedbackShortcut: Codable, Equatable, Sendable {
    public var key: String {
        didSet { key = Self.normalizedKey(key) ?? "" }
    }

    public var modifiersRawValue: UInt {
        didSet { modifiersRawValue = Self.normalizedModifiers(modifiersRawValue) }
    }

    public init(key: String, modifiersRawValue: UInt) {
        self.key = Self.normalizedKey(key) ?? ""
        self.modifiersRawValue = Self.normalizedModifiers(modifiersRawValue)
    }

    /// Invalid values should be discarded when restoring a saved preference.
    public var isValid: Bool {
        Self.normalizedKey(key) != nil
            && !modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    public var keyboardShortcut: KeyboardShortcut {
        var modifiers: EventModifiers = []
        if modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifierFlags.contains(.option) { modifiers.insert(.option) }
        if modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if modifierFlags.contains(.command) { modifiers.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(key.first ?? "\0"), modifiers: modifiers)
    }

    public var displayName: String {
        guard isValid else { return "未设置" }
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        return result + key.uppercased()
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    static func normalizedModifiers(_ rawValue: UInt) -> UInt {
        NSEvent.ModifierFlags(rawValue: rawValue)
            .intersection([.command, .control, .option, .shift]).rawValue
    }

    static func normalizedKey(_ key: String) -> String? {
        let normalized = key.lowercased()
        guard normalized.count == 1,
            !normalized.unicodeScalars.isEmpty,
            normalized.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && scalar.properties.generalCategory != .privateUse
                    && scalar.properties.generalCategory != .format
            })
        else { return nil }
        return normalized
    }

    func matches(key: String, modifiersRawValue: UInt) -> Bool {
        isValid && Self.normalizedKey(key) == self.key
            && Self.normalizedModifiers(modifiersRawValue) == self.modifiersRawValue
    }

    func conflictingMenuItem(in items: [FeedbackShortcutMenuItem]) -> FeedbackShortcutMenuItem? {
        items.first { item in
            !Self.isFeedbackMenuTitle(item.title)
                && matches(key: item.key, modifiersRawValue: item.modifiersRawValue)
        }
    }

    private static func isFeedbackMenuTitle(_ title: String) -> Bool {
        title == "反馈当前界面…" || title == "反馈当前界面..."
    }

    private enum CodingKeys: String, CodingKey {
        case key, modifiersRawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            modifiersRawValue: try container.decode(UInt.self, forKey: .modifiersRawValue))
    }
}

/// A value-only menu description keeps conflict matching independent of AppKit state.
struct FeedbackShortcutMenuItem: Equatable {
    let title: String
    let path: String
    let key: String
    let modifiersRawValue: UInt

    init(title: String, path: String? = nil, key: String, modifiersRawValue: UInt) {
        self.title = title
        self.path = path ?? title
        self.key = key
        var modifiers = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        // AppKit also accepts uppercase key equivalents as Shift shortcuts.
        if key != key.lowercased() { modifiers.insert(.shift) }
        self.modifiersRawValue = FeedbackShortcut.normalizedModifiers(modifiers.rawValue)
    }
}
