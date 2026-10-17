import SwiftUI

/// Accessibility permission status with a Grant button. Re-checks whenever the app becomes
/// active, e.g. after returning from System Settings.
struct AccessibilityStatusRow: View {
    /// Completes "Accessibility access is required to …", e.g. "move windows".
    let purpose: String
    @State private var granted = AccessibilityPermission.isGranted

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.statusGreen : Color.orange)
            Text(message)
            Spacer()
            if !granted {
                Button("Grant…") { AccessibilityPermission.prompt() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = AccessibilityPermission.isGranted
        }
    }

    private var message: String {
        granted ? "Accessibility access granted." : "Accessibility access is required to \(purpose)."
    }
}
