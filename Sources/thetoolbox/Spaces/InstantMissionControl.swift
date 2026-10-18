import AppKit

/// Opens Mission Control and App Exposé from their macOS keyboard shortcuts without the zoom
/// animation, by posting a fast synthetic trackpad swipe instead (`MissionControlSwipe.c`).
/// Closing is left to macOS, which already does it promptly.
final class InstantMissionControl {
    var isEnabled = false

    private enum View {
        case missionControl, appExpose
    }

    private var shortcuts: [SpaceSwitcher.KeyCombo: View] = [:]
    private var shortcutsLoadedAt = Date.distantPast

    /// Called from the key tap. Returns true to consume the key press.
    func handleKeyDown(_ combo: SpaceSwitcher.KeyCombo, isRepeat: Bool) -> Bool {
        guard isEnabled, let view = currentShortcuts[combo] else { return false }
        // Holding the keys down shouldn't open and close it repeatedly; swallow the repeats.
        if isRepeat { return true }
        // Already showing: let macOS handle the key, which closes it.
        if Self.isShowing { return false }
        DispatchQueue.main.async {
            guard AccessibilityPermission.isGranted else { return }
            if !tb_post_vertical_dock_swipe(view == .missionControl) { NSSound.beep() }
        }
        return true
    }

    // MARK: macOS shortcuts

    /// The shortcuts live in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.
    /// Re-read them at most every couple of seconds so changes there are picked up.
    private var currentShortcuts: [SpaceSwitcher.KeyCombo: View] {
        if Date().timeIntervalSince(shortcutsLoadedAt) > 2 {
            shortcuts = Self.loadShortcuts()
            shortcutsLoadedAt = Date()
        }
        return shortcuts
    }

    private static func loadShortcuts() -> [SpaceSwitcher.KeyCombo: View] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]

        var table: [SpaceSwitcher.KeyCombo: View] = [:]
        // Symbolic hot key IDs, with the macOS defaults (⌃↑, ⌃↓) for ones never changed.
        let entries: [(id: String, view: View, defaultKeyCode: Int)] = [
            ("32", .missionControl, 126),
            ("33", .appExpose, 125),
        ]
        for entry in entries {
            guard let combo = combo(from: hotKeys[entry.id], defaultKeyCode: entry.defaultKeyCode) else { continue }
            table[combo] = entry.view
        }
        return table
    }

    /// An entry looks like `{ enabled = 1; value = { parameters = (char, keyCode, modifiers); }; }`.
    private static func combo(from entry: Any?, defaultKeyCode: Int) -> SpaceSwitcher.KeyCombo? {
        guard let entry = entry as? [String: Any] else {
            return SpaceSwitcher.KeyCombo(keyCode: defaultKeyCode, modifiers: .control)
        }
        guard (entry["enabled"] as? Bool) ?? true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              parameters[1] != 0xFFFF
        else { return nil }
        return SpaceSwitcher.KeyCombo(keyCode: parameters[1],
                                      modifiers: NSEvent.ModifierFlags(rawValue: UInt(parameters[2])))
    }

    // MARK: State

    /// On macOS 27, Mission Control and App Exposé both cover the screen with a WindowManager
    /// window at this layer, which isn't on screen otherwise.
    private static let overlayLayer = 19

    private static var isShowing: Bool {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let windowManagerOverlay = windows.contains {
            $0[kCGWindowOwnerName as String] as? String == "WindowManager"
                && $0[kCGWindowLayer as String] as? Int == overlayLayer
        }
        // Earlier macOS versions draw them in the Dock, which the core knows how to spot.
        return windowManagerOverlay || iss_is_mission_control_active() || iss_is_expose_active()
    }
}
