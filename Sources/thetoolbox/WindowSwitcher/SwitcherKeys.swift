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
