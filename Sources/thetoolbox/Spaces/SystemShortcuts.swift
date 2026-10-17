import AppKit
import KeyboardShortcuts

/// An enabled macOS keyboard shortcut ("symbolic hotkey") from System Settings → Keyboard →
/// Keyboard Shortcuts.
struct SystemHotKey: Equatable {
    let id: String
    let keyCode: Int
    /// Only ⌃⌥⇧⌘, matching what KeyboardShortcuts records.
    let modifiers: NSEvent.ModifierFlags
}

/// macOS handles its own keyboard shortcuts before any app sees them. Mission Control's defaults
/// (⌃← / ⌃→ to move between spaces, ⌃1… to switch desktops) therefore swallow a matching
/// thetoolbox shortcut, and you get the slow animated switch instead. This finds those clashes and
/// can turn the macOS shortcuts off.
enum SystemShortcuts {
    struct Clash {
        let hotKeyID: String
        let shortcut: KeyboardShortcuts.Shortcut
    }

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let hotKeysKey = "AppleSymbolicHotKeys" as CFString
    private static let comparedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// "Move left a space" (⌃←) and "Move right a space" (⌃→) are on out of the box, but macOS
    /// only writes them to its preferences once they've been changed.
    private static let factoryDefaults: [String: [String: Any]] = [
        "79": ["enabled": true, "value": ["type": "standard", "parameters": [65535, 123, 0x840000]]],
        "81": ["enabled": true, "value": ["type": "standard", "parameters": [65535, 124, 0x840000]]],
    ]

    /// The enabled macOS shortcuts among `shortcuts`.
    static func clashes(with shortcuts: [KeyboardShortcuts.Shortcut]) -> [Clash] {
        enabledHotKeys(in: storedHotKeys()).compactMap { hotKey in
            shortcuts
                .first { $0.carbonKeyCode == hotKey.keyCode
                    && $0.modifiers.intersection(comparedModifiers) == hotKey.modifiers }
                .map { Clash(hotKeyID: hotKey.id, shortcut: $0) }
        }
    }

    /// Turns the clashing macOS shortcuts off, both in System Settings (so it sticks) and in the
    /// running session (so it applies right away).
    static func disable(_ clashes: [Clash]) {
        var stored = storedHotKeys()
        for clash in clashes {
            guard var entry = stored[clash.hotKeyID] as? [String: Any]
                ?? factoryDefaults[clash.hotKeyID] else { continue }
            entry["enabled"] = false
            stored[clash.hotKeyID] = entry
            if let id = Int32(clash.hotKeyID) {
                _ = setSymbolicHotKeyEnabled?(id, false)
            }
        }
        CFPreferencesSetAppValue(hotKeysKey, stored as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// Parses the `AppleSymbolicHotKeys` dictionary, filling in factory defaults it doesn't list.
    static func enabledHotKeys(in stored: [String: Any]) -> [SystemHotKey] {
        let entries = factoryDefaults.merging(stored.compactMapValues { $0 as? [String: Any] }) { _, stored in stored }
        return entries.compactMap { id, entry -> SystemHotKey? in
            guard entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int],
                  parameters.count == 3 else { return nil }
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(parameters[2])).intersection(comparedModifiers)
            return SystemHotKey(id: id, keyCode: parameters[1], modifiers: modifiers)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func storedHotKeys() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(hotKeysKey, domain) as? [String: Any] ?? [:]
    }

    /// Private SkyLight call that toggles a symbolic hotkey for the current login session. Looked
    /// up at runtime so a missing symbol can never break launch; persisting still works without it.
    private typealias SetSymbolicHotKeyEnabled = @convention(c) (Int32, Bool) -> Int32
    private static let setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabled? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetSymbolicHotKeyEnabled.self)
    }()
}
