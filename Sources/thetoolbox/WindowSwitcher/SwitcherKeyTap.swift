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
