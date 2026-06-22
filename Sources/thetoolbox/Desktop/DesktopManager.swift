import AppKit

/// Shows/hides desktop icons and desktop widgets. On modern macOS (Sonoma+/Tahoe) both are
/// managed by WindowManager, so we toggle its preferences and relaunch it to apply:
///   - icons   → `StandardHideDesktopIcons` (true hides desktop icons)
///   - widgets → `StandardHideWidgets`      (true hides desktop widgets)
///
/// Note: the legacy `com.apple.finder CreateDesktop` key is ignored on Tahoe, which is why the
/// first implementation did nothing for icons.
final class DesktopManager: ObservableObject {
    @Published var iconsVisible: Bool
    @Published var widgetsVisible: Bool

    private let domain = "com.apple.WindowManager"

    init() {
        let defaults = UserDefaults(suiteName: domain)
        iconsVisible = !((defaults?.object(forKey: "StandardHideDesktopIcons") as? Bool) ?? false)
        widgetsVisible = !((defaults?.object(forKey: "StandardHideWidgets") as? Bool) ?? false)
        #if DEBUG
        NSLog("thetoolbox desktop state: icons=\(iconsVisible) widgets=\(widgetsVisible)")
        #endif
    }

    func setIconsVisible(_ visible: Bool) {
        iconsVisible = visible
        apply(key: "StandardHideDesktopIcons", hide: !visible)
    }

    func setWidgetsVisible(_ visible: Bool) {
        widgetsVisible = visible
        apply(key: "StandardHideWidgets", hide: !visible)
    }

    /// Writes the preference and *then* relaunches WindowManager. The write must commit before
    /// the relaunch (the original bug was firing `killall` without waiting), so this runs off the
    /// main thread and blocks on each step in order.
    private func apply(key: String, hide: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.run("/usr/bin/defaults", ["write", self.domain, key, "-bool", hide ? "true" : "false"])
            self.run("/usr/bin/killall", ["WindowManager"])
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
            NSLog("thetoolbox desktop: \(path) \(args) failed: \(error)")
        }
    }
}
