import Foundation
import IOKit.pwr_mgt

/// Discrete keep-awake durations, left to right on the slider. `.off` disables keep-awake;
/// `.unlimited` keeps it on with no auto-off. The intermediate steps grow roughly logarithmically.
enum KeepAwakeStop: Int, CaseIterable, Identifiable {
    case off, m15, m30, h1, h2, h4, unlimited

    var id: Int { rawValue }

    /// Auto-off duration in minutes; nil for `.off` and `.unlimited` (no timer).
    var minutes: Int? {
        switch self {
        case .off, .unlimited: return nil
        case .m15: return 15
        case .m30: return 30
        case .h1: return 60
        case .h2: return 120
        case .h4: return 240
        }
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .m15: return "15m"
        case .m30: return "30m"
        case .h1: return "1h"
        case .h2: return "2h"
        case .h4: return "4h"
        case .unlimited: return "∞"
        }
    }
}

/// Caffeine-style power control: keep the Mac awake (prevent idle *system* sleep, which still
/// allows the display to sleep) for a chosen duration, and turn the display off on demand.
final class PowerManager: ObservableObject {
    /// Current slider position. Setting it to anything but `.off` starts keep-awake.
    @Published private(set) var stop: KeepAwakeStop = .off
    /// When a timed auto-off is armed, the moment it fires; nil for `.off` and `.unlimited`.
    @Published private(set) var autoOffDeadline: Date?

    var keepAwake: Bool { stop != .off }

    private var assertionID: IOPMAssertionID = 0
    private var autoOffTimer: Timer?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["THETOOLBOX_KEEPAWAKE_TEST"] == "1" {
            setStop(.h2)
            NSLog("thetoolbox keepAwake test: stop=\(stop) deadline=\(String(describing: autoOffDeadline)) remaining=\(autoOffRemainingText)")
        }
        #endif
    }

    /// Picks a duration and (re)starts keep-awake, or stops it when `.off`.
    func setStop(_ newStop: KeepAwakeStop) {
        guard newStop != stop else { return }
        stop = newStop
        if newStop == .off {
            teardown()
        } else {
            ensureAssertion()
            scheduleAutoOff()
        }
    }

    /// Turns the display off immediately via `pmset displaysleepnow` (works on Apple Silicon and
    /// needs no privileges). If keep-awake is on, the system stays running with the screen dark.
    func turnOffDisplay() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    /// Remaining time until auto-off, formatted "m:ss" (or "h:mm:ss"); empty when there's no
    /// active timer.
    var autoOffRemainingText: String {
        guard let deadline = autoOffDeadline else { return "" }
        let total = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func ensureAssertion() {
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "thetoolbox keep awake" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            stop = .off   // creation failed; reflect that we're not awake
        }
    }

    private func scheduleAutoOff() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        guard let minutes = stop.minutes, minutes > 0 else {
            autoOffDeadline = nil   // .unlimited (or .off) → no timer
            return
        }
        let interval = TimeInterval(minutes * 60)
        autoOffDeadline = Date().addingTimeInterval(interval)
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.setStop(.off)
        }
    }

    private func teardown() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDeadline = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    deinit {
        autoOffTimer?.invalidate()
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}
