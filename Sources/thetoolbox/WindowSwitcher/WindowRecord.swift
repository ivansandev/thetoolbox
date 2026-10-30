import CoreGraphics

/// One window as the switcher sees it.
struct WindowRecord: Equatable, Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    var title: String
    let bounds: CGRect
    var isMinimized = false
    var isFullscreen = false
    var isAppHidden = false
    /// Desktops (spaces) the window is on. Empty when unknown.
    var spaceIDs: Set<UInt64> = []
    /// Whether Accessibility listed this window. It lists every real window on the current
    /// desktop but usually not windows on other desktops.
    var isAccessible = true

    /// "App — Title", or just the app name when the title is empty or repeats it.
    var displayTitle: String {
        title.isEmpty || title == appName ? appName : "\(appName) — \(title)"
    }
}

enum DesktopScope: String, CaseIterable {
    case current, all
}

struct WindowListOptions: Equatable {
    var scope: DesktopScope = .current
    var includeMinimized = true
    var includeHidden = true
}

/// The switcher's rules for which windows to list, and in what order.
enum WindowListPolicy {
    static let minimumSize: CGFloat = 50

    /// Raw CGWindowList filter: a normal-layer, visible, reasonably sized window of another
    /// regular app.
    static func isCandidate(
        layer: Int, alpha: Double, bounds: CGRect,
        ownerPID: pid_t, ownPID: pid_t, ownerIsRegularApp: Bool
    ) -> Bool {
        layer == 0 && alpha > 0
            && bounds.width >= minimumSize && bounds.height >= minimumSize
            && ownerPID != ownPID && ownerIsRegularApp
    }

    /// `windows` must be front-to-back, which is most-recently-used first. Visible windows keep
    /// that order, then minimized windows, then windows of hidden apps. `currentSpaceIDs` holds
    /// every display's current desktop, or nil when desktop info is unavailable.
    /// `currentIsFullscreen` is true when one of those is a fullscreen app's desktop.
    static func list(
        _ windows: [WindowRecord], currentSpaceIDs: Set<UInt64>?, currentIsFullscreen: Bool = false,
        options: WindowListOptions
    ) -> [WindowRecord] {
        let scope = effectiveScope(options.scope, currentIsFullscreen: currentIsFullscreen)
        var visible: [WindowRecord] = []
        var minimized: [WindowRecord] = []
        var hidden: [WindowRecord] = []
        for window in windows {
            let onCurrent = isOnCurrentDesktop(window, currentSpaceIDs)
            // On the current desktop, anything Accessibility doesn't list is a helper surface.
            guard window.isAccessible || !onCurrent else { continue }
            guard scope == .all || onCurrent || window.isFullscreen else { continue }
            if window.isAppHidden {
                if options.includeHidden { hidden.append(window) }
            } else if window.isMinimized {
                if options.includeMinimized { minimized.append(window) }
            } else {
                visible.append(window)
            }
        }
        return visible + minimized + hidden
    }

    /// From a fullscreen app's desktop, the windows you came from are on another desktop, so
    /// "Current desktop" lists every desktop.
    static func effectiveScope(_ scope: DesktopScope, currentIsFullscreen: Bool) -> DesktopScope {
        currentIsFullscreen ? .all : scope
    }

    /// Unknown membership, or no desktop info at all, counts as the current desktop.
    static func isOnCurrentDesktop(_ window: WindowRecord, _ currentSpaceIDs: Set<UInt64>?) -> Bool {
        guard let currentSpaceIDs, !window.spaceIDs.isEmpty else { return true }
        return !window.spaceIDs.isDisjoint(with: currentSpaceIDs)
    }
}
