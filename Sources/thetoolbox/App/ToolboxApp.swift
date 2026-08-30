import SwiftUI

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var windowManager = WindowManager()
    @StateObject private var powerManager = PowerManager()
    @StateObject private var presentationModeManager = PresentationModeManager()
    @StateObject private var systemMonitor = SystemMonitor()
    @StateObject private var keyboardCleaner = KeyboardCleaner()
    @StateObject private var aiUsageManager = AIUsageManager()

    var body: some Scene {
        // .window style is required so the dropdown can host SwiftUI controls
        // (sliders) rather than only menu items.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(displayManager)
                .environmentObject(windowManager)
                .environmentObject(powerManager)
                .environmentObject(presentationModeManager)
                .environmentObject(systemMonitor)
                .environmentObject(keyboardCleaner)
                .environmentObject(aiUsageManager)
        } label: {
            StatusBarLabel(monitor: systemMonitor, usageManager: aiUsageManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(displayManager)
                .environmentObject(windowManager)
                .environmentObject(powerManager)
                .environmentObject(presentationModeManager)
        }
    }
}
