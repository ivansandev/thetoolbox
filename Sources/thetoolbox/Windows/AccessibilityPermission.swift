import ApplicationServices

/// Thin wrapper around the Accessibility (AX) trust check required to move other apps' windows.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Prompts the user (and registers the app in System Settings → Privacy & Security →
    /// Accessibility). Using the literal key value avoids SDK-version type differences for the
    /// imported `kAXTrustedCheckOptionPrompt` constant.
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
