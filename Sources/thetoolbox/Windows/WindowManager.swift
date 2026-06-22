import AppKit
import ApplicationServices
import KeyboardShortcuts

/// Moves and resizes the focused window of the frontmost app via the Accessibility API, and
/// owns the user's custom sizes plus all global-shortcut registrations.
final class WindowManager: ObservableObject {
    @Published private(set) var customSizes: [CustomSize]

    private let prefs = Preferences.shared
    private var lastActiveApp: NSRunningApplication?
    private var registeredCustomHandlers: Set<UUID> = []

    init() {
        customSizes = prefs.loadCustomSizes()
        seedDefaultsIfNeeded()
        trackActiveApp()
        registerBuiltInShortcuts()
        for size in customSizes { registerCustomHandler(for: size.id) }
    }

    /// On first launch only, install sensible default shortcuts (⌃⌥ + arrows / return / C) and
    /// a "Center 60% × 80%" custom size. Never clobbers a shortcut the user already set, and
    /// won't duplicate the custom size.
    private func seedDefaultsIfNeeded() {
        let flag = "didSeedWindowDefaults.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        let controlOption: NSEvent.ModifierFlags = [.control, .option]
        let builtinDefaults: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
            (.windowLeftHalf, .init(.leftArrow, modifiers: controlOption)),
            (.windowRightHalf, .init(.rightArrow, modifiers: controlOption)),
            (.windowTopHalf, .init(.upArrow, modifiers: controlOption)),
            (.windowBottomHalf, .init(.downArrow, modifiers: controlOption)),
            (.windowMaximize, .init(.return, modifiers: controlOption)),
            (.windowCenter, .init(.c, modifiers: controlOption)),
        ]
        for (name, shortcut) in builtinDefaults where KeyboardShortcuts.getShortcut(for: name) == nil {
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        }

        if customSizes.isEmpty {
            let size = CustomSize(name: "Center 60% × 80%", widthFraction: 0.6, heightFraction: 0.8)
            customSizes.append(size)
            prefs.saveCustomSizes(customSizes)
            KeyboardShortcuts.setShortcut(
                .init(.return, modifiers: [.control, .option, .command]),
                for: Self.shortcutName(for: size.id)
            )
        }
    }

    // MARK: Target app

    /// We track the last non-self active app so window actions triggered from our menu (which
    /// briefly takes focus) still target the app the user was actually using. Global shortcuts
    /// keep the real frontmost app, so this only matters for menu clicks.
    private func trackActiveApp() {
        lastActiveApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastActiveApp = app
        }
    }

    private func targetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        return lastActiveApp
    }

    // MARK: Public actions

    func perform(_ action: WindowAction) {
        applyFrame { visibleFrame, _ in action.rect(in: visibleFrame) }
    }

    func apply(_ size: CustomSize) {
        applyFrame { visibleFrame, _ in size.rect(in: visibleFrame) }
    }

    func center() {
        applyFrame { visibleFrame, currentSize in
            CGRect(x: visibleFrame.minX + (visibleFrame.width - currentSize.width) / 2,
                   y: visibleFrame.minY + (visibleFrame.height - currentSize.height) / 2,
                   width: currentSize.width,
                   height: currentSize.height)
        }
    }

    /// Resolves the focused window, figures out which screen it is on, and applies the target
    /// rect (computed in AppKit coordinates from that screen's visible frame).
    private func applyFrame(_ target: (_ visibleFrame: CGRect, _ currentSize: CGSize) -> CGRect) {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.prompt()
            return
        }
        guard let app = targetApp() else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return }
        let window = windowRef as! AXUIElement

        guard let currentAX = Self.frame(of: window) else { return }
        let currentAppKit = ScreenGeometry.flipY(currentAX)
        let screen = ScreenGeometry.screen(forAppKitRect: currentAppKit) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let targetAppKit = target(visibleFrame, currentAppKit.size)
        Self.setFrame(ScreenGeometry.flipY(targetAppKit), for: window)
    }

    // MARK: Custom sizes

    func addCustomSize(name: String, widthFraction: Double, heightFraction: Double) {
        let size = CustomSize(name: name, widthFraction: widthFraction, heightFraction: heightFraction)
        customSizes.append(size)
        prefs.saveCustomSizes(customSizes)
        registerCustomHandler(for: size.id)
    }

    func removeCustomSize(_ size: CustomSize) {
        customSizes.removeAll { $0.id == size.id }
        KeyboardShortcuts.reset(Self.shortcutName(for: size.id))
        prefs.saveCustomSizes(customSizes)
    }

    static func shortcutName(for id: UUID) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("customwindow-\(id.uuidString)")
    }

    // MARK: Shortcut registration

    private func registerBuiltInShortcuts() {
        let bindings: [(KeyboardShortcuts.Name, WindowAction)] = [
            (.windowLeftHalf, .leftHalf),
            (.windowRightHalf, .rightHalf),
            (.windowTopHalf, .topHalf),
            (.windowBottomHalf, .bottomHalf),
            (.windowMaximize, .maximize),
        ]
        for (name, action) in bindings {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.perform(action) }
        }
        KeyboardShortcuts.onKeyDown(for: .windowCenter) { [weak self] in self?.center() }
    }

    /// Registers exactly one handler per custom size id. The handler looks the size up live, so
    /// it harmlessly no-ops if the size was later removed.
    private func registerCustomHandler(for id: UUID) {
        guard registeredCustomHandlers.insert(id).inserted else { return }
        KeyboardShortcuts.onKeyDown(for: Self.shortcutName(for: id)) { [weak self] in
            guard let self, let size = self.customSizes.first(where: { $0.id == id }) else { return }
            self.apply(size)
        }
    }

    // MARK: AX frame read/write

    static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func setFrame(_ rect: CGRect, for window: AXUIElement) {
        var position = rect.origin
        var size = rect.size
        // Set position, then size, then position again so a window's minimum-size clamping
        // can't leave it shifted off the intended spot.
        if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}
