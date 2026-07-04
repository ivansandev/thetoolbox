import SwiftUI

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var windowManager = WindowManager()
    @StateObject private var powerManager = PowerManager()
    @StateObject private var desktopManager = DesktopManager()
    @StateObject private var systemMonitor = SystemMonitor()
    @StateObject private var keyboardCleaner = KeyboardCleaner()

    var body: some Scene {
        // .window style is required so the dropdown can host SwiftUI controls
        // (sliders) rather than only menu items.
        MenuBarExtra("thetoolbox", systemImage: "wrench.and.screwdriver") {
            MenuBarView()
                .environmentObject(displayManager)
                .environmentObject(windowManager)
                .environmentObject(powerManager)
                .environmentObject(desktopManager)
                .environmentObject(systemMonitor)
                .environmentObject(keyboardCleaner)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(displayManager)
                .environmentObject(windowManager)
                .environmentObject(powerManager)
                .environmentObject(desktopManager)
        }
    }
}
