import CoreGraphics
import XCTest
@testable import thetoolbox

final class SwitcherKeysTests: XCTestCase {
    private let tab = SwitcherKeyCode.tab
    private let qKey: UInt16 = 12

    private func makeKeys(trigger: SwitcherTrigger = .standard) -> SwitcherKeys {
        var keys = SwitcherKeys()
        keys.trigger = trigger
        keys.isEnabled = true
        return keys
    }

    private func down(_ keyCode: UInt16, _ modifiers: SwitcherModifiers = .command, isRepeat: Bool = false) -> SwitcherKeyEvent {
        .keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
    }

    private func decision(_ command: SwitcherCommand?, swallow: Bool) -> SwitcherKeyDecision {
        SwitcherKeyDecision(command: command, swallow: swallow)
    }

    func testTriggerBeginsForwardAndIsSwallowed() {
        var keys = makeKeys()
        XCTAssertEqual(keys.handle(down(tab)), decision(.begin(forward: true), swallow: true))
        XCTAssertTrue(keys.isActive)
    }

    func testShiftTriggerBeginsBackward() {
        var keys = makeKeys()
        XCTAssertEqual(keys.handle(down(tab, [.command, .shift])), decision(.begin(forward: false), swallow: true))
    }

    func testTabWithoutTheModifierPassesThrough() {
        var keys = makeKeys()
        XCTAssertEqual(keys.handle(down(tab, [])), .passThrough)
        XCTAssertFalse(keys.isActive)
    }

    func testOtherModifierCombinationsPassThrough() {
        var keys = makeKeys()
        XCTAssertEqual(keys.handle(down(tab, .option)), .passThrough)
        XCTAssertEqual(keys.handle(down(tab, [.command, .option])), .passThrough)
    }

    func testTabAndShiftTabMoveDuringASession() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.handle(down(tab)), decision(.next, swallow: true))
        XCTAssertEqual(keys.handle(down(tab, [.command, .shift])), decision(.previous, swallow: true))
    }

    func testArrowsMoveDuringASession() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.handle(down(SwitcherKeyCode.leftArrow)), decision(.move(.left), swallow: true))
        XCTAssertEqual(keys.handle(down(SwitcherKeyCode.rightArrow)), decision(.move(.right), swallow: true))
        XCTAssertEqual(keys.handle(down(SwitcherKeyCode.upArrow)), decision(.move(.up), swallow: true))
        XCTAssertEqual(keys.handle(down(SwitcherKeyCode.downArrow)), decision(.move(.down), swallow: true))
    }

    func testReleasingTheModifierCommits() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.handle(.modifiersChanged([])), decision(.commit, swallow: false))
        XCTAssertFalse(keys.isActive)
    }

    func testAddingShiftDuringASessionDoesNotCommit() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.handle(.modifiersChanged([.command, .shift])), .passThrough)
        XCTAssertTrue(keys.isActive)
    }

    func testEscapeCancels() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.handle(down(SwitcherKeyCode.escape)), decision(.cancel, swallow: true))
        XCTAssertFalse(keys.isActive)
        // Releasing ⌘ afterwards does not commit.
        XCTAssertEqual(keys.handle(.modifiersChanged([])), .passThrough)
    }

    func testQuickTapBeginsThenCommits() {
        var keys = makeKeys()
        XCTAssertEqual(keys.handle(down(tab)), decision(.begin(forward: true), swallow: true))
        XCTAssertEqual(keys.handle(.keyUp(keyCode: tab)), .swallowed)
        XCTAssertEqual(keys.handle(.modifiersChanged([])), decision(.commit, swallow: false))
    }

    func testOtherKeysAreSwallowedDuringASession() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.handle(down(qKey)), .swallowed, "⌘Q must not quit the frontmost app mid-switch")
        XCTAssertEqual(keys.handle(.keyUp(keyCode: qKey)), .swallowed)
    }

    func testKeyUpIsSwallowedEvenAfterTheSessionEnds() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        _ = keys.handle(.modifiersChanged([]))
        XCTAssertEqual(keys.handle(.keyUp(keyCode: tab)), .swallowed)
        XCTAssertEqual(keys.handle(.keyUp(keyCode: tab)), .passThrough, "only once per swallowed key-down")
    }

    func testRepeatAfterEscapeDoesNotReopen() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        _ = keys.handle(down(SwitcherKeyCode.escape))
        XCTAssertEqual(keys.handle(down(tab, isRepeat: true)), .swallowed)
        XCTAssertFalse(keys.isActive)
    }

    func testModifierChangesOutsideASessionPassThrough() {
        var keys = makeKeys()
        XCTAssertEqual(keys.handle(.modifiersChanged(.command)), .passThrough)
        XCTAssertEqual(keys.handle(.modifiersChanged([])), .passThrough)
    }

    func testEndSessionStopsTheSessionButKeepsKeyUpSwallowing() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        keys.endSession(id: keys.sessionID)
        XCTAssertFalse(keys.isActive)
        XCTAssertEqual(keys.handle(.modifiersChanged([])), .passThrough)
        XCTAssertEqual(keys.handle(.keyUp(keyCode: tab)), .swallowed)
    }

    func testSessionIDIncrementsWithEachBegin() {
        var keys = makeKeys()
        let start = keys.sessionID
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.sessionID, start &+ 1)
        _ = keys.handle(.modifiersChanged([]))
        _ = keys.handle(down(tab))
        XCTAssertEqual(keys.sessionID, start &+ 2)
    }

    func testEndSessionWithAnOldIDLeavesTheNewSessionRunning() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        let first = keys.sessionID
        _ = keys.handle(.modifiersChanged([]))
        _ = keys.handle(down(tab))
        // The first session's commit reaches the main thread after the second one began.
        keys.endSession(id: first)
        XCTAssertTrue(keys.isActive)
        XCTAssertEqual(keys.handle(.modifiersChanged([])), decision(.commit, swallow: false))
    }

    func testEndSessionWithTheCurrentIDEndsIt() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        _ = keys.handle(.modifiersChanged([]))
        _ = keys.handle(down(tab))
        keys.endSession(id: keys.sessionID)
        XCTAssertFalse(keys.isActive)
    }

    func testDisablingPassesEverythingThroughAndResets() {
        var keys = makeKeys()
        _ = keys.handle(down(tab))
        keys.isEnabled = false
        XCTAssertFalse(keys.isActive)
        XCTAssertEqual(keys.handle(.keyUp(keyCode: tab)), .passThrough)
        XCTAssertEqual(keys.handle(down(tab)), .passThrough)
    }

    func testCustomTrigger() {
        var keys = makeKeys(trigger: SwitcherTrigger(keyCode: tab, modifiers: .option)!)
        XCTAssertEqual(keys.handle(down(tab, .command)), .passThrough)
        XCTAssertEqual(keys.handle(down(tab, .option)), decision(.begin(forward: true), swallow: true))
        XCTAssertEqual(keys.handle(.modifiersChanged([])), decision(.commit, swallow: false))
    }

    func testTriggerNeedsAHoldableModifier() {
        XCTAssertNil(SwitcherTrigger(keyCode: tab, modifiers: []))
        XCTAssertNil(SwitcherTrigger(keyCode: tab, modifiers: .shift))
        XCTAssertEqual(SwitcherTrigger(keyCode: tab, modifiers: [.command, .shift])?.modifiers, .command)
    }

    func testEventFlagsKeepOnlyModifierKeys() {
        let raw = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskAlphaShift.rawValue
            | CGEventFlags.maskNonCoalesced.rawValue
        XCTAssertEqual(SwitcherModifiers(eventFlags: raw), .command)
    }
}
