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

/// Caffeine-style power control: keep the Mac awake (prevent idle *display* sleep, which keeps the
/// screen lit and therefore the system awake too) for a chosen duration. Preventing display sleep
/// is what the "Caffeine" app does — using the weaker system-only assertion let the screen go dark
/// on the idle timer, which reads as "not working".
final class PowerManager: ObservableObject {
    /// Current slider position. Setting it to anything but `.off` starts keep-awake.
    @Published private(set) var stop: KeepAwakeStop = .off
    /// When a timed auto-off is armed, the moment it fires; nil for `.off` and `.unlimited`.
    @Published private(set) var autoOffDeadline: Date?
    /// Persistent system-wide `pmset disablesleep` state. Unlike the assertion above, this also
    /// blocks explicit and lid-close sleep and survives app restarts.
    @Published private(set) var systemSleepDisabled = false
    @Published private(set) var isChangingSystemSleep = false
    @Published private(set) var systemSleepError: String?

    var keepAwake: Bool { stop != .off }

    private var assertionID: IOPMAssertionID = 0
    private var autoOffTimer: Timer?

    init() {
        refreshSystemSleepState()
        #if DEBUG
        if ProcessInfo.processInfo.environment["THETOOLBOX_KEEPAWAKE_TEST"] == "1" {
            setStop(.h2)
            NSLog("thetoolbox keepAwake test: stop=\(stop) deadline=\(String(describing: autoOffDeadline)) remaining=\(autoOffRemainingText)")
        }
        #endif
    }

    /// Reads the kernel's effective state rather than trusting an app preference; the user may
    /// also change this setting directly with `pmset` while the Toolbox is not running.
    func refreshSystemSleepState() {
        systemSleepDisabled = Self.readSystemSleepDisabled()
    }

    /// Applies the same system-wide setting as `sudo pmset -a disablesleep 1|0`. AppleScript's
    /// administrator-privileges clause presents the standard macOS authorization dialog, so the
    /// app never requests, receives, or stores an administrator password.
    func setSystemSleepDisabled(_ disabled: Bool) {
        guard !isChangingSystemSleep, disabled != systemSleepDisabled else { return }
        isChangingSystemSleep = true
        systemSleepError = nil

        let value = disabled ? 1 : 0
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        var scriptError: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&scriptError)

        systemSleepDisabled = Self.readSystemSleepDisabled()
        isChangingSystemSleep = false

        guard systemSleepDisabled != disabled else { return }
        let errorNumber = scriptError?[NSAppleScript.errorNumber] as? Int
        if errorNumber == -128 {
            // The user cancelled the administrator dialog; the unchanged toggle is enough.
            return
        }
        systemSleepError = disabled
            ? "The Mac could not be set to stay awake."
            : "Normal Mac sleep could not be restored."
    }

    func dismissSystemSleepError() {
        systemSleepError = nil
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
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
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

    private static func readSystemSleepDisabled() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", "IOPMrootDomain", "-d", "1"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return false }
            return parseSystemSleepDisabled(text)
        } catch {
            return false
        }
    }

    static func parseSystemSleepDisabled(_ text: String) -> Bool {
        text.range(
            of: #""SleepDisabled"\s*=\s*(Yes|True|1)"#,
            options: .regularExpression
        ) != nil
    }

    deinit {
        autoOffTimer?.invalidate()
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}
