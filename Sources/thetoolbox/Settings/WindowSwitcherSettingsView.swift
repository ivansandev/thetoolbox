import KeyboardShortcuts
import SwiftUI

struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var windowSwitcher: WindowSwitcher
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        Form {
            Section("Permissions") {
                AccessibilityStatusRow(purpose: "switch windows")
                ScreenRecordingStatusRow()
            }

            Section {
                Toggle("Use the window switcher", isOn: $windowSwitcher.isEnabled)
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .windowSwitcher) { shortcut in
                        guard let shortcut else { return }
                        guard SwitcherTrigger(shortcut) != nil else {
                            // Releasing ⌘, ⌥ or ⌃ is what picks the window, so one is required.
                            NSSound.beep()
                            KeyboardShortcuts.reset(.windowSwitcher)
                            return
                        }
                        windowManager.resolveShortcutConflict(preferring: .windowSwitcher)
                    }
                }
                Button("Restore Default") {
                    KeyboardShortcuts.reset(.windowSwitcher)
                    windowManager.resolveShortcutConflict(preferring: .windowSwitcher)
                }
            } header: {
                Text("Switcher")
            } footer: {
                Text("Hold the shortcut's modifier and press its key to step through windows; release to switch. Add ⇧ to go backward, or use the arrow keys. The shortcut needs ⌘, ⌥ or ⌃. While on, it replaces the macOS app switcher on the same keys. If the recorder says a shortcut is used by the system, choose Use Anyway.")
            }

            Section("Windows") {
                Picker("Show windows from", selection: $windowSwitcher.scope) {
                    Text("Current desktop").tag(DesktopScope.current)
                    Text("All desktops").tag(DesktopScope.all)
                }
                Toggle("Include minimized windows", isOn: $windowSwitcher.includeMinimized)
                Toggle("Include windows of hidden apps", isOn: $windowSwitcher.includeHidden)
            }
        }
        .formStyle(.grouped)
    }
}
