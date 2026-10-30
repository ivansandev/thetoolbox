import AppKit
import KeyboardShortcuts

extension SwitcherTrigger {
    /// Nil when the recorded shortcut has no ⌘, ⌥ or ⌃.
    init?(_ shortcut: KeyboardShortcuts.Shortcut) {
        var modifiers: SwitcherModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        self.init(keyCode: UInt16(truncatingIfNeeded: shortcut.carbonKeyCode), modifiers: modifiers)
    }
}

/// The ⌘Tab window switcher. A key press takes a window snapshot right away; the panel appears
/// only if the shortcut is still held after `panelDelay`, so a quick ⌘Tab just flips to the
/// previous window. Main thread only.
final class WindowSwitcher: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            prefs.windowSwitcherEnabled = isEnabled
            applyState()
        }
    }

    @Published var scope: DesktopScope {
        didSet { prefs.windowSwitcherScope = scope }
    }

    @Published var includeMinimized: Bool {
        didSet { prefs.windowSwitcherIncludeMinimized = includeMinimized }
    }

    @Published var includeHidden: Bool {
        didSet { prefs.windowSwitcherIncludeHidden = includeHidden }
    }

    /// How long the shortcut must stay held before the panel appears.
    static let panelDelay: TimeInterval = 0.12
    /// Share of the screen's visible area the panel may use.
    static let screenFraction: CGFloat = 0.8

    private struct Session {
        /// The key machine's ID for this session.
        let id: UInt64
        let snapshot: WindowSnapshot
        var selection: SwitcherSelection
        let screen: NSScreen
    }

    private let prefs = Preferences.shared
    private let keyTap = SwitcherKeyTap()
    private let inventory = WindowInventory()
    private let focuser = WindowFocuser()
    private let thumbnails = ThumbnailCapturer()
    /// Built on first use: creating its hosting view while SwiftUI is still creating the app's
    /// state objects (this manager is one) can trip a layout inside that update.
    private var createdPanel: SwitcherPanel?
    private var panel: SwitcherPanel {
        if let createdPanel { return createdPanel }
        let panel = SwitcherPanel()
        panel.onHover = { [weak self] index in self?.hover(index) }
        panel.onClick = { [weak self] index in self?.click(index) }
        createdPanel = panel
        return panel
    }
    private var session: Session?
    private var panelTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var startRetryTimer: Timer?

    init() {
        isEnabled = prefs.windowSwitcherEnabled
        scope = prefs.windowSwitcherScope
        includeMinimized = prefs.windowSwitcherIncludeMinimized
        includeHidden = prefs.windowSwitcherIncludeHidden

        keyTap.onCommand = { [weak self] command, id in self?.handle(command, id: id) }

        // Creating the name writes its default shortcut, which posts a defaults-changed
        // notification. Force that now, before observing, or the observer re-enters the lazy init.
        _ = KeyboardShortcuts.Name.windowSwitcher

        let center = NotificationCenter.default
        // The recorded shortcut lives in UserDefaults (KeyboardShortcuts); pick up changes.
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyState()
        }
        // While a shortcut recorder is focused, let it see ⌘Tab instead of the switcher.
        center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keyTap.setForwardsToRecorder(ShortcutRecording.isActive)
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keyTap.setForwardsToRecorder(false)
        }
        applyState()
    }

    // MARK: On/off

    /// Runs the tap only when the feature is on, a valid shortcut is set, the window list works
    /// and Accessibility is granted. Otherwise macOS's own ⌘Tab is untouched.
    private func applyState() {
        // Storing a shortcut registers a global hotkey even with no handler. The switcher's own
        // tap handles the key, so unregister it: it must not swallow the key while we're off.
        KeyboardShortcuts.disable(.windowSwitcher)
        let trigger = KeyboardShortcuts.getShortcut(for: .windowSwitcher).flatMap { SwitcherTrigger($0) }
        guard isEnabled, let trigger, inventory.isAvailable else {
            stopRetrying()
            turnOff()
            return
        }
        guard keyTap.start() else {
            turnOff()
            retryUntilPermitted()
            return
        }
        stopRetrying()
        keyTap.configure(enabled: true, trigger: trigger)
    }

    private func turnOff() {
        keyTap.configure(enabled: false, trigger: .standard)
        keyTap.stop()
        endSession(focus: false)
    }

    /// Starts working as soon as Accessibility is granted, like the space shortcuts do.
    private func retryUntilPermitted() {
        guard startRetryTimer == nil else { return }
        startRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.applyState()
        }
    }

    private func stopRetrying() {
        startRetryTimer?.invalidate()
        startRetryTimer = nil
    }

    // MARK: Session

    /// `id` is the key machine's session the command belongs to. Commands for a session that
    /// is no longer the current one arrived late and are dropped; only a begin starts a new one.
    private func handle(_ command: SwitcherCommand, id: UInt64) {
        if case let .begin(forward) = command {
            // Every begin is a new key session (its ID is new), so drop any leftover one.
            endSession(focus: false)
            begin(forward: forward, id: id)
            return
        }
        guard let session, session.id == id else { return }
        switch command {
        case .begin: break
        case .next: updateSelection { $0.next() }
        case .previous: updateSelection { $0.previous() }
        case let .move(direction): updateSelection { $0.move(direction) }
        case .commit: endSession(focus: true)
        case .cancel: endSession(focus: false)
        }
    }

    private func begin(forward: Bool, id: UInt64) {
        let options = WindowListOptions(scope: scope, includeMinimized: includeMinimized, includeHidden: includeHidden)
        let snapshot = inventory.snapshot(options: options)
        let mouse = NSEvent.mouseLocation
        guard !snapshot.windows.isEmpty,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else {
            keyTap.endSession(id: id)
            return
        }
        // Keep only as many windows as fit on screen; the least recent ones drop off.
        let visible = screen.visibleFrame
        let columns = SwitcherLayout.columns(count: snapshot.windows.count, availableWidth: visible.width * Self.screenFraction)
        let limit = columns * SwitcherLayout.maxRows(availableHeight: visible.height * Self.screenFraction)
        let windows = Array(snapshot.windows.prefix(limit))

        session = Session(
            id: id,
            snapshot: WindowSnapshot(windows: windows, elements: snapshot.elements),
            selection: SwitcherSelection(count: windows.count, columns: columns, forward: forward),
            screen: screen
        )
        panelTimer = Timer.scheduledTimer(withTimeInterval: Self.panelDelay, repeats: false) { [weak self] _ in
            self?.showPanel()
        }
    }

    private func showPanel() {
        guard let session else { return }
        let windows = session.snapshot.windows
        var icons: [pid_t: NSImage] = [:]
        var cached: [CGWindowID: CGImage] = [:]
        for window in windows {
            if icons[window.pid] == nil {
                icons[window.pid] = NSRunningApplication(processIdentifier: window.pid)?.icon
            }
            if let image = thumbnails.cached(window.id) { cached[window.id] = image }
        }
        panel.show(
            windows: windows,
            icons: icons,
            thumbnails: cached,
            selectedIndex: session.selection.index,
            columns: session.selection.columns,
            on: session.screen
        )
        let ids = windows.map(\.id)
        captureTask = Task { [thumbnails, panel] in
            await thumbnails.capture(ids, maxSize: SwitcherLayout.thumbnailSize) { id, image in
                panel.model.thumbnails[id] = image
            }
        }
    }

    private func updateSelection(_ change: (inout SwitcherSelection) -> Void) {
        guard var current = session else { return }
        change(&current.selection)
        session = current
        panel.model.selectedIndex = current.selection.index
    }

    private func hover(_ index: Int) {
        updateSelection { $0.select(index) }
    }

    private func click(_ index: Int) {
        guard session != nil else { return }
        updateSelection { $0.select(index) }
        endSession(focus: true)
    }

    /// Closes the panel and, when `focus` is true, switches to the selected window.
    private func endSession(focus: Bool) {
        panelTimer?.invalidate()
        panelTimer = nil
        captureTask?.cancel()
        captureTask = nil
        createdPanel?.hide()
        guard let ended = session else { return }
        session = nil
        keyTap.endSession(id: ended.id)
        guard focus, ended.snapshot.windows.indices.contains(ended.selection.index) else { return }
        let window = ended.snapshot.windows[ended.selection.index]
        focuser.focus(window, element: ended.snapshot.elements[window.id])
    }
}
