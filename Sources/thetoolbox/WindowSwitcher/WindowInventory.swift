import AppKit
import ApplicationServices

/// The listed windows at one moment, plus the Accessibility element of each window that has
/// one (used to unminimize and raise it).
struct WindowSnapshot {
    let windows: [WindowRecord]
    let elements: [CGWindowID: AXUIElement]

    static let empty = WindowSnapshot(windows: [], elements: [:])
}

/// Builds the window list on demand, on the main thread. It takes a few milliseconds, plus at
/// most `axTimeout` for each app that doesn't answer Accessibility.
final class WindowInventory {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32

    private static let axTimeout: Float = 0.25

    private let spaces = SpacesAPI.shared
    /// Maps an Accessibility window to its WindowServer ID.
    private let getWindow = PrivateSymbols.function("_AXUIElementGetWindow", as: GetWindow.self)

    /// False when macOS lacks the call that ties Accessibility windows to window IDs; without it
    /// no window could be listed, so the switcher must stay off.
    var isAvailable: Bool { getWindow != nil }

    func snapshot(options: WindowListOptions) -> WindowSnapshot {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return .empty }

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = app
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // 1. Candidate windows from the WindowServer, front to back.
        var candidates: [CandidateWindow] = []
        for entry in info {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard WindowListPolicy.isCandidate(
                layer: layer, alpha: alpha, bounds: bounds,
                ownerPID: pid, ownPID: ownPID, ownerIsRegularApp: apps[pid] != nil
            ) else { continue }
            candidates.append(CandidateWindow(id: id, pid: pid, bounds: bounds, name: entry[kCGWindowName as String] as? String))
        }

        // 2. Accessibility details, one app at a time. Apps that don't answer keep their CG data.
        var details: [CGWindowID: AXDetails] = [:]
        var unanswered: Set<pid_t> = []
        for pid in Set(candidates.map(\.pid)) {
            if let windows = accessibilityWindows(pid: pid) {
                details.merge(windows) { first, _ in first }
            } else {
                unanswered.insert(pid)
            }
        }

        // 3. Desktops, then the list rules.
        let desktops = spaces.desktops()
        var records: [WindowRecord] = []
        for candidate in candidates {
            guard let app = apps[candidate.pid] else { continue }
            let detail = details[candidate.id]
            let spaceIDs = desktops == nil ? [] : spaces.spaceIDs(of: candidate.id)
            let onFullscreenDesktop = desktops.map { !spaceIDs.isDisjoint(with: $0.fullscreen) } ?? false
            records.append(WindowRecord(
                id: candidate.id,
                pid: candidate.pid,
                appName: app.localizedName ?? "",
                title: detail?.title ?? candidate.name ?? "",
                bounds: candidate.bounds,
                isMinimized: detail?.isMinimized ?? false,
                isFullscreen: (detail?.isFullscreen ?? false) || onFullscreenDesktop,
                isAppHidden: app.isHidden,
                spaceIDs: spaceIDs,
                // When the app didn't answer, nothing says the window is a helper surface.
                isAccessible: detail != nil || unanswered.contains(candidate.pid)
            ))
        }
        let listed = WindowListPolicy.list(
            records, currentSpaceIDs: desktops?.current,
            currentIsFullscreen: desktops?.currentIsFullscreen ?? false, options: options
        )
        var elements: [CGWindowID: AXUIElement] = [:]
        for window in listed {
            if let element = details[window.id]?.element { elements[window.id] = element }
        }
        return WindowSnapshot(windows: listed, elements: elements)
    }

    // MARK: Accessibility

    private struct CandidateWindow {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        /// Only filled in when Screen Recording is granted.
        let name: String?
    }

    private struct AXDetails {
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
        let isFullscreen: Bool
    }

    /// The app's Accessibility windows by window ID, or nil when it didn't answer the windows
    /// list (any error, including a timeout).
    private func accessibilityWindows(pid: pid_t) -> [CGWindowID: AXDetails]? {
        guard let getWindow else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        guard let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var result: [CGWindowID: AXDetails] = [:]
        for window in windows {
            AXUIElementSetMessagingTimeout(window, Self.axTimeout)
            var id: CGWindowID = 0
            guard getWindow(window, &id) == AXError.success.rawValue, id != 0 else { continue }
            result[id] = AXDetails(
                element: window,
                title: Self.attribute(window, kAXTitleAttribute) as? String ?? "",
                isMinimized: Self.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                isFullscreen: Self.attribute(window, "AXFullScreen") as? Bool ?? false
            )
        }
        return result
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
