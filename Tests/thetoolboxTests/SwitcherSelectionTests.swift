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

    func testColumnsFitTheAvailableWidth() {
        // (1000 - 32 + 8) / 208 = 4.69 → 4 per row
        XCTAssertEqual(SwitcherLayout.columns(count: 3, availableWidth: 1000), 3)
        XCTAssertEqual(SwitcherLayout.columns(count: 10, availableWidth: 1000), 4)
        XCTAssertEqual(SwitcherLayout.columns(count: 10, availableWidth: 100), 1)
        XCTAssertEqual(SwitcherLayout.columns(count: 0, availableWidth: 1000), 1)
    }

    func testMaxRowsFitTheAvailableHeight() {
        // (1000 - 32 - 12 - 18 + 8) / 158 = 5.99 → 5
        XCTAssertEqual(SwitcherLayout.maxRows(availableHeight: 1000), 5)
        XCTAssertEqual(SwitcherLayout.maxRows(availableHeight: 100), 1)
    }

    func testPanelSize() {
        XCTAssertEqual(SwitcherLayout.panelSize(count: 3, columns: 3), CGSize(width: 648, height: 212))
        XCTAssertEqual(SwitcherLayout.panelSize(count: 5, columns: 3), CGSize(width: 648, height: 370))
    }

    func testTileIndexHitTesting() {
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            SwitcherLayout.tileIndex(at: CGPoint(x: x, y: y), columns: 3, count: 4)
        }
        XCTAssertEqual(hit(17, 17), 0)
        XCTAssertNil(hit(220, 17), "gap between tiles")
        XCTAssertEqual(hit(225, 17), 1)
        XCTAssertEqual(hit(17, 175), 3)
        XCTAssertNil(hit(225, 175), "past the last tile")
        XCTAssertNil(hit(10, 17), "inside the padding")
        XCTAssertNil(hit(640, 17), "past the last column")
    }
}
