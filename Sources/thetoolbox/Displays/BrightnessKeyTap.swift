import AppKit
import ApplicationServices

/// Intercepts the system brightness keys via a session CGEventTap so we can route them to the
/// display under the pointer. Requires Accessibility permission; `start()` is idempotent and
/// safe to retry once permission has been granted.
final class BrightnessKeyTap {
    /// Called for each brightness key event. `up` is the brightness-up key; `isKeyDown`
    /// distinguishes press from release. Return true to consume the event (we handled it),
    /// false to pass it through to macOS.
    var handler: ((_ up: Bool, _ isKeyDown: Bool) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let systemDefinedType: UInt32 = 14   // NX_SYSDEFINED
    private let auxButtonsSubtype = 8            // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private let brightnessUp = 2                 // NX_KEYTYPE_BRIGHTNESS_UP
    private let brightnessDown = 3               // NX_KEYTYPE_BRIGHTNESS_DOWN

    var isRunning: Bool { eventTap != nil }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << systemDefinedType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is slow or interrupted; just re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              Int(nsEvent.subtype.rawValue) == auxButtonsSubtype else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        guard keyCode == brightnessUp || keyCode == brightnessDown else {
            return Unmanaged.passUnretained(event)
        }

        let isKeyDown = ((data1 & 0x0000_FF00) >> 8) == 0x0A
        let consumed = handler?(keyCode == brightnessUp, isKeyDown) ?? false
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    deinit { stop() }
}

private func brightnessTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
