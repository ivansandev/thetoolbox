import AppKit
import XCTest
@testable import thetoolbox

final class SystemShortcutsTests: XCTestCase {
    private func entry(enabled: Bool, keyCode: Int, modifiers: Int) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": [65535, keyCode, modifiers]]]
    }

    func testMoveBetweenSpacesIsOnByDefault() {
        let hotKeys = SystemShortcuts.enabledHotKeys(in: [:])

        XCTAssertEqual(hotKeys, [
            SystemHotKey(id: "79", keyCode: 123, modifiers: .control),
            SystemHotKey(id: "81", keyCode: 124, modifiers: .control),
        ])
    }

    func testStoredEntryOverridesDefault() {
        let stored: [String: Any] = ["79": entry(enabled: false, keyCode: 123, modifiers: 0x840000)]

        XCTAssertEqual(SystemShortcuts.enabledHotKeys(in: stored).map(\.id), ["81"])
    }

    func testEnabledDesktopShortcutIsListedWithoutFunctionFlag() {
        let stored: [String: Any] = [
            "79": entry(enabled: false, keyCode: 123, modifiers: 0x840000),
            "81": entry(enabled: false, keyCode: 124, modifiers: 0x840000),
            "118": entry(enabled: true, keyCode: 18, modifiers: 0x40000 | 0x80000),
            "119": entry(enabled: false, keyCode: 19, modifiers: 0x40000),
        ]

        XCTAssertEqual(SystemShortcuts.enabledHotKeys(in: stored), [
            SystemHotKey(id: "118", keyCode: 18, modifiers: [.control, .option]),
        ])
    }

    func testMalformedEntriesAreIgnored() {
        let stored: [String: Any] = [
            "79": entry(enabled: false, keyCode: 123, modifiers: 0x840000),
            "81": entry(enabled: false, keyCode: 124, modifiers: 0x840000),
            "60": ["enabled": true],
            "61": "not a dictionary",
        ]

        XCTAssertTrue(SystemShortcuts.enabledHotKeys(in: stored).isEmpty)
    }
}
