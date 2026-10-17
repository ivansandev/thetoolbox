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

    private enum Action {
        case previous, next, space(Int)
    }

    /// A key code plus ⌃⌥⇧⌘ flags, comparable between a recorded shortcut and a live key event.
    private struct KeyCombo: Hashable {
        let keyCode: Int
        let modifiers: UInt

        init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection([.control, .option, .shift, .command]).rawValue
        }
    }

    private let prefs = Preferences.shared
    private let keyTap = KeyDownTap()
    private var actions: [KeyCombo: Action] = [:]
    private var startRetryTimer: Timer?

    init() {
        instantSwipes = prefs.instantSpaceSwipes
        seedDefaultsIfNeeded()
        reloadShortcuts()
        keyTap.handler = { [weak self] event in self?.handleKeyDown(event) ?? false }
        start()
        // Lets real swipes pass through untouched while App Exposé is open.
        iss_set_overlay_detection_enabled(true)
        iss_set_swipe_override(instantSwipes)

        // Shortcuts are stored in UserDefaults by KeyboardShortcuts; re-read them when they change.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadShortcuts() }
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

    // MARK: Startup

    /// The key tap and the core's gesture tap both need Accessibility. Until it's granted, retry
    /// quietly so shortcuts and swipes start working as soon as it is.
    private func start() {
        guard !startIfPermitted() else { return }
        startRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.startIfPermitted() else { return }
            timer.invalidate()
            self.startRetryTimer = nil
        }
    }

    /// Both taps are idempotent: once running, starting again returns true immediately.
    private func startIfPermitted() -> Bool {
        guard AccessibilityPermission.isGranted else { return false }
        let keysStarted = keyTap.start()
        return iss_init() && keysStarted
    }

    // MARK: Shortcuts

    private func reloadShortcuts() {
        var table: [KeyCombo: Action] = [:]
        func add(_ name: KeyboardShortcuts.Name, _ action: Action) {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return }
            table[KeyCombo(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.modifiers)] = action
        }
        add(.spacePrevious, .previous)
        add(.spaceNext, .next)
        for number in 1 ... Self.maxSpaces {
            add(.switchToSpace(number), .space(number))
        }
        actions = table
    }

    /// Runs on the main thread for every key press, so it must stay a quick dictionary lookup.
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        // Let keys through while our own Settings window is in front, so its shortcut
        // recorders can capture combos that are already assigned.
        guard !NSApp.isActive else { return false }
        let combo = KeyCombo(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        )
        guard let action = actions[combo] else { return false }
        // Holding the keys down shouldn't keep switching; swallow the repeats.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        }
        return true
    }

    /// Posting the synthetic swipe needs Accessibility. Beeps when there's no space that way.
    private func perform(_ action: Action) {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.prompt()
            return
        }
        let switched: Bool
        switch action {
        case .previous: switched = iss_switch(ISSDirectionLeft)
        case .next: switched = iss_switch(ISSDirectionRight)
        case let .space(number): switched = iss_switch_to_index(UInt32(number - 1))
        }
        if !switched { NSSound.beep() }
    }
}
