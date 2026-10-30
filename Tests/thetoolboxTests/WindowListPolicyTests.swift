import CoreGraphics
import XCTest
@testable import thetoolbox

final class WindowListPolicyTests: XCTestCase {
    private let size = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func window(
        _ id: CGWindowID,
        spaces: Set<UInt64> = [1],
        minimized: Bool = false,
        hidden: Bool = false,
        fullscreen: Bool = false,
        accessible: Bool = true
    ) -> WindowRecord {
        WindowRecord(
            id: id, pid: 100, appName: "App", title: "Window \(id)", bounds: size,
            isMinimized: minimized, isFullscreen: fullscreen, isAppHidden: hidden,
            spaceIDs: spaces, isAccessible: accessible
        )
    }

    private func ids(
        _ windows: [WindowRecord],
        current: Set<UInt64>? = [1],
        currentIsFullscreen: Bool = false,
        options: WindowListOptions = WindowListOptions()
    ) -> [CGWindowID] {
        WindowListPolicy.list(
            windows, currentSpaceIDs: current, currentIsFullscreen: currentIsFullscreen, options: options
        ).map(\.id)
    }

    func testKeepsFrontToBackOrder() {
        XCTAssertEqual(ids([window(3), window(1), window(2)]), [3, 1, 2])
    }

    func testCurrentDesktopScopeDropsOtherDesktops() {
        let windows = [window(1), window(2, spaces: [2], accessible: false), window(3, spaces: [1, 2])]
        XCTAssertEqual(ids(windows), [1, 3])
    }

    func testCurrentDesktopsOfEveryDisplayCount() {
        XCTAssertEqual(ids([window(1), window(2, spaces: [5])], current: [1, 5]), [1, 2])
    }

    func testAllDesktopsScopeKeepsOtherDesktops() {
        let windows = [window(1), window(2, spaces: [2], accessible: false)]
        XCTAssertEqual(ids(windows, options: WindowListOptions(scope: .all)), [1, 2])
    }

    func testFromAFullscreenDesktopEveryDesktopIsListed() {
        // In a fullscreen app (desktop 9), the regular desktop you came from is another desktop.
        let windows = [window(1, spaces: [9], fullscreen: true), window(2, spaces: [1], accessible: false)]
        XCTAssertEqual(ids(windows, current: [9], currentIsFullscreen: true), [1, 2])
        XCTAssertEqual(ids(windows, current: [9]), [1])
    }

    func testDesktopScopeRule() {
        func inScope(_ window: WindowRecord, _ scope: DesktopScope) -> Bool {
            WindowListPolicy.isInScope(window, currentSpaceIDs: [1], scope: scope)
        }
        XCTAssertTrue(inScope(window(1), .current))
        XCTAssertTrue(inScope(window(2, spaces: []), .current), "unknown membership")
        XCTAssertTrue(inScope(window(3, spaces: [9], fullscreen: true), .current))
        XCTAssertFalse(inScope(window(4, spaces: [2]), .current))
        XCTAssertTrue(inScope(window(4, spaces: [2]), .all))
    }

    func testFullscreenWindowsAreAlwaysListed() {
        let windows = [window(1), window(2, spaces: [9], fullscreen: true, accessible: false)]
        XCTAssertEqual(ids(windows), [1, 2])
    }

    func testMinimizedThenHiddenGoLast() {
        let windows = [window(1, minimized: true), window(2, hidden: true), window(3)]
        XCTAssertEqual(ids(windows), [3, 1, 2])
    }

    func testMinimizedAndHiddenCanBeLeftOut() {
        let windows = [window(1, minimized: true), window(2, hidden: true), window(3)]
        let options = WindowListOptions(includeMinimized: false, includeHidden: false)
        XCTAssertEqual(ids(windows, options: options), [3])
    }

    func testInaccessibleWindowOnTheCurrentDesktopIsDropped() {
        XCTAssertEqual(ids([window(1), window(2, accessible: false)]), [1])
    }

    func testUnknownDesktopMembershipCountsAsCurrent() {
        XCTAssertEqual(ids([window(1, spaces: [])]), [1])
    }

    func testWithoutDesktopInfoOnlyAccessibleWindowsAreKept() {
        let windows = [window(1, spaces: [7]), window(2, spaces: [8], accessible: false)]
        XCTAssertEqual(ids(windows, current: nil), [1])
    }

    func testCandidateFilter() {
        func candidate(layer: Int = 0, alpha: Double = 1, bounds: CGRect? = nil, owner: pid_t = 10, regular: Bool = true) -> Bool {
            WindowListPolicy.isCandidate(
                layer: layer, alpha: alpha, bounds: bounds ?? size,
                ownerPID: owner, ownPID: 1, ownerIsRegularApp: regular
            )
        }
        XCTAssertTrue(candidate())
        XCTAssertFalse(candidate(layer: 25), "menu bar / status layers")
        XCTAssertFalse(candidate(alpha: 0), "invisible surfaces")
        XCTAssertFalse(candidate(bounds: CGRect(x: 0, y: 0, width: 40, height: 300)), "too narrow")
        XCTAssertFalse(candidate(owner: 1), "thetoolbox's own windows")
        XCTAssertFalse(candidate(regular: false), "agents and background apps")
    }

    func testDisplayTitle() {
        func record(title: String) -> WindowRecord {
            WindowRecord(id: 1, pid: 1, appName: "Mail", title: title, bounds: size)
        }
        XCTAssertEqual(record(title: "Inbox").displayTitle, "Mail — Inbox")
        XCTAssertEqual(record(title: "").displayTitle, "Mail")
        XCTAssertEqual(record(title: "Mail").displayTitle, "Mail")
    }
}
