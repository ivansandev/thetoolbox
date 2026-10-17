import AppKit
import ApplicationServices

/// Sees key presses through a session CGEventTap, ahead of macOS's own keyboard shortcuts. That's
/// what lets a space shortcut use the same keys as Mission Control (⌃← / ⌃→): a regular global
/// hotkey would lose to the system. Requires Accessibility; `start()` is idempotent and safe to
/// retry once permission has been granted.
final class KeyDownTap {
    /// Called for every key-down. Return true to consume the event, false to pass it on.
    var handler: ((CGEvent) -> Bool)?

    private var eventTap: CFMachPort?

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: keyDownTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is slow or interrupted; just re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, handler?(event) == true else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }
}

private func keyDownTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyDownTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
