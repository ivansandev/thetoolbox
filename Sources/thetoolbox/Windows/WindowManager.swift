import AppKit
import ApplicationServices
import KeyboardShortcuts

/// Moves and resizes the focused window of the frontmost app via the Accessibility API, and
/// owns the user's custom sizes plus all global-shortcut registrations.
/// Direction to push a window across displays (ordered left-to-right by screen origin).
enum ScreenDirection { case left, right }

final class WindowManager: ObservableObject {
    @Published private(set) var customSizes: [CustomSize]

    private let prefs = Preferences.shared
    private var lastActiveApp: NSRunningApplication?
    private var registeredCustomHandlers: Set<UUID> = []

    init() {
        customSizes = prefs.loadCustomSizes()
        seedDefaultsIfNeeded()
        migrateCenterFitDefault()
        trackActiveApp()
        registerBuiltInShortcuts()
        for size in customSizes { registerCustomHandler(for: size.id) }
    }

    /// On first launch only, install sensible default shortcuts (⌃⌥ + arrows / return / C) and
    /// a "Center 60% × 80%" custom size. Never clobbers a shortcut the user already set, and
    /// won't duplicate the custom size.
    private func seedDefaultsIfNeeded() {
        // Bumped to v3 to seed the new "Move to Left/Right Display" defaults on existing installs
        // too. The per-name nil check below means no shortcut the user already set is touched.
        let flag = "didSeedWindowDefaults.v3"
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
            (.windowCenterFit, .init(.return, modifiers: [.control, .option, .command])),
            (.windowDisplayLeft, .init(.leftArrow, modifiers: [.control, .option, .command])),
            (.windowDisplayRight, .init(.rightArrow, modifiers: [.control, .option, .command])),
        ]
        for (name, shortcut) in builtinDefaults where KeyboardShortcuts.getShortcut(for: name) == nil {
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        }

        if customSizes.isEmpty {
            let size = CustomSize(name: "Center 60% × 80%", widthFraction: 0.6, heightFraction: 0.8)
            customSizes.append(size)
            prefs.saveCustomSizes(customSizes)
        }
    }

    /// One-time: "Center" was briefly seeded with ⌃⌥⇧C; switch installs that still carry that
    /// auto-seeded value to the intended default, ⌃⌥⌘↩. Leaves a deliberate user choice alone.
    private func migrateCenterFitDefault() {
        let key = "migratedCenterFitDefault.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let autoSeeded = KeyboardShortcuts.Shortcut(.c, modifiers: [.control, .option, .shift])
        if KeyboardShortcuts.getShortcut(for: .windowCenterFit) == autoSeeded {
            KeyboardShortcuts.setShortcut(.init(.return, modifiers: [.control, .option, .command]),
                                          for: .windowCenterFit)
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

    /// Centers the window at a screen-appropriate size: ~90% of the visible frame, capped to a
    /// comfortable maximum. Small/normal screens (built-in, 1080p) end up almost maximized; large,
    /// high-resolution screens (4K-with-room, 5K/6K) get a sensible centered window instead of a
    /// sprawling one. Sizing is in points, i.e. the screen's usable space.
    func centerFit() {
        let maxWidth: CGFloat = 1920
        let maxHeight: CGFloat = 1200
        applyFrame { visibleFrame, _ in
            let width = min(visibleFrame.width * 0.9, maxWidth)
            let height = min(visibleFrame.height * 0.9, maxHeight)
            return CGRect(x: visibleFrame.minX + (visibleFrame.width - width) / 2,
                          y: visibleFrame.minY + (visibleFrame.height - height) / 2,
                          width: width, height: height)
        }
    }

    /// Resolves the focused window, figures out which screen it is on, and applies the target
    /// rect (computed in AppKit coordinates from that screen's visible frame).
    private func applyFrame(_ target: (_ visibleFrame: CGRect, _ currentSize: CGSize) -> CGRect) {
        guard let ctx = focusedWindow() else { return }
        let targetAppKit = target(ctx.screen.visibleFrame, ctx.appKitRect.size)
        Self.setFrame(ScreenGeometry.flipY(targetAppKit), for: ctx.window)
    }

    /// Moves the focused window to the adjacent display (wrapping around), keeping its position and
    /// size *relative* to the visible frame — so e.g. a left-half window stays a left-half window
    /// even if the two monitors differ in resolution. No-op with a single display.
    func moveToAdjacentDisplay(_ direction: ScreenDirection) {
        guard let ctx = focusedWindow() else { return }
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard screens.count > 1,
              let current = screens.firstIndex(of: ctx.screen) else { return }

        let n = screens.count
        let targetIndex = direction == .left ? (current - 1 + n) % n : (current + 1) % n
        let from = ctx.screen.visibleFrame
        let to = screens[targetIndex].visibleFrame

        // Express the window as fractions of the source visible frame, then re-apply on the target.
        let fracX = (ctx.appKitRect.minX - from.minX) / from.width
        let fracY = (ctx.appKitRect.minY - from.minY) / from.height
        let width = min(ctx.appKitRect.width / from.width, 1) * to.width
        let height = min(ctx.appKitRect.height / from.height, 1) * to.height
        // Clamp the origin so the window stays fully on the target screen.
        let x = min(max(to.minX + fracX * to.width, to.minX), to.maxX - width)
        let y = min(max(to.minY + fracY * to.height, to.minY), to.maxY - height)

        Self.setFrame(ScreenGeometry.flipY(CGRect(x: x, y: y, width: width, height: height)),
                      for: ctx.window)
    }

    /// Shared resolution of the frontmost app's focused AX window: handles the Accessibility gate,
    /// reads the window's frame in AppKit coordinates, and identifies the screen it is on.
    private func focusedWindow() -> (window: AXUIElement, appKitRect: CGRect, screen: NSScreen)? {
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.prompt()
            return nil
        }
        guard let app = targetApp() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return nil }
        let window = windowRef as! AXUIElement

        guard let currentAX = Self.frame(of: window) else { return nil }
        let appKitRect = ScreenGeometry.flipY(currentAX)
        guard let screen = ScreenGeometry.screen(forAppKitRect: appKitRect) ?? NSScreen.main else { return nil }
        return (window, appKitRect, screen)
    }

    // MARK: Custom sizes

    func addCustomSize(name: String, widthFraction: Double, heightFraction: Double,
                       xFraction: Double, yFraction: Double) {
        let size = CustomSize(name: name, widthFraction: widthFraction, heightFraction: heightFraction,
                              xFraction: xFraction, yFraction: yFraction)
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
        KeyboardShortcuts.onKeyDown(for: .windowCenterFit) { [weak self] in self?.centerFit() }
        KeyboardShortcuts.onKeyDown(for: .windowDisplayLeft) { [weak self] in self?.moveToAdjacentDisplay(.left) }
        KeyboardShortcuts.onKeyDown(for: .windowDisplayRight) { [weak self] in self?.moveToAdjacentDisplay(.right) }
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

    // MARK: Shortcut conflicts

    /// All shortcut names this app manages (built-in actions + one per custom size).
    var allShortcutNames: [KeyboardShortcuts.Name] {
        let builtins: [KeyboardShortcuts.Name] = [
            .windowLeftHalf, .windowRightHalf, .windowTopHalf,
            .windowBottomHalf, .windowMaximize, .windowCenter, .windowCenterFit,
            .windowDisplayLeft, .windowDisplayRight,
        ]
        return builtins + customSizes.map { Self.shortcutName(for: $0.id) }
    }

    /// When `name` is assigned a shortcut, clear that same combo from any of our other actions so
    /// each shortcut maps to exactly one action (most recently assigned wins). The cleared
    /// recorders update themselves via KeyboardShortcuts' change notification.
    func resolveShortcutConflict(preferring name: KeyboardShortcuts.Name) {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return }
        for other in allShortcutNames where other != name {
            if KeyboardShortcuts.getShortcut(for: other) == shortcut {
                KeyboardShortcuts.setShortcut(nil, for: other)
            }
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
