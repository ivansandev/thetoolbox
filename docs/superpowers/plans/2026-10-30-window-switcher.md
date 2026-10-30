# Window Switcher (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace macOS's ⌘Tab app switcher with a window switcher that lists the current desktop's windows, with live thumbnails, in a native macOS HUD panel.

**Architecture:** Pure logic (key state machine, window-list rules, selection and layout math) sits in small, unit-tested files. Thin system wrappers sit on top of it: private SkyLight desktop calls, a CGWindowList + Accessibility snapshot, window focusing, ScreenCaptureKit thumbnails, and a session event tap on its own thread. A `WindowSwitcher` manager (an `ObservableObject`, like the other managers) wires them together, and a new Settings tab exposes the options.

**Tech Stack:** Swift 5 mode, AppKit + SwiftUI, macOS 14+, ScreenCaptureKit, Accessibility (AX), CGEventTap, private SkyLight symbols via `dlsym`, KeyboardShortcuts (recorder and storage only), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-30-window-switcher-design.md`

**Scope:** This plan is spec phase 1 (the switcher). Phase 2 (Dock previews, including the "Dock previews enabled" setting) gets its own plan after this one lands.

## Global Constraints

- Deployment target macOS 14.0; `SWIFT_VERSION` 5.0 (from `project.yml`). Don't change either.
- `project.yml` is the source of truth. New files under `Sources/` and `Tests/thetoolboxTests/` are picked up by `xcodegen generate`; never edit `thetoolbox.xcodeproj`.
- No new package dependencies. No code copied from DockWindow; it is a reference only.
- Native macOS look: `NSVisualEffectView` `.hudWindow` material, system fonts, `Color.primary.opacity(0.18)` selection. No custom themes.
- Private APIs are resolved at runtime with `dlopen`/`dlsym` (`PrivateSymbols`). Never link them, and never crash when one is missing.
- Thumbnails stay in memory only; nothing is written to disk.
- The default trigger is ⌘Tab. Shift reverses direction. A trigger must include ⌘, ⌥ or ⌃.
- When the feature is off, Accessibility is missing, or no trigger is set, the switcher's tap is stopped and macOS's ⌘Tab works normally.
- Settings defaults: enabled on, scope Current desktop, include minimized on, include hidden apps on.
- Commit straight to `main` (repo convention). Commit messages are plain sentences and end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Generate and test with:
  - `xcodegen generate`
  - `xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/<TestClass>`
- Build with: `xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build`

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/thetoolbox/WindowSwitcher/SwitcherKeys.swift` | Modifier set, trigger, key events/commands, the pure session state machine |
| Create `Sources/thetoolbox/WindowSwitcher/WindowRecord.swift` | `WindowRecord`, `DesktopScope`, `WindowListOptions`, pure `WindowListPolicy` |
| Create `Sources/thetoolbox/WindowSwitcher/SwitcherSelection.swift` | Pure selection movement and `SwitcherLayout` geometry |
| Create `Sources/thetoolbox/WindowSwitcher/PrivateSymbols.swift` | Runtime lookup of private C functions |
| Create `Sources/thetoolbox/WindowSwitcher/SpacesAPI.swift` | Current and fullscreen desktops; desktops of a window |
| Create `Sources/thetoolbox/WindowSwitcher/WindowInventory.swift` | On-demand window snapshot (CG + AX + desktops → policy) |
| Create `Sources/thetoolbox/WindowSwitcher/WindowFocuser.swift` | Focus one specific window (unhide, unminimize, front, raise) |
| Create `Sources/thetoolbox/WindowSwitcher/ThumbnailCapturer.swift` | ScreenCaptureKit captures with an in-memory LRU cache |
| Create `Sources/thetoolbox/WindowSwitcher/SwitcherKeyTap.swift` | Session event tap on its own thread, feeding `SwitcherKeys` |
| Create `Sources/thetoolbox/WindowSwitcher/SwitcherPanel.swift` | HUD panel, view model, SwiftUI tiles, mouse hit-testing view |
| Create `Sources/thetoolbox/WindowSwitcher/WindowSwitcher.swift` | Manager: preferences, permission gating, session flow |
| Create `Sources/thetoolbox/Shortcuts/ShortcutRecording.swift` | Shared "is a shortcut recorder focused?" check |
| Create `Sources/thetoolbox/Windows/ScreenRecordingPermission.swift` | Screen Recording check and request |
| Create `Sources/thetoolbox/Settings/ScreenRecordingStatusRow.swift` | Permission row for Settings |
| Create `Sources/thetoolbox/Settings/WindowSwitcherSettingsView.swift` | The Switcher settings tab |
| Modify `Sources/thetoolbox/Spaces/SpaceSwitcher.swift` | Use `ShortcutRecording.isActive` |
| Modify `Sources/thetoolbox/Shortcuts/ShortcutNames.swift` | Add `.windowSwitcher` |
| Modify `Sources/thetoolbox/Persistence/Preferences.swift` | Add the four switcher preferences |
| Modify `Sources/thetoolbox/App/ToolboxApp.swift` | Create the manager; pass it to Settings |
| Modify `Sources/thetoolbox/Settings/SettingsView.swift` | Add the Switcher tab |
| Modify `Sources/thetoolbox/Windows/WindowManager.swift:289` | Include `.windowSwitcher` in conflict resolution |
| Modify `README.md` | Feature, usage, permissions and structure entries |
| Create `Tests/thetoolboxTests/SwitcherKeysTests.swift` | State machine tests |
| Create `Tests/thetoolboxTests/WindowListPolicyTests.swift` | List rules tests |
| Create `Tests/thetoolboxTests/SwitcherSelectionTests.swift` | Selection and layout tests |

---

### Task 1: Key state machine (`SwitcherKeys`)

**Files:**
- Create: `Sources/thetoolbox/WindowSwitcher/SwitcherKeys.swift`
- Test: `Tests/thetoolboxTests/SwitcherKeysTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct SwitcherModifiers: OptionSet, Hashable` (`rawValue: UInt64`; `.shift`, `.control`, `.option`, `.command`, `.holdable`, `.allKeys`; `init(eventFlags: UInt64)`)
  - `enum SwitcherKeyCode` (`tab = 48`, `escape = 53`, `leftArrow = 123`, `rightArrow = 124`, `downArrow = 125`, `upArrow = 126`, all `UInt16`)
  - `struct SwitcherTrigger: Equatable` (`keyCode: UInt16`, `modifiers: SwitcherModifiers`; `init?(keyCode:modifiers:)`; `static let standard`)
  - `enum SwitcherKeyEvent: Equatable` (`.keyDown(keyCode:modifiers:isRepeat:)`, `.keyUp(keyCode:)`, `.modifiersChanged(SwitcherModifiers)`)
  - `enum SwitcherDirection: Equatable` (`.left`, `.right`, `.up`, `.down`)
  - `enum SwitcherCommand: Equatable` (`.begin(forward: Bool)`, `.next`, `.previous`, `.move(SwitcherDirection)`, `.commit`, `.cancel`)
  - `struct SwitcherKeyDecision: Equatable` (`command: SwitcherCommand?`, `swallow: Bool`; `.passThrough`, `.swallowed`)
  - `struct SwitcherKeys` (`trigger`, `isEnabled`, `isActive`; `mutating handle(_:) -> SwitcherKeyDecision`, `mutating endSession()`, `mutating reset()`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/thetoolboxTests/SwitcherKeysTests.swift`:

```swift
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
        keys.endSession()
        XCTAssertFalse(keys.isActive)
        XCTAssertEqual(keys.handle(.modifiersChanged([])), .passThrough)
        XCTAssertEqual(keys.handle(.keyUp(keyCode: tab)), .swallowed)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherKeysTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'SwitcherKeys' in scope` (and similar for the other types).

- [ ] **Step 3: Write the implementation**

Create `Sources/thetoolbox/WindowSwitcher/SwitcherKeys.swift`:

```swift
import CoreGraphics

/// ⌃⌥⇧⌘, stored with CGEventFlags bit values so an event tap's flags convert directly.
struct SwitcherModifiers: OptionSet, Hashable {
    let rawValue: UInt64

    static let shift = SwitcherModifiers(rawValue: CGEventFlags.maskShift.rawValue)
    static let control = SwitcherModifiers(rawValue: CGEventFlags.maskControl.rawValue)
    static let option = SwitcherModifiers(rawValue: CGEventFlags.maskAlternate.rawValue)
    static let command = SwitcherModifiers(rawValue: CGEventFlags.maskCommand.rawValue)

    static let allKeys: SwitcherModifiers = [.shift, .control, .option, .command]
    /// Modifiers a session can be held with. Shift only flips direction.
    static let holdable: SwitcherModifiers = [.control, .option, .command]
}

extension SwitcherModifiers {
    /// Keeps ⌃⌥⇧⌘ from raw event flags and drops Caps Lock, Fn and device bits.
    init(eventFlags: UInt64) {
        self.init(rawValue: eventFlags & SwitcherModifiers.allKeys.rawValue)
    }
}

/// Virtual key codes (Carbon `kVK_*`) the switcher reacts to.
enum SwitcherKeyCode {
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

/// The shortcut that opens the switcher. Releasing its modifiers picks the window, so it must
/// have at least one of ⌘⌥⌃. Shift is never part of it: Shift reverses direction.
struct SwitcherTrigger: Equatable {
    let keyCode: UInt16
    let modifiers: SwitcherModifiers

    static let standard = SwitcherTrigger(keyCode: SwitcherKeyCode.tab, modifiers: .command)!

    init?(keyCode: UInt16, modifiers: SwitcherModifiers) {
        let held = modifiers.intersection(.holdable)
        guard !held.isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = held
    }
}

enum SwitcherKeyEvent: Equatable {
    case keyDown(keyCode: UInt16, modifiers: SwitcherModifiers, isRepeat: Bool)
    case keyUp(keyCode: UInt16)
    case modifiersChanged(SwitcherModifiers)
}

enum SwitcherDirection: Equatable {
    case left, right, up, down
}

enum SwitcherCommand: Equatable {
    case begin(forward: Bool)
    case next
    case previous
    case move(SwitcherDirection)
    case commit
    case cancel
}

struct SwitcherKeyDecision: Equatable {
    var command: SwitcherCommand?
    /// True to keep the event from reaching macOS and the frontmost app.
    var swallow: Bool

    static let passThrough = SwitcherKeyDecision(command: nil, swallow: false)
    static let swallowed = SwitcherKeyDecision(command: nil, swallow: true)
}

/// Decides, event by event, what the switcher does with the keyboard. Pure value type: the key
/// tap owns one and calls `handle` for every key-down, key-up and modifier change.
struct SwitcherKeys {
    var trigger: SwitcherTrigger = .standard
    var isEnabled = false {
        didSet { if !isEnabled { reset() } }
    }

    /// True from the trigger press until commit, cancel or `endSession()`.
    private(set) var isActive = false
    /// Key-ups to swallow because we swallowed their key-down.
    private var swallowedKeyUps: Set<UInt16> = []

    /// Ends the session without a command (e.g. the list was empty, or a click picked a window).
    /// Key-ups for keys already swallowed are still swallowed.
    mutating func endSession() {
        isActive = false
    }

    mutating func reset() {
        isActive = false
        swallowedKeyUps.removeAll()
    }

    mutating func handle(_ event: SwitcherKeyEvent) -> SwitcherKeyDecision {
        guard isEnabled else { return .passThrough }
        switch event {
        case let .keyUp(keyCode):
            return swallowedKeyUps.remove(keyCode) != nil ? .swallowed : .passThrough

        case let .modifiersChanged(modifiers):
            guard isActive, !modifiers.isSuperset(of: trigger.modifiers) else { return .passThrough }
            isActive = false
            return SwitcherKeyDecision(command: .commit, swallow: false)

        case let .keyDown(keyCode, modifiers, isRepeat):
            if isActive {
                return swallow(keyCode, sessionCommand(keyCode: keyCode, modifiers: modifiers))
            }
            guard keyCode == trigger.keyCode,
                  modifiers.intersection(.holdable) == trigger.modifiers else { return .passThrough }
            // A trigger key still held after Esc keeps repeating; it must not reopen the switcher.
            guard !isRepeat else { return swallow(keyCode, nil) }
            isActive = true
            return swallow(keyCode, .begin(forward: !modifiers.contains(.shift)))
        }
    }

    private mutating func sessionCommand(keyCode: UInt16, modifiers: SwitcherModifiers) -> SwitcherCommand? {
        switch keyCode {
        case SwitcherKeyCode.escape:
            isActive = false
            return .cancel
        case trigger.keyCode:
            return modifiers.contains(.shift) ? .previous : .next
        case SwitcherKeyCode.leftArrow: return .move(.left)
        case SwitcherKeyCode.rightArrow: return .move(.right)
        case SwitcherKeyCode.upArrow: return .move(.up)
        case SwitcherKeyCode.downArrow: return .move(.down)
        default:
            // Every other key is swallowed so ⌘Q, ⌘W etc. can't act on the frontmost app.
            return nil
        }
    }

    private mutating func swallow(_ keyCode: UInt16, _ command: SwitcherCommand?) -> SwitcherKeyDecision {
        swallowedKeyUps.insert(keyCode)
        return SwitcherKeyDecision(command: command, swallow: true)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherKeysTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/thetoolbox/WindowSwitcher/SwitcherKeys.swift Tests/thetoolboxTests/SwitcherKeysTests.swift
git commit -F - <<'EOF'
Add the window switcher's key state machine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Window list rules (`WindowRecord`, `WindowListPolicy`)

**Files:**
- Create: `Sources/thetoolbox/WindowSwitcher/WindowRecord.swift`
- Test: `Tests/thetoolboxTests/WindowListPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct WindowRecord: Equatable, Identifiable` with memberwise init in this order: `id: CGWindowID`, `pid: pid_t`, `appName: String`, `title: String`, `bounds: CGRect`, `isMinimized: Bool = false`, `isFullscreen: Bool = false`, `isAppHidden: Bool = false`, `spaceIDs: Set<UInt64> = []`, `isAccessible: Bool = true`; computed `displayTitle: String`
  - `enum DesktopScope: String, CaseIterable` (`.current`, `.all`)
  - `struct WindowListOptions: Equatable` (`scope = .current`, `includeMinimized = true`, `includeHidden = true`)
  - `enum WindowListPolicy` with `static func isCandidate(layer: Int, alpha: Double, bounds: CGRect, ownerPID: pid_t, ownPID: pid_t, ownerIsRegularApp: Bool) -> Bool` and `static func list(_ windows: [WindowRecord], currentSpaceIDs: Set<UInt64>?, options: WindowListOptions) -> [WindowRecord]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/thetoolboxTests/WindowListPolicyTests.swift`:

```swift
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
        options: WindowListOptions = WindowListOptions()
    ) -> [CGWindowID] {
        WindowListPolicy.list(windows, currentSpaceIDs: current, options: options).map(\.id)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/WindowListPolicyTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'WindowRecord' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/thetoolbox/WindowSwitcher/WindowRecord.swift`:

```swift
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
    static func list(
        _ windows: [WindowRecord], currentSpaceIDs: Set<UInt64>?, options: WindowListOptions
    ) -> [WindowRecord] {
        var visible: [WindowRecord] = []
        var minimized: [WindowRecord] = []
        var hidden: [WindowRecord] = []
        for window in windows {
            let onCurrent = isOnCurrentDesktop(window, currentSpaceIDs)
            // On the current desktop, anything Accessibility doesn't list is a helper surface.
            guard window.isAccessible || !onCurrent else { continue }
            guard options.scope == .all || onCurrent || window.isFullscreen else { continue }
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

    /// Unknown membership, or no desktop info at all, counts as the current desktop.
    static func isOnCurrentDesktop(_ window: WindowRecord, _ currentSpaceIDs: Set<UInt64>?) -> Bool {
        guard let currentSpaceIDs, !window.spaceIDs.isEmpty else { return true }
        return !window.spaceIDs.isDisjoint(with: currentSpaceIDs)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/WindowListPolicyTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/thetoolbox/WindowSwitcher/WindowRecord.swift Tests/thetoolboxTests/WindowListPolicyTests.swift
git commit -F - <<'EOF'
Add the window switcher's window list rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Selection and layout (`SwitcherSelection`, `SwitcherLayout`)

**Files:**
- Create: `Sources/thetoolbox/WindowSwitcher/SwitcherSelection.swift`
- Test: `Tests/thetoolboxTests/SwitcherSelectionTests.swift`

**Interfaces:**
- Consumes: `SwitcherDirection` (Task 1).
- Produces:
  - `struct SwitcherSelection: Equatable` (`count`, `columns`, `index`; `init(count:columns:forward:)`; `mutating next()`, `previous()`, `move(_:)`, `select(_:)`)
  - `enum SwitcherLayout` with constants `tileSize` (200×150), `tileInset` (10), `spacing` (8), `padding` (16), `titleSpacing` (12), `titleHeight` (18), `thumbnailSize` (180×130), and `static func columns(count:availableWidth:) -> Int`, `maxRows(availableHeight:) -> Int`, `rows(count:columns:) -> Int`, `gridSize(count:columns:) -> CGSize`, `panelSize(count:columns:) -> CGSize`, `tileIndex(at:columns:count:) -> Int?` (the point is measured from the panel's top-left)

- [ ] **Step 1: Write the failing tests**

Create `Tests/thetoolboxTests/SwitcherSelectionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherSelectionTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'SwitcherSelection' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/thetoolbox/WindowSwitcher/SwitcherSelection.swift`:

```swift
import CoreGraphics

/// Which tile is selected, and how keys move the selection through a grid.
struct SwitcherSelection: Equatable {
    let count: Int
    let columns: Int
    private(set) var index: Int

    /// Forward starts on the previous window (index 1), backward on the last one, so a quick
    /// ⌘Tab flips between the two most recent windows.
    init(count: Int, columns: Int, forward: Bool) {
        self.count = max(0, count)
        self.columns = max(1, columns)
        if count <= 1 {
            index = 0
        } else {
            index = forward ? 1 : count - 1
        }
    }

    mutating func next() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    mutating func previous() {
        guard count > 0 else { return }
        index = (index - 1 + count) % count
    }

    mutating func select(_ newIndex: Int) {
        guard (0 ..< count).contains(newIndex) else { return }
        index = newIndex
    }

    /// Left/right step through the list; up/down keep the column and wrap rows, landing on the
    /// last tile when the target row is too short.
    mutating func move(_ direction: SwitcherDirection) {
        switch direction {
        case .left: previous()
        case .right: next()
        case .up, .down:
            guard count > 0 else { return }
            let rows = SwitcherLayout.rows(count: count, columns: columns)
            guard rows > 1 else { return }
            let row = index / columns
            let column = index % columns
            let step = direction == .down ? 1 : rows - 1
            index = min(((row + step) % rows) * columns + column, count - 1)
        }
    }
}

/// Geometry of the switcher panel. Tiles are a fixed size, laid out left to right and top to
/// bottom, so the SwiftUI view and the mouse hit-testing share these numbers.
enum SwitcherLayout {
    static let tileSize = CGSize(width: 200, height: 150)
    static let tileInset: CGFloat = 10
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 16
    static let titleSpacing: CGFloat = 12
    static let titleHeight: CGFloat = 18

    static var thumbnailSize: CGSize {
        CGSize(width: tileSize.width - tileInset * 2, height: tileSize.height - tileInset * 2)
    }

    /// Tiles per row: all of them if they fit, otherwise as many as fit (at least one).
    static func columns(count: Int, availableWidth: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let usable = availableWidth - padding * 2 + spacing
        let fit = max(1, Int(usable / (tileSize.width + spacing)))
        return min(count, fit)
    }

    /// Rows that fit in `availableHeight`, leaving room for the title line (at least one).
    static func maxRows(availableHeight: CGFloat) -> Int {
        let usable = availableHeight - padding * 2 - titleSpacing - titleHeight + spacing
        return max(1, Int(usable / (tileSize.height + spacing)))
    }

    static func rows(count: Int, columns: Int) -> Int {
        let columns = max(1, columns)
        return max(1, (count + columns - 1) / columns)
    }

    static func gridSize(count: Int, columns: Int) -> CGSize {
        let columns = CGFloat(max(1, columns))
        let rows = CGFloat(rows(count: count, columns: Int(columns)))
        return CGSize(
            width: columns * tileSize.width + (columns - 1) * spacing,
            height: rows * tileSize.height + (rows - 1) * spacing
        )
    }

    static func panelSize(count: Int, columns: Int) -> CGSize {
        let grid = gridSize(count: count, columns: columns)
        return CGSize(
            width: grid.width + padding * 2,
            height: grid.height + padding * 2 + titleSpacing + titleHeight
        )
    }

    /// The tile under `point`, measured from the panel's top-left corner, or nil for padding,
    /// gaps and empty cells.
    static func tileIndex(at point: CGPoint, columns: Int, count: Int) -> Int? {
        let x = point.x - padding
        let y = point.y - padding
        guard x >= 0, y >= 0, columns > 0 else { return nil }
        let strideX = tileSize.width + spacing
        let strideY = tileSize.height + spacing
        let column = Int(x / strideX)
        let row = Int(y / strideY)
        guard column < columns,
              x - CGFloat(column) * strideX < tileSize.width,
              y - CGFloat(row) * strideY < tileSize.height else { return nil }
        let index = row * columns + column
        return index < count ? index : nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherSelectionTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/thetoolbox/WindowSwitcher/SwitcherSelection.swift Tests/thetoolboxTests/SwitcherSelectionTests.swift
git commit -F - <<'EOF'
Add the window switcher's selection and layout math

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 4: Desktops and window snapshot (`PrivateSymbols`, `SpacesAPI`, `WindowInventory`)

These wrap live system state, so there are no unit tests. Their rules were tested in Task 2, and the snapshot gets checked on a real Mac in Task 9.

**Files:**
- Create: `Sources/thetoolbox/WindowSwitcher/PrivateSymbols.swift`
- Create: `Sources/thetoolbox/WindowSwitcher/SpacesAPI.swift`
- Create: `Sources/thetoolbox/WindowSwitcher/WindowInventory.swift`

**Interfaces:**
- Consumes: `WindowRecord`, `WindowListOptions`, `WindowListPolicy` (Task 2).
- Produces:
  - `enum PrivateSymbols` with `static func function<T>(_ name: String, as type: T.Type) -> T?`
  - `final class SpacesAPI` with `static let shared`, `struct Desktops { let current: Set<UInt64>; let fullscreen: Set<UInt64> }`, `func desktops() -> Desktops?`, `func spaceIDs(of windowID: CGWindowID) -> Set<UInt64>`
  - `struct WindowSnapshot` (`windows: [WindowRecord]`, `elements: [CGWindowID: AXUIElement]`; `static let empty`)
  - `final class WindowInventory` with `var isAvailable: Bool` and `func snapshot(options: WindowListOptions) -> WindowSnapshot`

- [ ] **Step 1: Create `PrivateSymbols.swift`**

```swift
import Darwin

/// Looks up private C functions at runtime, so a symbol that a macOS update removes returns nil
/// instead of stopping the app from launching.
enum PrivateSymbols {
    private static let handles: [UnsafeMutableRawPointer] = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
    ].compactMap { dlopen($0, RTLD_LAZY) }

    /// `T` must be a `@convention(c)` function type matching the symbol's real signature.
    static func function<T>(_ name: String, as _: T.Type) -> T? {
        for handle in handles {
            if let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: T.self)
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Create `SpacesAPI.swift`**

```swift
import CoreGraphics
import Foundation

/// Private SkyLight calls for desktops (spaces). Every method returns nil or empty when macOS no
/// longer provides a call; the window list then treats every window as on the current desktop.
final class SpacesAPI {
    static let shared = SpacesAPI()

    struct Desktops {
        /// The current desktop of every display.
        let current: Set<UInt64>
        /// Desktops that hold a fullscreen app.
        let fullscreen: Set<UInt64>
    }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let mainConnectionID = PrivateSymbols.function("SLSMainConnectionID", as: MainConnectionID.self)
        ?? PrivateSymbols.function("CGSMainConnectionID", as: MainConnectionID.self)
    private let copyManagedDisplaySpaces = PrivateSymbols.function("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        ?? PrivateSymbols.function("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private let copySpacesForWindows = PrivateSymbols.function("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
        ?? PrivateSymbols.function("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)

    /// Selector for "all spaces" in CGSCopySpacesForWindows.
    private static let allSpacesMask: Int32 = 7
    /// Space type of a fullscreen app's desktop in CGSCopyManagedDisplaySpaces.
    private static let fullscreenSpaceType = 4

    private init() {}

    func desktops() -> Desktops? {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let array = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue(),
              let displays = (array as NSArray) as? [[String: Any]] else { return nil }
        var current = Set<UInt64>()
        var fullscreen = Set<UInt64>()
        for display in displays {
            if let space = display["Current Space"] as? [String: Any], let id = Self.id(of: space) {
                current.insert(id)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? []
            where (space["type"] as? NSNumber)?.intValue == Self.fullscreenSpaceType {
                if let id = Self.id(of: space) { fullscreen.insert(id) }
            }
        }
        return current.isEmpty ? nil : Desktops(current: current, fullscreen: fullscreen)
    }

    /// The desktops `windowID` is on; empty when unknown.
    func spaceIDs(of windowID: CGWindowID) -> Set<UInt64> {
        guard let mainConnectionID, let copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let array = copySpacesForWindows(mainConnectionID(), Self.allSpacesMask, ids)?.takeRetainedValue(),
              let spaces = (array as NSArray) as? [NSNumber] else { return [] }
        return Set(spaces.map(\.uint64Value))
    }

    private static func id(of space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? NSNumber ?? space["id64"] as? NSNumber)?.uint64Value
    }
}
```

- [ ] **Step 3: Create `WindowInventory.swift`**

```swift
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

        // 2. Accessibility details, one app at a time.
        var details: [CGWindowID: AXDetails] = [:]
        for pid in Set(candidates.map(\.pid)) {
            details.merge(accessibilityWindows(pid: pid)) { first, _ in first }
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
                isAccessible: detail != nil
            ))
        }
        let listed = WindowListPolicy.list(records, currentSpaceIDs: desktops?.current, options: options)
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

    private func accessibilityWindows(pid: pid_t) -> [CGWindowID: AXDetails] {
        guard let getWindow else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        guard let windows = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [:] }
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
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **` and no `error:` lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/thetoolbox/WindowSwitcher/PrivateSymbols.swift Sources/thetoolbox/WindowSwitcher/SpacesAPI.swift Sources/thetoolbox/WindowSwitcher/WindowInventory.swift
git commit -F - <<'EOF'
Add desktop lookup and the window switcher's window snapshot

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 5: Window focusing (`WindowFocuser`)

**Files:**
- Create: `Sources/thetoolbox/WindowSwitcher/WindowFocuser.swift`

**Interfaces:**
- Consumes: `WindowRecord` (Task 2), `PrivateSymbols` (Task 4).
- Produces: `final class WindowFocuser` with `func focus(_ window: WindowRecord, element: AXUIElement?)`

- [ ] **Step 1: Create `WindowFocuser.swift`**

```swift
import AppKit
import ApplicationServices

/// Brings one specific window to the front, switching to its desktop when needed. If the window
/// is gone, this still brings its app forward.
final class WindowFocuser {
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private let getProcessForPID = PrivateSymbols.function("GetProcessForPID", as: GetProcessForPID.self)
    private let setFrontProcess = PrivateSymbols.function("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self)
    private let postEventRecord = PrivateSymbols.function("SLPSPostEventRecordTo", as: PostEventRecordTo.self)

    /// Fronts the process as if the user had clicked it.
    private static let userGenerated: UInt32 = 0x200

    func focus(_ window: WindowRecord, element: AXUIElement?) {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return }
        if app.isHidden { app.unhide() }
        if let element, window.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if !frontWindow(pid: window.pid, windowID: window.id) {
            app.activate()
        }
        if let element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    /// Fronts the app with exactly this window key, and switches to the window's desktop.
    /// Returns false when the private calls are unavailable or fail.
    private func frontWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == 0,
              setFrontProcess(&psn, windowID, Self.userGenerated) == 0 else { return false }

        // A synthetic "make key window" event record, sent as a press then a release.
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x3A] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { record.replaceSubrange(0x3C ..< 0x40, with: $0) }
        for offset in 0x20 ..< 0x30 { record[offset] = 0xFF }
        record[0x08] = 0x01
        _ = postEventRecord(&psn, &record)
        record[0x08] = 0x02
        _ = postEventRecord(&psn, &record)
        return true
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/thetoolbox/WindowSwitcher/WindowFocuser.swift
git commit -F - <<'EOF'
Add focusing a specific window for the window switcher

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 6: Thumbnails and Screen Recording (`ThumbnailCapturer`, `ScreenRecordingPermission`)

**Files:**
- Create: `Sources/thetoolbox/Windows/ScreenRecordingPermission.swift`
- Create: `Sources/thetoolbox/WindowSwitcher/ThumbnailCapturer.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `enum ScreenRecordingPermission` with `static var isGranted: Bool` and `static func request()`
  - `final class ThumbnailCapturer` with `func cached(_ id: CGWindowID) -> CGImage?` and `func capture(_ ids: [CGWindowID], maxSize: CGSize, onImage: @escaping (CGWindowID, CGImage) -> Void) async` (`onImage` runs on the main thread)

- [ ] **Step 1: Create `ScreenRecordingPermission.swift`**

```swift
import AppKit
import CoreGraphics

/// Screen Recording access, needed only for window thumbnails.
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// The first call shows the system prompt and lists thetoolbox in System Settings. If access
    /// is still missing (the prompt was dismissed earlier), opens the Screen Recording pane.
    static func request() {
        guard !CGRequestScreenCaptureAccess() else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Create `ThumbnailCapturer.swift`**

```swift
import AppKit
import ScreenCaptureKit

/// Small window images for the switcher, from ScreenCaptureKit. Kept in memory only, with an
/// LRU limit. `cached` and the cache itself are main-thread only; `capture` hops back to the
/// main thread for each image.
final class ThumbnailCapturer {
    static let maxCached = 100
    static let maxConcurrent = 4

    private var cache: [CGWindowID: CGImage] = [:]
    private var lastUse: [CGWindowID: UInt64] = [:]
    private var clock: UInt64 = 0

    func cached(_ id: CGWindowID) -> CGImage? {
        guard let image = cache[id] else { return nil }
        touch(id)
        return image
    }

    /// Captures `ids`, at most `maxConcurrent` at a time, calling `onImage` on the main thread as
    /// each image arrives. Does nothing without Screen Recording access. Stops when cancelled.
    func capture(_ ids: [CGWindowID], maxSize: CGSize, onImage: @escaping (CGWindowID, CGImage) -> Void) async {
        guard ScreenRecordingPermission.isGranted, !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = ids.compactMap { byID[$0] }.makeIterator()

        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for _ in 0 ..< Self.maxConcurrent {
                guard let window = pending.next() else { break }
                group.addTask { (window.windowID, await Self.image(of: window, maxSize: maxSize)) }
            }
            while let result = await group.next() {
                let (id, image) = result
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if let image {
                    await MainActor.run {
                        self.store(image, for: id)
                        onImage(id, image)
                    }
                }
                if let window = pending.next() {
                    group.addTask { (window.windowID, await Self.image(of: window, maxSize: maxSize)) }
                }
            }
        }
    }

    private static func image(of window: SCWindow, maxSize: CGSize) async -> CGImage? {
        let frame = window.frame.size
        guard frame.width > 0, frame.height > 0 else { return nil }
        // Fit inside maxSize, at 2× for Retina.
        let scale = min(maxSize.width / frame.width, maxSize.height / frame.height, 1) * 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func store(_ image: CGImage, for id: CGWindowID) {
        cache[id] = image
        touch(id)
        while cache.count > Self.maxCached,
              let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
            cache.removeValue(forKey: oldest)
            lastUse.removeValue(forKey: oldest)
        }
    }

    private func touch(_ id: CGWindowID) {
        clock &+= 1
        lastUse[id] = clock
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **` (Swift 5 mode may print concurrency *warnings* about `SCWindow`/`CGImage` not being `Sendable`; those are expected and fine).

- [ ] **Step 4: Commit**

```bash
git add Sources/thetoolbox/Windows/ScreenRecordingPermission.swift Sources/thetoolbox/WindowSwitcher/ThumbnailCapturer.swift
git commit -F - <<'EOF'
Add window thumbnails and the Screen Recording permission check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 7: Key tap (`SwitcherKeyTap`, `ShortcutRecording`)

The Spaces feature's `KeyDownTap` forwards keys to a focused shortcut recorder, because otherwise macOS acts on shortcuts like ⌃← before the recorder sees them. ⌘Tab has the same problem, so the switcher's tap must forward too. This task moves the "is a recorder focused?" check into one shared place.

**Files:**
- Create: `Sources/thetoolbox/Shortcuts/ShortcutRecording.swift`
- Modify: `Sources/thetoolbox/Spaces/SpaceSwitcher.swift` (the `isRecordingShortcut` check)
- Create: `Sources/thetoolbox/WindowSwitcher/SwitcherKeyTap.swift`

**Interfaces:**
- Consumes: `SwitcherKeys`, `SwitcherKeyEvent`, `SwitcherModifiers`, `SwitcherTrigger`, `SwitcherCommand`, `SwitcherKeyDecision` (Task 1); `AccessibilityPermission` (existing).
- Produces:
  - `enum ShortcutRecording` with `static var isActive: Bool` (main thread)
  - `final class SwitcherKeyTap` with `var onCommand: ((SwitcherCommand) -> Void)?` (called on main), `var isRunning: Bool`, `@discardableResult func start() -> Bool`, `func stop()`, `func configure(enabled: Bool, trigger: SwitcherTrigger)`, `func endSession()`, `func setForwardsToRecorder(_ value: Bool)`

- [ ] **Step 1: Create `ShortcutRecording.swift`**

```swift
import AppKit
import KeyboardShortcuts

enum ShortcutRecording {
    /// True while one of thetoolbox's KeyboardShortcuts recorders is listening. A focused
    /// recorder edits through the window's field editor, whose delegate is the recorder.
    /// Main thread only.
    static var isActive: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.delegate is KeyboardShortcuts.RecorderCocoa
    }
}
```

- [ ] **Step 2: Make `SpaceSwitcher` use it**

In `Sources/thetoolbox/Spaces/SpaceSwitcher.swift`, replace:

```swift
        if Self.isRecordingShortcut, let key = NSEvent(cgEvent: event) {
```

with:

```swift
        if ShortcutRecording.isActive, let key = NSEvent(cgEvent: event) {
```

and delete this block (it now lives in `ShortcutRecording`):

```swift
    /// A focused recorder edits through the window's field editor, whose delegate is the recorder.
    private static var isRecordingShortcut: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.delegate is KeyboardShortcuts.RecorderCocoa
    }
```

- [ ] **Step 3: Create `SwitcherKeyTap.swift`**

```swift
import AppKit
import CoreGraphics

/// The switcher's session event tap. It runs on its own thread so a busy main thread can't make
/// macOS disable the tap in the middle of a switch. `SwitcherKeys` decides what happens with
/// each event; commands are delivered on the main thread. Needs Accessibility.
final class SwitcherKeyTap {
    /// Called on the main thread.
    var onCommand: ((SwitcherCommand) -> Void)?

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var keys = SwitcherKeys()
    private var forwardsToRecorder = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    var isRunning: Bool { locked { tap != nil } }

    /// Starts the tap thread. Idempotent. Returns false without Accessibility, or if macOS
    /// refuses to create the tap.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard AccessibilityPermission.isGranted else { return false }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { self.run(ready: ready) }
        thread.name = "thetoolbox window switcher keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return isRunning
    }

    /// Stops the tap thread. Safe to call when it isn't running.
    func stop() {
        locked {
            keys.reset()
            guard let runLoop else { return }
            // Queued as a block so it also works if the loop hasn't started running yet.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(runLoop) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    func configure(enabled: Bool, trigger: SwitcherTrigger) {
        locked {
            keys.trigger = trigger
            keys.isEnabled = enabled
        }
    }

    /// Ends a session the manager closed itself (empty list, mouse click, feature turned off).
    func endSession() {
        locked { keys.endSession() }
    }

    /// While a shortcut recorder is listening, key presses go to it instead of the switcher.
    func setForwardsToRecorder(_ value: Bool) {
        locked { forwardsToRecorder = value }
    }

    // MARK: Tap thread

    private func run(ready: DispatchSemaphore) {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: switcherKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ready.signal()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        locked {
            self.tap = tap
            self.runLoop = loop
        }
        ready.signal()

        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .defaultMode)
        CFMachPortInvalidate(tap)
        locked {
            self.tap = nil
            self.runLoop = nil
            keys.reset()
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let keyEvent: SwitcherKeyEvent
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns off a tap that was slow or interrupted; turn it straight back on.
            locked { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return pass
        case .keyDown:
            keyEvent = .keyDown(
                keyCode: Self.keyCode(of: event),
                modifiers: SwitcherModifiers(eventFlags: event.flags.rawValue),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            keyEvent = .keyUp(keyCode: Self.keyCode(of: event))
        case .flagsChanged:
            keyEvent = .modifiersChanged(SwitcherModifiers(eventFlags: event.flags.rawValue))
        default:
            return pass
        }

        let (decision, forward): (SwitcherKeyDecision, Bool) = locked {
            forwardsToRecorder ? (.passThrough, true) : (keys.handle(keyEvent), false)
        }

        if forward {
            // Hand the key straight to the recorder, before macOS's own ⌘Tab can take it.
            guard type == .keyDown else { return pass }
            let copy = event.copy()
            DispatchQueue.main.async {
                if let copy, let key = NSEvent(cgEvent: copy) { NSApp.postEvent(key, atStart: false) }
            }
            return nil
        }
        if let command = decision.command {
            DispatchQueue.main.async { [weak self] in self?.onCommand?(command) }
        }
        return decision.swallow ? nil : pass
    }

    private static func keyCode(of event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private func switcherKeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SwitcherKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
```

- [ ] **Step 4: Build, and re-run the existing tests to make sure the SpaceSwitcher change broke nothing**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherKeysTests -only-testing:thetoolboxTests/DDCCapabilitiesTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/thetoolbox/Shortcuts/ShortcutRecording.swift Sources/thetoolbox/Spaces/SpaceSwitcher.swift Sources/thetoolbox/WindowSwitcher/SwitcherKeyTap.swift
git commit -F - <<'EOF'
Add the window switcher's key tap and share the recorder check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 8: Panel UI (`SwitcherPanel`)

The panel can't take key focus, so it never steals focus from the app you're switching away from. Mouse handling is done in an AppKit view with an always-active tracking area, because SwiftUI hover doesn't fire while thetoolbox (a menu-bar app) isn't the active app. Hit-testing uses `SwitcherLayout.tileIndex`, which was tested in Task 3.

**Files:**
- Create: `Sources/thetoolbox/WindowSwitcher/SwitcherPanel.swift`

**Interfaces:**
- Consumes: `WindowRecord` (Task 2); `SwitcherLayout` (Task 3).
- Produces:
  - `final class SwitcherViewModel: ObservableObject` (`windows`, `selectedIndex`, `thumbnails: [CGWindowID: CGImage]`, `icons: [pid_t: NSImage]`, `columns`)
  - `final class SwitcherPanel` with `let model: SwitcherViewModel`, `var onHover: ((Int) -> Void)?`, `var onClick: ((Int) -> Void)?`, `func show(windows: [WindowRecord], icons: [pid_t: NSImage], thumbnails: [CGWindowID: CGImage], selectedIndex: Int, columns: Int, on screen: NSScreen)`, `func hide()`

- [ ] **Step 1: Create `SwitcherPanel.swift`**

```swift
import AppKit
import SwiftUI

/// What the panel shows. `WindowSwitcher` updates it as the selection moves and thumbnails
/// arrive.
final class SwitcherViewModel: ObservableObject {
    @Published var windows: [WindowRecord] = []
    @Published var selectedIndex = 0
    @Published var thumbnails: [CGWindowID: CGImage] = [:]
    @Published var icons: [pid_t: NSImage] = [:]
    @Published var columns = 1
}

/// A floating HUD panel in the style of the system ⌘Tab switcher.
final class SwitcherPanel {
    let model = SwitcherViewModel()

    var onHover: ((Int) -> Void)? {
        get { hostingView.onHover }
        set { hostingView.onHover = newValue }
    }

    var onClick: ((Int) -> Void)? {
        get { hostingView.onClick }
        set { hostingView.onClick = newValue }
    }

    private let panel: NSPanel
    private let hostingView: SwitcherHostingView

    init() {
        hostingView = SwitcherHostingView(rootView: SwitcherView(model: model))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(hostingView)

        panel = NonKeyPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = background
    }

    func show(
        windows: [WindowRecord],
        icons: [pid_t: NSImage],
        thumbnails: [CGWindowID: CGImage],
        selectedIndex: Int,
        columns: Int,
        on screen: NSScreen
    ) {
        model.columns = columns
        model.icons = icons
        model.thumbnails = thumbnails
        model.windows = windows
        model.selectedIndex = selectedIndex
        hostingView.columns = columns
        hostingView.count = windows.count

        let size = SwitcherLayout.panelSize(count: windows.count, columns: columns)
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Never becomes key, so the app being switched away from keeps keyboard focus.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI tiles and handles the mouse itself: an always-active tracking area works
/// while thetoolbox isn't the active app.
private final class SwitcherHostingView: NSHostingView<SwitcherView> {
    var columns = 1
    var count = 0
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private var mouseArea: NSTrackingArea?

    required init(rootView: SwitcherView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseArea { removeTrackingArea(mouseArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseArea = area
    }

    // Mouse-moved events only arrive when the pointer actually moves, so a panel that opens
    // under a resting pointer keeps its keyboard selection.
    override func mouseMoved(with event: NSEvent) {
        if let index = tileIndex(for: event) { onHover?(index) }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = tileIndex(for: event) { onClick?(index) }
    }

    private func tileIndex(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        return SwitcherLayout.tileIndex(at: CGPoint(x: point.x, y: fromTop), columns: columns, count: count)
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: SwitcherLayout.titleSpacing) {
            VStack(alignment: .leading, spacing: SwitcherLayout.spacing) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: SwitcherLayout.spacing) {
                        ForEach(row, id: \.self) { index in
                            let window = model.windows[index]
                            SwitcherTile(
                                window: window,
                                icon: model.icons[window.pid],
                                thumbnail: model.thumbnails[window.id],
                                isSelected: index == model.selectedIndex
                            )
                        }
                    }
                }
            }
            Text(selectedTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    width: SwitcherLayout.gridSize(count: model.windows.count, columns: model.columns).width,
                    height: SwitcherLayout.titleHeight
                )
        }
        .padding(SwitcherLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rows: [[Int]] {
        let count = model.windows.count
        let columns = max(1, model.columns)
        return stride(from: 0, to: count, by: columns).map { Array($0 ..< min($0 + columns, count)) }
    }

    private var selectedTitle: String {
        model.windows.indices.contains(model.selectedIndex) ? model.windows[model.selectedIndex].displayTitle : ""
    }
}

private struct SwitcherTile: View {
    let window: WindowRecord
    let icon: NSImage?
    let thumbnail: CGImage?
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if thumbnail != nil, let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .offset(x: 6, y: 6)
            }
        }
        .padding(SwitcherLayout.tileInset)
        .frame(width: SwitcherLayout.tileSize.width, height: SwitcherLayout.tileSize.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.18) : Color.clear)
        )
        .opacity(window.isMinimized || window.isAppHidden ? 0.6 : 1)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/thetoolbox/WindowSwitcher/SwitcherPanel.swift
git commit -F - <<'EOF'
Add the window switcher's native HUD panel

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 9: Manager and app wiring (`WindowSwitcher`)

**Files:**
- Modify: `Sources/thetoolbox/Persistence/Preferences.swift`
- Modify: `Sources/thetoolbox/Shortcuts/ShortcutNames.swift`
- Create: `Sources/thetoolbox/WindowSwitcher/WindowSwitcher.swift`
- Modify: `Sources/thetoolbox/App/ToolboxApp.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–8; `Preferences.shared`; `AccessibilityPermission`; `ShortcutRecording`.
- Produces:
  - `PreferenceKey.windowSwitcherEnabled`, `.windowSwitcherScope`, `.windowSwitcherIncludeMinimized`, `.windowSwitcherIncludeHidden`; `Preferences.windowSwitcherEnabled: Bool` (default true), `windowSwitcherScope: DesktopScope` (default `.current`), `windowSwitcherIncludeMinimized: Bool` (default true), `windowSwitcherIncludeHidden: Bool` (default true)
  - `KeyboardShortcuts.Name.windowSwitcher` (default ⌘Tab)
  - `extension SwitcherTrigger { init?(_ shortcut: KeyboardShortcuts.Shortcut) }`
  - `final class WindowSwitcher: ObservableObject` with `@Published var isEnabled`, `scope`, `includeMinimized`, `includeHidden`

- [ ] **Step 1: Add the preferences**

In `Sources/thetoolbox/Persistence/Preferences.swift`, add these keys to `enum PreferenceKey`, after `instantMissionControl`:

```swift
    static let windowSwitcherEnabled = "windowSwitcherEnabled.v1"
    static let windowSwitcherScope = "windowSwitcherScope.v1"
    static let windowSwitcherIncludeMinimized = "windowSwitcherIncludeMinimized.v1"
    static let windowSwitcherIncludeHidden = "windowSwitcherIncludeHidden.v1"
```

and add this section at the end of `final class Preferences`, after the `instantMissionControl` property:

```swift

    // MARK: Window switcher

    var windowSwitcherEnabled: Bool {
        get { defaults.object(forKey: PreferenceKey.windowSwitcherEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.windowSwitcherEnabled) }
    }

    var windowSwitcherScope: DesktopScope {
        get { defaults.string(forKey: PreferenceKey.windowSwitcherScope).flatMap(DesktopScope.init) ?? .current }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.windowSwitcherScope) }
    }

    var windowSwitcherIncludeMinimized: Bool {
        get { defaults.object(forKey: PreferenceKey.windowSwitcherIncludeMinimized) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.windowSwitcherIncludeMinimized) }
    }

    var windowSwitcherIncludeHidden: Bool {
        get { defaults.object(forKey: PreferenceKey.windowSwitcherIncludeHidden) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.windowSwitcherIncludeHidden) }
    }
```

- [ ] **Step 2: Add the shortcut name**

In `Sources/thetoolbox/Shortcuts/ShortcutNames.swift`, add before the closing `}` of the extension:

```swift

    /// Opens the window switcher. Only the recorder and the stored value are used; the switcher's
    /// own key tap reads it, so KeyboardShortcuts never registers it as a global hotkey.
    static let windowSwitcher = Self("windowSwitcher", default: .init(.tab, modifiers: .command))
```

- [ ] **Step 3: Create `WindowSwitcher.swift`**

```swift
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
        let snapshot: WindowSnapshot
        var selection: SwitcherSelection
        let screen: NSScreen
    }

    private let prefs = Preferences.shared
    private let keyTap = SwitcherKeyTap()
    private let inventory = WindowInventory()
    private let focuser = WindowFocuser()
    private let thumbnails = ThumbnailCapturer()
    private let panel = SwitcherPanel()
    private var session: Session?
    private var panelTimer: Timer?
    private var captureTask: Task<Void, Never>?
    private var startRetryTimer: Timer?

    init() {
        isEnabled = prefs.windowSwitcherEnabled
        scope = prefs.windowSwitcherScope
        includeMinimized = prefs.windowSwitcherIncludeMinimized
        includeHidden = prefs.windowSwitcherIncludeHidden

        keyTap.onCommand = { [weak self] command in self?.handle(command) }
        panel.onHover = { [weak self] index in self?.hover(index) }
        panel.onClick = { [weak self] index in self?.click(index) }

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

    private func handle(_ command: SwitcherCommand) {
        switch command {
        case let .begin(forward):
            if session != nil {
                updateSelection { forward ? $0.next() : $0.previous() }
            } else {
                begin(forward: forward)
            }
        case .next: updateSelection { $0.next() }
        case .previous: updateSelection { $0.previous() }
        case let .move(direction): updateSelection { $0.move(direction) }
        case .commit: endSession(focus: true)
        case .cancel: endSession(focus: false)
        }
    }

    private func begin(forward: Bool) {
        let options = WindowListOptions(scope: scope, includeMinimized: includeMinimized, includeHidden: includeHidden)
        let snapshot = inventory.snapshot(options: options)
        let mouse = NSEvent.mouseLocation
        guard !snapshot.windows.isEmpty,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else {
            keyTap.endSession()
            return
        }
        // Keep only as many windows as fit on screen; the least recent ones drop off.
        let visible = screen.visibleFrame
        let columns = SwitcherLayout.columns(count: snapshot.windows.count, availableWidth: visible.width * Self.screenFraction)
        let limit = columns * SwitcherLayout.maxRows(availableHeight: visible.height * Self.screenFraction)
        let windows = Array(snapshot.windows.prefix(limit))

        session = Session(
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
        panel.hide()
        keyTap.endSession()
        guard let ended = session else { return }
        session = nil
        guard focus, ended.snapshot.windows.indices.contains(ended.selection.index) else { return }
        let window = ended.snapshot.windows[ended.selection.index]
        focuser.focus(window, element: ended.snapshot.elements[window.id])
    }
}
```

- [ ] **Step 4: Create the manager in the app**

In `Sources/thetoolbox/App/ToolboxApp.swift`, add after `@StateObject private var spaceSwitcher = SpaceSwitcher()`:

```swift
    @StateObject private var windowSwitcher = WindowSwitcher()
```

and in the `Settings { ... }` scene, add after `.environmentObject(spaceSwitcher)`:

```swift
                .environmentObject(windowSwitcher)
```

- [ ] **Step 5: Build and run the existing unit tests**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherKeysTests -only-testing:thetoolboxTests/WindowListPolicyTests -only-testing:thetoolboxTests/SwitcherSelectionTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Smoke test on a real Mac**

1. Quit any running thetoolbox (menu bar icon → Quit), so two copies don't both tap ⌘Tab.
2. Run: `open build/Build/Products/Debug/thetoolbox.app`
3. If ⌘Tab still shows the macOS switcher, grant Accessibility (System Settings → Privacy & Security → Accessibility). Ad-hoc dev builds lose the grant on every rebuild: remove the old thetoolbox entry and add it again. It starts working within 2 seconds of the grant, with no relaunch.
4. Open three windows on this desktop (e.g. two Finder windows and a Safari window).
5. Quick ⌘Tab tap: you land on the previous window with no panel.
6. Hold ⌘ and press Tab: the panel appears with app icons (thumbnails come in Task 10 once Screen Recording is granted). Tab moves, release picks the selected window.
7. Hold ⌘, press Tab, then press Esc: the panel closes and focus doesn't change.

Expected: all of the above behave as described. If anything doesn't, fix it before committing (use superpowers:systematic-debugging).

- [ ] **Step 7: Commit**

```bash
git add Sources/thetoolbox/Persistence/Preferences.swift Sources/thetoolbox/Shortcuts/ShortcutNames.swift Sources/thetoolbox/WindowSwitcher/WindowSwitcher.swift Sources/thetoolbox/App/ToolboxApp.swift
git commit -F - <<'EOF'
Turn on the window switcher for Command-Tab

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 10: Settings tab, permission row, conflicts and README

**Files:**
- Create: `Sources/thetoolbox/Settings/ScreenRecordingStatusRow.swift`
- Create: `Sources/thetoolbox/Settings/WindowSwitcherSettingsView.swift`
- Modify: `Sources/thetoolbox/Settings/SettingsView.swift`
- Modify: `Sources/thetoolbox/Windows/WindowManager.swift:289`
- Modify: `README.md`

**Interfaces:**
- Consumes: `WindowSwitcher` (Task 9), `ScreenRecordingPermission` (Task 6), `SwitcherTrigger.init?(_ shortcut:)` (Task 9), `KeyboardShortcuts.Name.windowSwitcher` (Task 9), `DesktopScope` (Task 2), existing `AccessibilityStatusRow`, `WindowManager.resolveShortcutConflict(preferring:)`.
- Produces: `struct ScreenRecordingStatusRow: View`, `struct WindowSwitcherSettingsView: View`.

- [ ] **Step 1: Create `ScreenRecordingStatusRow.swift`**

```swift
import SwiftUI

/// Screen Recording permission status with a Grant button, matching `AccessibilityStatusRow`.
/// Re-checks whenever the app becomes active, e.g. after returning from System Settings.
struct ScreenRecordingStatusRow: View {
    @State private var granted = ScreenRecordingPermission.isGranted

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.statusGreen : Color.orange)
            Text(granted
                ? "Screen Recording access granted."
                : "Screen Recording access is needed for window thumbnails. Without it, app icons are shown.")
            Spacer()
            if !granted {
                Button("Grant…") { ScreenRecordingPermission.request() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = ScreenRecordingPermission.isGranted
        }
    }
}
```

- [ ] **Step 2: Create `WindowSwitcherSettingsView.swift`**

```swift
import KeyboardShortcuts
import SwiftUI

struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var windowSwitcher: WindowSwitcher
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        Form {
            Section("Permissions") {
                AccessibilityStatusRow(purpose: "switch windows")
                ScreenRecordingStatusRow()
            }

            Section {
                Toggle("Use the window switcher", isOn: $windowSwitcher.isEnabled)
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .windowSwitcher) { shortcut in
                        guard let shortcut else { return }
                        guard SwitcherTrigger(shortcut) != nil else {
                            // Releasing ⌘, ⌥ or ⌃ is what picks the window, so one is required.
                            NSSound.beep()
                            KeyboardShortcuts.reset(.windowSwitcher)
                            return
                        }
                        windowManager.resolveShortcutConflict(preferring: .windowSwitcher)
                    }
                }
                Button("Restore Default") {
                    KeyboardShortcuts.reset(.windowSwitcher)
                    windowManager.resolveShortcutConflict(preferring: .windowSwitcher)
                }
            } header: {
                Text("Switcher")
            } footer: {
                Text("Hold the shortcut's modifier and press its key to step through windows; release to switch. Add ⇧ to go backward, or use the arrow keys. The shortcut needs ⌘, ⌥ or ⌃. While on, it replaces the macOS app switcher on the same keys. If the recorder says a shortcut is used by the system, choose Use Anyway.")
            }

            Section("Windows") {
                Picker("Show windows from", selection: $windowSwitcher.scope) {
                    Text("Current desktop").tag(DesktopScope.current)
                    Text("All desktops").tag(DesktopScope.all)
                }
                Toggle("Include minimized windows", isOn: $windowSwitcher.includeMinimized)
                Toggle("Include windows of hidden apps", isOn: $windowSwitcher.includeHidden)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 3: Add the tab**

In `Sources/thetoolbox/Settings/SettingsView.swift`, add after the `WindowSettingsView()` tab (after its `.tabItem` line):

```swift
            WindowSwitcherSettingsView()
                .tabItem { Label("Switcher", systemImage: "rectangle.on.rectangle") }
```

- [ ] **Step 4: Include the switcher in shortcut conflict resolution**

In `Sources/thetoolbox/Windows/WindowManager.swift`, replace:

```swift
        for other in allShortcutNames + KeyboardShortcuts.Name.spaceShortcuts where other != name {
```

with:

```swift
        for other in allShortcutNames + KeyboardShortcuts.Name.spaceShortcuts + [.windowSwitcher] where other != name {
```

- [ ] **Step 5: Update the README**

In `README.md`, add this feature bullet right after the **Instant space switching** bullet (after the line ending `from their macOS keyboard shortcuts.`):

```markdown
- **Window switcher** — ⌘Tab shows every window on the current desktop, not just every app,
  with live thumbnails in a native macOS-style panel. Hold ⌘ and press Tab (⇧Tab or the arrow
  keys to move back and around, or point and click), then release ⌘ to switch; a quick ⌘Tab flips
  to the previous window without showing the panel. It replaces the macOS app switcher while it's
  on. Inspired by [DockWindow](https://github.com/KIKOmanasijev/DockWindow).
```

Add this usage bullet right after the **Spaces:** usage bullet (after the line `  Accessibility, like window management.`):

```markdown
- **Window switcher:** hold ⌘ and press Tab to step through this desktop's windows (Esc cancels);
  release ⌘ to switch. **Settings → Switcher** has the on/off switch, the shortcut (**Restore
  Default** puts back ⌘Tab), and whether to include other desktops, minimized windows and hidden
  apps. Needs Accessibility; thumbnails also need Screen Recording (app icons otherwise).
```

Add this permissions bullet right after the **Brightness-key routing** bullet (after the line `  also requires Accessibility.`):

```markdown
- **Window switcher** uses a session event tap for its shortcut and Accessibility to read and
  focus windows. Thumbnails use ScreenCaptureKit, which needs **Screen Recording** permission
  (System Settings → Privacy & Security → Screen & System Audio Recording); without it the
  switcher shows app icons. Images stay in memory and are never saved.
```

In the project structure list, replace:

```markdown
  `Windows`, `Spaces`, `Settings`, `Shortcuts`, `Persistence`).
```

with:

```markdown
  `Windows`, `WindowSwitcher`, `Spaces`, `Settings`, `Shortcuts`, `Persistence`).
```

- [ ] **Step 6: Build and check the Settings tab**

Run: `xcodegen generate && xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`

Then quit any running copy, `open build/Build/Products/Debug/thetoolbox.app`, open Settings → **Switcher**, and check:
- Both permission rows show; **Grant…** for Screen Recording shows the system prompt or opens the pane. After granting, quit and reopen thetoolbox; thumbnails then appear in the panel.
- Turning **Use the window switcher** off brings back the macOS switcher on ⌘Tab immediately; turning it on takes over again.
- Clicking the recorder and pressing ⌥Tab records it (choose **Use Anyway** if asked); ⌥Tab now opens the switcher and ⌘Tab is the macOS switcher again. Pressing ⌘Tab while the recorder is focused records ⌘Tab rather than switching apps. **Restore Default** puts back ⌘Tab.

- [ ] **Step 7: Commit**

```bash
git add Sources/thetoolbox/Settings/ScreenRecordingStatusRow.swift Sources/thetoolbox/Settings/WindowSwitcherSettingsView.swift Sources/thetoolbox/Settings/SettingsView.swift Sources/thetoolbox/Windows/WindowManager.swift README.md
git commit -F - <<'EOF'
Add the Switcher settings tab and document the window switcher

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 11: Full verification

No code changes unless a check fails. If one does, fix it with superpowers:systematic-debugging and commit the fix with a message that names the failing check.

- [ ] **Step 1: Run every unit test the switcher added, plus the existing offline tests**

Run: `xcodegen generate && xcodebuild test -scheme thetoolbox -configuration Debug -derivedDataPath build -only-testing:thetoolboxTests/SwitcherKeysTests -only-testing:thetoolboxTests/WindowListPolicyTests -only-testing:thetoolboxTests/SwitcherSelectionTests -only-testing:thetoolboxTests/DDCCapabilitiesTests -only-testing:thetoolboxTests/AIUsageResponseTests -only-testing:thetoolboxTests/ClaudeAuthenticationTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **` (`LiveAIUsageTests` is left out because it calls live services.)

- [ ] **Step 2: Walk the spec's manual checklist on a real Mac (phase 1 items)**

With the Debug build running, Accessibility granted and Screen Recording granted (then app relaunched):

1. A quick ⌘Tab flips to the previous window with no panel; holding shows the panel.
2. Tab, ⇧Tab, all four arrows (in a layout with 2+ rows), hover (only after moving the mouse), click, and Esc all behave as described in the spec.
3. Press ⌘Q while the panel is up: nothing quits.
4. Two displays (if available): the panel opens on the display under the mouse and lists windows from both displays' current desktops.
5. A fullscreen app (green button) appears in the list from a normal desktop, and picking it switches there.
6. Click into a password field (e.g. Safari's address bar on a login page, or a Keychain prompt), then press ⌘Tab: the macOS switcher appears (secure input fallback).
7. Settings → Switcher → turn the switcher off: ⌘Tab is the macOS switcher immediately. Turn it back on.
8. Revoke Screen Recording and relaunch: tiles show app icons; everything else works.
9. Set **Show windows from** to **All desktops**: windows from another desktop appear, and picking one switches to that desktop and window.

Expected: every item passes. Write down anything that doesn't and fix it before finishing.

- [ ] **Step 3: Confirm the tree is clean**

Run: `git status --short`
Expected: no output (everything committed).
