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
