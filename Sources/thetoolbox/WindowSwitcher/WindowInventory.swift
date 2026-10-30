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
/// most about `axTimeout` for each app that stops answering Accessibility: an app is not asked
/// again after its first timeout.
final class WindowInventory {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32

    private static let axTimeout: Float = 0.25
    /// Read together, in one round trip per window.
    private static let detailAttributes = [kAXTitleAttribute, kAXMinimizedAttribute, "AXFullScreen"] as CFArray

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

        // 2. Desktops, and a record of each candidate from WindowServer data alone.
        let desktops = spaces.desktops()
        let currentIsFullscreen = desktops?.currentIsFullscreen ?? false
        let scope = WindowListPolicy.effectiveScope(options.scope, currentIsFullscreen: currentIsFullscreen)
        var records: [WindowRecord] = []
        for candidate in candidates {
            guard let app = apps[candidate.pid] else { continue }
            let spaceIDs = desktops == nil ? [] : spaces.spaceIDs(of: candidate.id)
            records.append(WindowRecord(
                id: candidate.id,
                pid: candidate.pid,
                appName: app.localizedName ?? "",
                title: candidate.name ?? "",
                bounds: candidate.bounds,
                isFullscreen: desktops.map { !spaceIDs.isDisjoint(with: $0.fullscreen) } ?? false,
                isAppHidden: app.isHidden,
                spaceIDs: spaceIDs,
                isAccessible: false
            ))
        }

        // 3. Accessibility details, one app at a time, only for apps with a window in scope (the
        // others' windows can't be listed). Windows an app didn't get to answer keep their CG data.
        let askedPIDs = Set(records.filter {
            WindowListPolicy.isInScope($0, currentSpaceIDs: desktops?.current, scope: scope)
        }.map(\.pid))
        var details: [CGWindowID: AXDetails] = [:]
        var unanswered: Set<pid_t> = []
        for pid in askedPIDs {
            if let answer = accessibilityWindows(pid: pid) {
                details.merge(answer.windows) { first, _ in first }
                if answer.stalled { unanswered.insert(pid) }
            } else {
                unanswered.insert(pid)
            }
        }
        for index in records.indices {
            let id = records[index].id
            if let detail = details[id] {
                records[index].title = detail.title
                records[index].isMinimized = detail.isMinimized
                records[index].isFullscreen = records[index].isFullscreen || detail.isFullscreen
            }
            // When the app didn't answer, nothing says the window is a helper surface.
            records[index].isAccessible = details[id] != nil || unanswered.contains(records[index].pid)
        }

        // 4. The list rules.
        let listed = WindowListPolicy.list(
            records, currentSpaceIDs: desktops?.current,
            currentIsFullscreen: currentIsFullscreen, options: options
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
    /// list (any error, including a timeout). `stalled` is true when it stopped answering part
    /// way through: it isn't asked anything more, and the windows read so far are kept.
    private func accessibilityWindows(pid: pid_t) -> (windows: [CGWindowID: AXDetails], stalled: Bool)? {
        guard let getWindow else { return ([:], false) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement] else { return nil }
        var result: [CGWindowID: AXDetails] = [:]
        for window in windows {
            AXUIElementSetMessagingTimeout(window, Self.axTimeout)
            var id: CGWindowID = 0
            let idError = getWindow(window, &id)
            if idError == AXError.cannotComplete.rawValue { return (result, true) }
            guard idError == AXError.success.rawValue, id != 0 else { continue }
            // Without options, an attribute the window lacks comes back as an error value in its
            // slot and the call still succeeds.
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(window, Self.detailAttributes, [], &values)
            if error == .cannotComplete { return (result, true) }
            let read = error == .success ? (values as? [Any]) ?? [] : []
            func value<T>(_ index: Int) -> T? { index < read.count ? read[index] as? T : nil }
            result[id] = AXDetails(
                element: window,
                title: value(0) ?? "",
                isMinimized: value(1) ?? false,
                isFullscreen: value(2) ?? false
            )
        }
        return (result, false)
    }
}
