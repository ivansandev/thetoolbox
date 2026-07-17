import AppKit

/// A single "clear the screen for presenting" mode. When active it hides desktop icons and widgets —
/// on both the standard desktop *and* Stage Manager — and auto-hides the Dock. Turning it off restores
/// each of those to the *exact* state it had before the mode was enabled: the state is captured as a
/// snapshot on enable, and on disable every key is written back to its captured value — or deleted, if it
/// had no value before (an absent key is not the same as one explicitly set to `false`).
///
/// Icons/widgets are governed by the `WindowManager` process on modern macOS (Sonoma+/Tahoe), via the
/// `com.apple.WindowManager` domain — the legacy `com.apple.finder CreateDesktop` key does nothing there.
/// Each visibility axis has a separate key for the standard desktop and for Stage Manager, so the mode
/// writes all four; the earlier per-toggle implementation only wrote the `Standard*` keys and therefore
/// left icons/widgets showing under Stage Manager.
///
/// (Do Not Disturb was intentionally left out: the Focus DB under `~/Library/DoNotDisturb` is
/// TCC-protected, so toggling it would require Full Disk Access. It can be added later behind a
/// user-chosen mechanism.)
final class PresentationModeManager: ObservableObject {
    @Published var isActive: Bool

    private let defaults = UserDefaults.standard

    private static let windowManagerDomain = "com.apple.WindowManager"
    private static let dockDomain = "com.apple.dock"
    private static let dockAutoHideKey = "autohide"
    private static let windowManagerKeys = [
        "StandardHideDesktopIcons",
        "StageManagerHideDesktopIcons",
        "StandardHideWidgets",
        "StageManagerHideWidgets",
    ]

    /// The state we captured when the mode was turned on, so turning it off can put things back exactly.
    /// A domain/key pair is recorded here only if it *had* a value before enabling; a key absent from the
    /// relevant map was unset, and restoring deletes it rather than writing a value.
    private struct Snapshot: Codable {
        /// WindowManager key → its original Bool value. Keys not present here were unset before enabling.
        var windowManager: [String: Bool]
        /// The Dock's original `autohide` value; nil if it had none.
        var dockAutoHide: Bool?
    }

    init() {
        // The system keys persist, so if the mode was on at quit the desktop is already cleared and the
        // toggle should read on — no re-apply needed, just reflect the stored flag.
        isActive = defaults.bool(forKey: PreferenceKey.presentationModeActive)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active

        if active {
            // Capture what's there *now* (authoritative read, see currentBool) before overwriting it.
            let snapshot = captureSnapshot()
            persist(snapshot)
            applyPresenting()
        } else {
            restore(loadSnapshot())
            defaults.removeObject(forKey: PreferenceKey.presentationModeSnapshot)
        }
        defaults.set(active, forKey: PreferenceKey.presentationModeActive)
    }

    private func captureSnapshot() -> Snapshot {
        var wmSnap: [String: Bool] = [:]
        for key in Self.windowManagerKeys {
            if let value = currentBool(Self.windowManagerDomain, key) {
                wmSnap[key] = value
            }
        }
        return Snapshot(
            windowManager: wmSnap,
            dockAutoHide: currentBool(Self.dockDomain, Self.dockAutoHideKey)
        )
    }

    /// Hides everything. Writes the preferences and *then* relaunches the owning process — the write must
    /// commit before the `killall` (firing `killall` without waiting was the original desktop-toggle bug),
    /// so this runs off the main thread and blocks on each step in order.
    private func applyPresenting() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for key in Self.windowManagerKeys {
                self.write(Self.windowManagerDomain, key, true)
            }
            self.run("/usr/bin/killall", ["WindowManager"])

            self.write(Self.dockDomain, Self.dockAutoHideKey, true)
            self.run("/usr/bin/killall", ["Dock"])
        }
    }

    /// Puts every key back exactly as the snapshot found it: restore its captured value, or delete it if it
    /// had none. A missing snapshot (shouldn't happen) falls back to un-hiding everything.
    private func restore(_ snapshot: Snapshot?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for key in Self.windowManagerKeys {
                if let snapshot {
                    self.restore(Self.windowManagerDomain, key, to: snapshot.windowManager[key])
                } else {
                    self.write(Self.windowManagerDomain, key, false)
                }
            }
            self.run("/usr/bin/killall", ["WindowManager"])

            if let snapshot {
                self.restore(Self.dockDomain, Self.dockAutoHideKey, to: snapshot.dockAutoHide)
            } else {
                self.write(Self.dockDomain, Self.dockAutoHideKey, false)
            }
            self.run("/usr/bin/killall", ["Dock"])
        }
    }

    private func restore(_ domain: String, _ key: String, to value: Bool?) {
        if let value {
            write(domain, key, value)
        } else {
            run("/usr/bin/defaults", ["delete", domain, key])
        }
    }

    private func persist(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: PreferenceKey.presentationModeSnapshot)
        }
    }

    private func loadSnapshot() -> Snapshot? {
        guard let data = defaults.data(forKey: PreferenceKey.presentationModeSnapshot) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func write(_ domain: String, _ key: String, _ value: Bool) {
        run("/usr/bin/defaults", ["write", domain, key, "-bool", value ? "true" : "false"])
    }

    /// Reads a Bool preference authoritatively via `defaults read` (rather than `UserDefaults(suiteName:)`,
    /// which caches per-process and can miss changes another process — e.g. System Settings — made since).
    /// Returns nil if the key is unset or not a recognizable bool, so the caller can treat it as "absent".
    private func currentBool(_ domain: String, _ key: String) -> Bool? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", domain, key]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            NSLog("thetoolbox presentation: read \(domain) \(key) failed: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }   // key absent
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch out {
        case "1", "true", "YES": return true
        case "0", "false", "NO": return false
        default: return nil
        }
    }

    private func run(_ path: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("thetoolbox presentation: \(path) \(args) failed: \(error)")
        }
    }
}
