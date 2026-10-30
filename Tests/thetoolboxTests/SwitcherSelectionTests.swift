import CoreGraphics
import XCTest
@testable import thetoolbox

final class SwitcherSelectionTests: XCTestCase {
    // MARK: Selection

    func testForwardStartsOnThePreviousWindow() {
        XCTAssertEqual(SwitcherSelection(count: 5, columns: 5, forward: true).index, 1)
    }

    func testBackwardStartsOnTheLastWindow() {
        XCTAssertEqual(SwitcherSelection(count: 5, columns: 5, forward: false).index, 4)
    }

    func testForwardStartsOnTheFirstWindowWhenItIsNotTheActiveApps() {
        // e.g. thetoolbox's Settings or a windowless Finder is active: the top window is the one
        // you came from.
        XCTAssertEqual(SwitcherSelection(count: 5, columns: 5, forward: true, firstIsActive: false).index, 0)
    }

    func testBackwardIgnoresWhetherTheFirstWindowIsActive() {
        XCTAssertEqual(SwitcherSelection(count: 5, columns: 5, forward: false, firstIsActive: false).index, 4)
    }

    func testASingleWindowIsSelectedEitherWay() {
        XCTAssertEqual(SwitcherSelection(count: 1, columns: 1, forward: true).index, 0)
        XCTAssertEqual(SwitcherSelection(count: 1, columns: 1, forward: false).index, 0)
    }

    func testAnEmptyListStaysAtZero() {
        var selection = SwitcherSelection(count: 0, columns: 1, forward: true)
        selection.next()
        selection.move(.down)
        XCTAssertEqual(selection.index, 0)
    }

    func testNextAndPreviousWrap() {
        var selection = SwitcherSelection(count: 3, columns: 3, forward: true)
        selection.next()
        XCTAssertEqual(selection.index, 2)
        selection.next()
        XCTAssertEqual(selection.index, 0)
        selection.previous()
        XCTAssertEqual(selection.index, 2)
    }

    func testLeftAndRightAreThePreviousAndNextWindow() {
        var selection = SwitcherSelection(count: 3, columns: 3, forward: true)
        selection.move(.right)
        XCTAssertEqual(selection.index, 2)
        selection.move(.left)
        XCTAssertEqual(selection.index, 1)
    }

    func testDownKeepsTheColumnAndClampsAShortLastRow() {
        // 7 tiles in 3 columns: rows [0 1 2] [3 4 5] [6]
        var selection = SwitcherSelection(count: 7, columns: 3, forward: true)
        selection.select(2)
        selection.move(.down)
        XCTAssertEqual(selection.index, 5)
        selection.move(.down)
        XCTAssertEqual(selection.index, 6, "no tile below column 2, so the last tile")
        selection.move(.down)
        XCTAssertEqual(selection.index, 0, "wraps to the top row")
    }

    func testUpWrapsToTheLastRow() {
        var selection = SwitcherSelection(count: 7, columns: 3, forward: true)
        selection.select(0)
        selection.move(.up)
        XCTAssertEqual(selection.index, 6)
        selection.select(2)
        selection.move(.up)
        XCTAssertEqual(selection.index, 6)
    }

    func testUpAndDownDoNothingInASingleRow() {
        var selection = SwitcherSelection(count: 3, columns: 3, forward: true)
        selection.move(.up)
        selection.move(.down)
        XCTAssertEqual(selection.index, 1)
    }

    func testSelectIgnoresOutOfRangeIndexes() {
        var selection = SwitcherSelection(count: 3, columns: 3, forward: true)
        selection.select(9)
        selection.select(-1)
        XCTAssertEqual(selection.index, 1)
    }

    // MARK: Layout

    private let layout = SwitcherLayout(tileWidth: 200)

    func testTileHeightFollowsTheAspectRatio() {
        XCTAssertEqual(layout.tileSize, CGSize(width: 200, height: 150))
    }

    func testColumnsFitTheAvailableWidth() {
        // (1000 - 40 + 10) / 210 = 4.62 → 4 per row
        XCTAssertEqual(layout.columns(count: 3, availableWidth: 1000), 3)
        XCTAssertEqual(layout.columns(count: 10, availableWidth: 1000), 4)
        XCTAssertEqual(layout.columns(count: 10, availableWidth: 100), 1)
        XCTAssertEqual(layout.columns(count: 0, availableWidth: 1000), 1)
    }

    func testMaxRowsFitTheAvailableHeight() {
        // (1000 - 40 - 12 - 20 + 10) / 160 = 5.86 → 5
        XCTAssertEqual(layout.maxRows(availableHeight: 1000), 5)
        XCTAssertEqual(layout.maxRows(availableHeight: 100), 1)
    }

    func testPanelSize() {
        XCTAssertEqual(layout.panelSize(count: 3, columns: 3), CGSize(width: 660, height: 222))
        XCTAssertEqual(layout.panelSize(count: 5, columns: 3), CGSize(width: 660, height: 382))
    }

    func testTileIndexHitTesting() {
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            layout.tileIndex(at: CGPoint(x: x, y: y), columns: 3, count: 4)
        }
        XCTAssertEqual(hit(21, 21), 0)
        XCTAssertNil(hit(225, 21), "gap between tiles")
        XCTAssertEqual(hit(231, 21), 1)
        XCTAssertEqual(hit(21, 181), 3)
        XCTAssertNil(hit(231, 181), "past the last tile")
        XCTAssertNil(hit(10, 21), "inside the padding")
        XCTAssertNil(hit(645, 21), "past the last column")
    }

    // MARK: Sizing to the screen

    private let laptop = CGSize(width: 1210, height: 756) // 80% of a 1512-point-wide screen

    func testTilesScaleWithTheScreenWidth() {
        // 1512 × 0.18 = 272
        let fitted = SwitcherLayout.fitting(count: 3, screenWidth: 1512, available: laptop)
        XCTAssertEqual(fitted.tileSize, CGSize(width: 272, height: 204))
    }

    func testTileWidthIsClamped() {
        let huge = SwitcherLayout.fitting(count: 1, screenWidth: 4000, available: CGSize(width: 3200, height: 1800))
        XCTAssertEqual(huge.tileSize.width, SwitcherLayout.maxTileWidth)
        let tiny = SwitcherLayout.fitting(count: 1, screenWidth: 500, available: CGSize(width: 400, height: 300))
        XCTAssertEqual(tiny.tileSize.width, SwitcherLayout.minTileWidth)
    }

    func testTilesShrinkUntilEveryWindowFits() {
        let fitted = SwitcherLayout.fitting(count: 30, screenWidth: 1512, available: laptop)
        XCTAssertLessThan(fitted.tileSize.width, 272)
        let capacity = fitted.columns(count: 30, availableWidth: laptop.width)
            * fitted.maxRows(availableHeight: laptop.height)
        XCTAssertGreaterThanOrEqual(capacity, 30)
    }

    func testTilesNeverShrinkBelowTheMinimum() {
        let fitted = SwitcherLayout.fitting(count: 500, screenWidth: 1512, available: laptop)
        XCTAssertEqual(fitted.tileSize.width, SwitcherLayout.minTileWidth)
    }

    func testIconsGrowWithTheTile() {
        let fitted = SwitcherLayout.fitting(count: 3, screenWidth: 1512, available: laptop)
        XCTAssertEqual(fitted.badgeIconSize, 54)
        XCTAssertEqual(SwitcherLayout(tileWidth: 160).badgeIconSize, 36)
        XCTAssertEqual(SwitcherLayout(tileWidth: 380).badgeIconSize, 72)
    }
}
