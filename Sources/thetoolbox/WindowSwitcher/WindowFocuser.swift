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
