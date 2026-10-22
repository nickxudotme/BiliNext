import AppKit
import SwiftUI
import XCTest

@testable import SwiftFeedback

final class FeedbackShortcutTests: XCTestCase {
    func testNormalizesLettersAndIgnoresDeviceModifierFlags() throws {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .numericPad, .function]
        let shortcut = FeedbackShortcut(key: "F", modifiersRawValue: flags.rawValue)

        XCTAssertEqual(shortcut.key, "f")
        XCTAssertEqual(shortcut.modifierFlags, [.command, .shift])
        XCTAssertEqual(shortcut.displayName, "⇧⌘F")
        XCTAssertEqual(shortcut.keyboardShortcut.modifiers, [.command, .shift])
        XCTAssertTrue(shortcut.isValid)
        XCTAssertEqual(
            try JSONDecoder().decode(FeedbackShortcut.self, from: JSONEncoder().encode(shortcut)),
            shortcut)
    }

    func testRejectsUnmodifiedAndNonPrintableKeys() {
        for flags: NSEvent.ModifierFlags in [[], .shift, .capsLock] {
            XCTAssertFalse(FeedbackShortcut(key: "f", modifiersRawValue: flags.rawValue).isValid)
        }
        for key in ["", "ab", "\t", "\n", " ", "\u{F700}", "\u{200D}"] {
            XCTAssertFalse(
                FeedbackShortcut(
                    key: key, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue
                ).isValid)
        }
        for key in ["f", "5", "/", "é"] {
            XCTAssertTrue(
                FeedbackShortcut(key: key, modifiersRawValue: NSEvent.ModifierFlags.option.rawValue)
                    .isValid)
        }
    }

    func testMatchesOnlyExactUserModifiers() {
        let shortcut = FeedbackShortcut(
            key: "f", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue)

        XCTAssertTrue(
            shortcut.matches(
                key: "F", modifiersRawValue: NSEvent.ModifierFlags([.command, .capsLock]).rawValue))
        XCTAssertFalse(
            shortcut.matches(
                key: "f", modifiersRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue))
        XCTAssertFalse(
            shortcut.matches(key: "f", modifiersRawValue: NSEvent.ModifierFlags.control.rawValue))
        XCTAssertFalse(
            shortcut.matches(key: "g", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue))
    }

    func testMenuConflictReturnsSpecificItemAndExcludesFeedbackAction() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let shortcut = FeedbackShortcut(key: "f", modifiersRawValue: command)
        let feedback = FeedbackShortcutMenuItem(
            title: "反馈当前界面…", key: "f", modifiersRawValue: command)
        let find = FeedbackShortcutMenuItem(
            title: "查找…", path: "编辑 → 查找…", key: "f", modifiersRawValue: command)

        XCTAssertNil(shortcut.conflictingMenuItem(in: [feedback]))
        XCTAssertEqual(shortcut.conflictingMenuItem(in: [feedback, find]), find)
        XCTAssertEqual(shortcut.conflictingMenuItem(in: [find])?.path, "编辑 → 查找…")
    }

    func testUppercaseMenuEquivalentIncludesShift() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let shiftedCommand = NSEvent.ModifierFlags([.command, .shift]).rawValue
        let menu = FeedbackShortcutMenuItem(title: "示例", key: "F", modifiersRawValue: command)

        XCTAssertNil(
            FeedbackShortcut(key: "f", modifiersRawValue: command).conflictingMenuItem(in: [menu]))
        XCTAssertEqual(
            FeedbackShortcut(key: "f", modifiersRawValue: shiftedCommand).conflictingMenuItem(in: [
                menu
            ]), menu)
    }

    func testDecodedAndMutatedValuesAreNormalized() throws {
        let flags = NSEvent.ModifierFlags([.control, .capsLock]).rawValue
        let data = Data("{\"key\":\"A\",\"modifiersRawValue\":\(flags)}".utf8)
        var shortcut = try JSONDecoder().decode(FeedbackShortcut.self, from: data)

        XCTAssertEqual(shortcut.key, "a")
        XCTAssertEqual(shortcut.modifierFlags, .control)
        shortcut.key = "Z"
        shortcut.modifiersRawValue = NSEvent.ModifierFlags([.option, .numericPad]).rawValue
        XCTAssertEqual(shortcut.displayName, "⌥Z")
        shortcut.key = "invalid"
        XCTAssertFalse(shortcut.isValid)
    }
}
