import AppKit
import KeyboardShortcuts

/// Switches spaces instantly, with no slide animation. The work is done by the vendored
/// InstantSpaceSwitcher core (`Vendor/InstantSpaceSwitcher`): it posts a synthetic trackpad swipe
/// fast enough that the Dock skips the animation, and can do the same for real trackpad swipes.
final class SpaceSwitcher: ObservableObject {
    /// Highest space number with its own shortcut, matching the original app.
    static let maxSpaces = 16

    /// Real three/four-finger swipes between spaces also switch instantly.
    @Published var instantSwipes: Bool {
        didSet {
            prefs.instantSpaceSwipes = instantSwipes
            iss_set_swipe_override(instantSwipes)
        }
    }

    private let prefs = Preferences.shared
    private var coreRetryTimer: Timer?

    init() {
        instantSwipes = prefs.instantSpaceSwipes
        seedDefaultsIfNeeded()
        startCore()
        // Lets real swipes pass through untouched while App Exposé is open.
        iss_set_overlay_detection_enabled(true)
        iss_set_swipe_override(instantSwipes)
        registerShortcuts()
        // Drop the core's predicted position once the space changes by other means.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in iss_reset_predictions() }
    }

    /// On first launch only, install ⌃← / ⌃→ for previous/next and ⌃1…⌃0 for spaces 1–10.
    /// Never clobbers a shortcut the user already set, here or on a window action.
    private func seedDefaultsIfNeeded() {
        let flag = "didSeedSpaceDefaults.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        var defaults: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
            (.spacePrevious, KeyboardShortcuts.Shortcut(.leftArrow, modifiers: .control)),
            (.spaceNext, KeyboardShortcuts.Shortcut(.rightArrow, modifiers: .control)),
        ]
        let digits: [KeyboardShortcuts.Key] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero]
        for (index, key) in digits.enumerated() {
            defaults.append((KeyboardShortcuts.Name.switchToSpace(index + 1),
                             KeyboardShortcuts.Shortcut(key, modifiers: .control)))
        }

        let windowNames = KeyboardShortcuts.Name.windowShortcuts
            + prefs.loadCustomSizes().map { WindowManager.shortcutName(for: $0.id) }
        let taken = windowNames.compactMap { KeyboardShortcuts.getShortcut(for: $0) }
        for (name, shortcut) in defaults
        where KeyboardShortcuts.getShortcut(for: name) == nil && !taken.contains(shortcut) {
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        }
    }

    /// The core's event tap (needed for instant swipes) requires Accessibility. Until it's
    /// granted, retry quietly so swipes start working as soon as it is.
    private func startCore() {
        guard !Self.startCoreIfPermitted() else { return }
        coreRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Self.startCoreIfPermitted() else { return }
            timer.invalidate()
            self?.coreRetryTimer = nil
        }
    }

    /// `iss_init` is idempotent: once its event tap exists it returns true immediately.
    private static func startCoreIfPermitted() -> Bool {
        AccessibilityPermission.isGranted && iss_init()
    }

    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .spacePrevious) { [weak self] in
            self?.perform { iss_switch(ISSDirectionLeft) }
        }
        KeyboardShortcuts.onKeyDown(for: .spaceNext) { [weak self] in
            self?.perform { iss_switch(ISSDirectionRight) }
        }
        for number in 1 ... Self.maxSpaces {
            KeyboardShortcuts.onKeyDown(for: .switchToSpace(number)) { [weak self] in
                self?.perform { iss_switch_to_index(UInt32(number - 1)) }
            }
        }
    }

    /// Posting the synthetic swipe needs Accessibility. Beeps when there's no space that way.
    private func perform(_ switchSpace: () -> Bool) {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.prompt()
            return
        }
        _ = iss_init() // Starts the core's event tap if the permission arrived since launch.
        if !switchSpace() { NSSound.beep() }
    }

    // MARK: macOS shortcut clashes

    /// Space shortcuts that macOS's own (enabled) keyboard shortcuts would swallow.
    func systemShortcutClashes() -> [SystemShortcuts.Clash] {
        let shortcuts = KeyboardShortcuts.Name.spaceShortcuts.compactMap { KeyboardShortcuts.getShortcut(for: $0) }
        return SystemShortcuts.clashes(with: shortcuts)
    }

    func turnOffSystemShortcuts(_ clashes: [SystemShortcuts.Clash]) {
        SystemShortcuts.disable(clashes)
        // Register our hotkeys afresh now that macOS no longer claims those keys.
        KeyboardShortcuts.disable(KeyboardShortcuts.Name.spaceShortcuts)
        KeyboardShortcuts.enable(KeyboardShortcuts.Name.spaceShortcuts)
    }
}
