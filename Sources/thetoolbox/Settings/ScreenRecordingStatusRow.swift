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
