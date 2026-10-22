import AppKit
import Carbon
import XCTest
@testable import Wharf

final class KeyboardShortcutTests: DockyPreferencesTestCase {

    // MARK: Construction and modifier masking

    func testEmptyShortcutIsInvalidAndReadsNotSet() {
        let empty = KeyboardShortcut.empty
        XCTAssertEqual(empty.keyCode, 0)
        XCTAssertTrue(empty.modifierFlags.isEmpty)
        XCTAssertFalse(empty.isValid)
        XCTAssertEqual(empty.displayString, "Not Set")
    }

    func testInitKeepsOnlySupportedModifiers() {
        let noisy: NSEvent.ModifierFlags = [.command, .capsLock, .function, .numericPad, .help, .option]
        let shortcut = KeyboardShortcut(keyCode: 1, modifierFlags: noisy)
        XCTAssertEqual(shortcut.modifierFlags, [.command, .option])
        XCTAssertEqual(shortcut.modifierFlagsRawValue, NSEvent.ModifierFlags([.command, .option]).rawValue)
    }

    func testCapsLockAloneIsNotAValidShortcut() {
        XCTAssertFalse(KeyboardShortcut(keyCode: 1, modifierFlags: [.capsLock]).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 1, modifierFlags: [.function]).isValid)
    }

    func testEachSupportedModifierMakesAShortcutValid() {
        for flag in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            XCTAssertTrue(KeyboardShortcut(keyCode: 0, modifierFlags: flag).isValid)
        }
    }

    func testEveryModifierSubsetRoundTripsThroughInit() {
        let all: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]
        for mask in 0..<16 {
            var flags: NSEvent.ModifierFlags = []
            for (index, flag) in all.enumerated() where mask & (1 << index) != 0 {
                flags.insert(flag)
            }
            let shortcut = KeyboardShortcut(keyCode: 12, modifierFlags: flags)
            XCTAssertEqual(shortcut.modifierFlags, flags, "mask \(mask)")
            XCTAssertEqual(shortcut.isValid, !flags.isEmpty, "mask \(mask)")
        }
    }

    // MARK: Carbon flags

    func testCarbonModifierFlagsMapEachModifier() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 0, modifierFlags: [.command]).carbonModifierFlags, UInt32(cmdKey))
        XCTAssertEqual(KeyboardShortcut(keyCode: 0, modifierFlags: [.option]).carbonModifierFlags, UInt32(optionKey))
        XCTAssertEqual(KeyboardShortcut(keyCode: 0, modifierFlags: [.control]).carbonModifierFlags, UInt32(controlKey))
        XCTAssertEqual(KeyboardShortcut(keyCode: 0, modifierFlags: [.shift]).carbonModifierFlags, UInt32(shiftKey))
    }

    func testCarbonModifierFlagsCombine() {
        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: [.command, .shift, .option, .control])
        XCTAssertEqual(shortcut.carbonModifierFlags, UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(KeyboardShortcut.empty.carbonModifierFlags, 0)
    }

    func testCarbonFlagsIgnoreUnsupportedBits() {
        let shortcut = KeyboardShortcut(keyCode: 0, modifierFlags: [.capsLock, .command])
        XCTAssertEqual(shortcut.carbonModifierFlags, UInt32(cmdKey))
    }

    // MARK: Display strings

    func testModifierDisplayOrderIsControlOptionShiftCommand() {
        XCTAssertEqual(
            KeyboardShortcut.modifierDisplayString(for: [.command, .shift, .option, .control]),
            "\u{2303}\u{2325}\u{21E7}\u{2318}"
        )
        XCTAssertEqual(KeyboardShortcut.modifierDisplayString(for: []), "")
        XCTAssertEqual(KeyboardShortcut.modifierDisplayString(for: [.capsLock]), "")
    }

    func testDisplayStringCombinesModifiersAndKey() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 48, modifierFlags: [.option]).displayString, "\u{2325}Tab")
        XCTAssertEqual(KeyboardShortcut(keyCode: 0, modifierFlags: [.command, .shift]).displayString, "\u{21E7}\u{2318}A")
        XCTAssertEqual(KeyboardShortcut(keyCode: 49, modifierFlags: [.control]).displayString, "\u{2303}Space")
    }

    func testSpecialKeyNames() {
        let expected: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyboardShortcut.keyDisplayString(for: code), name, "\(code)")
        }
    }

    func testLetterAndDigitKeyNames() {
        let expected: [UInt16: String] = [0: "A", 1: "S", 6: "Z", 12: "Q", 18: "1", 29: "0", 46: "M", 47: ".", 50: "`"]
        for (code, name) in expected {
            XCTAssertEqual(KeyboardShortcut.keyDisplayString(for: code), name, "\(code)")
        }
    }

    func testUnmappedKeyCodeFallsBackToNumericLabel() {
        XCTAssertEqual(KeyboardShortcut.keyDisplayString(for: 999), "Key 999")
        XCTAssertEqual(KeyboardShortcut.keyDisplayString(for: 65535), "Key 65535")
        XCTAssertEqual(KeyboardShortcut.keyDisplayString(for: 10), "Key 10")
    }

    func testEveryKeyCodeHasANonEmptyDisplayString() {
        for code in 0...UInt16.max {
            XCTAssertFalse(KeyboardShortcut.keyDisplayString(for: code).isEmpty, "\(code)")
        }
    }

    func testDisplayStringOfInvalidShortcutIgnoresKeyCode() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 48, modifierFlags: []).displayString, "Not Set")
    }

    func testReleaseInstruction() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 48, modifierFlags: [.option]).releaseInstruction, "Release \u{2325} to switch")
        XCTAssertEqual(KeyboardShortcut(keyCode: 48, modifierFlags: []).releaseInstruction, "Release shortcut to switch")
        XCTAssertEqual(
            KeyboardShortcut(keyCode: 48, modifierFlags: [.control, .shift]).releaseInstruction,
            "Release \u{2303}\u{21E7} to switch"
        )
    }

    // MARK: Events

    private func keyEvent(code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: code
        ))
    }

    func testShortcutFromEventCapturesKeyAndSupportedModifiers() throws {
        let event = try keyEvent(code: 12, flags: [.command, .option, .capsLock])
        let shortcut = try XCTUnwrap(KeyboardShortcut.from(event: event))
        XCTAssertEqual(shortcut.keyCode, 12)
        XCTAssertEqual(shortcut.modifierFlags, [.command, .option])
    }

    func testShortcutFromEventWithoutModifierIsNil() throws {
        XCTAssertNil(KeyboardShortcut.from(event: try keyEvent(code: 12, flags: [])))
        XCTAssertNil(KeyboardShortcut.from(event: try keyEvent(code: 12, flags: [.capsLock])))
    }

    // MARK: Codable

    func testCodableRoundTrip() throws {
        for code in [0, 1, 48, 255, 4096, 65535] as [UInt16] {
            for flags in [[], [.command], [.option, .shift], [.command, .option, .control, .shift]] as [NSEvent.ModifierFlags] {
                let original = KeyboardShortcut(keyCode: code, modifierFlags: flags)
                let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: JSONEncoder().encode(original))
                XCTAssertEqual(decoded, original)
            }
        }
    }

    func testEncodedFormIsStableForPersistence() throws {
        let data = try JSONEncoder().encode(KeyboardShortcut(keyCode: 48, modifierFlags: [.option]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["keyCode", "modifierFlagsRawValue"])
        XCTAssertEqual(object["keyCode"] as? Int, 48)
        XCTAssertEqual(object["modifierFlagsRawValue"] as? UInt, NSEvent.ModifierFlags.option.rawValue)
    }

    func testDecodedUnsupportedBitsAreMaskedByTheAccessors() throws {
        let hostileBits: UInt = NSEvent.ModifierFlags.capsLock.rawValue | NSEvent.ModifierFlags.command.rawValue | 0xFFFF
        let data = json("{\"keyCode\":1,\"modifierFlagsRawValue\":\(hostileBits)}")
        let shortcut = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(shortcut.modifierFlags, [.command])
        XCTAssertEqual(shortcut.carbonModifierFlags, UInt32(cmdKey))
        XCTAssertTrue(shortcut.isValid)
        XCTAssertEqual(shortcut.displayString, "\u{2318}S")
    }

    func testDecodedShortcutWithOnlyUnsupportedBitsIsInvalid() throws {
        let data = json("{\"keyCode\":1,\"modifierFlagsRawValue\":\(NSEvent.ModifierFlags.capsLock.rawValue)}")
        let shortcut = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertFalse(shortcut.isValid)
        XCTAssertEqual(shortcut.displayString, "Not Set")
    }

    func testDecodingRejectsOutOfRangeKeyCodes() {
        for code in ["-1", "65536", "70000", "1e6"] {
            let data = json("{\"keyCode\":\(code),\"modifierFlagsRawValue\":0}")
            XCTAssertThrowsError(try JSONDecoder().decode(KeyboardShortcut.self, from: data), code)
        }
    }

    // MARK: Persistence through DockyPreferences

    func testShortcutDefaults() {
        let prefs = makePrefs()
        XCTAssertEqual(prefs.launchpadShortcut, .empty)
        XCTAssertEqual(prefs.windowSwitcherShortcut, KeyboardShortcut(keyCode: 48, modifierFlags: [.option]))
    }

    func testShortcutSettersPersistAndReload() {
        let prefs = makePrefs()
        prefs.launchpadShortcut = KeyboardShortcut(keyCode: 37, modifierFlags: [.command, .shift])
        prefs.windowSwitcherShortcut = KeyboardShortcut(keyCode: 48, modifierFlags: [.control])
        let reloaded = reload()
        XCTAssertEqual(reloaded.launchpadShortcut, KeyboardShortcut(keyCode: 37, modifierFlags: [.command, .shift]))
        XCTAssertEqual(reloaded.windowSwitcherShortcut, KeyboardShortcut(keyCode: 48, modifierFlags: [.control]))
    }

    func testClearingAShortcutPersistsTheEmptyValue() {
        let prefs = makePrefs()
        prefs.windowSwitcherShortcut = .empty
        XCTAssertNotNil(defaults.data(forKey: PrefKeys.windowSwitcherShortcut))
        XCTAssertEqual(reload().windowSwitcherShortcut, .empty)
    }

    func testStoredShortcutWithHostileKeyCodeFallsBackToDefaults() {
        defaults.set(json("{\"keyCode\":70000,\"modifierFlagsRawValue\":524288}"), forKey: PrefKeys.windowSwitcherShortcut)
        defaults.set(json("{\"keyCode\":-1,\"modifierFlagsRawValue\":524288}"), forKey: PrefKeys.launchpadShortcut)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.windowSwitcherShortcut, KeyboardShortcut(keyCode: 48, modifierFlags: [.option]))
        XCTAssertEqual(prefs.launchpadShortcut, .empty)
    }

    func testStoredShortcutWrongTypeFallsBackToDefaults() {
        defaults.set("option-tab", forKey: PrefKeys.windowSwitcherShortcut)
        defaults.set(12, forKey: PrefKeys.launchpadShortcut)
        let prefs = makePrefs()
        XCTAssertEqual(prefs.windowSwitcherShortcut, KeyboardShortcut(keyCode: 48, modifierFlags: [.option]))
        XCTAssertEqual(prefs.launchpadShortcut, .empty)
    }
}
