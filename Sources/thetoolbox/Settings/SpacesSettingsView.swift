import KeyboardShortcuts
import SwiftUI

struct SpacesSettingsView: View {
    @EnvironmentObject private var spaceSwitcher: SpaceSwitcher
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        Form {
            Section("Permission") {
                AccessibilityStatusRow(purpose: "switch spaces")
            }

            Section {
                Toggle("Instant trackpad swipes", isOn: $spaceSwitcher.instantSwipes)
            } footer: {
                Text("Swiping between spaces with three or four fingers switches instantly, without the slide animation.")
            }

            Section {
                Toggle("Instant Mission Control and App Exposé", isOn: $spaceSwitcher.instantMissionControl)
            } footer: {
                Text("Their keyboard shortcuts open them without the zoom animation. Set the shortcuts in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
            }

            Section {
                shortcutRow("Previous Space", .spacePrevious)
                shortcutRow("Next Space", .spaceNext)
                ForEach(1 ... 10, id: \.self) { number in
                    shortcutRow("Space \(number)", .switchToSpace(number))
                }
                DisclosureGroup("Spaces 11–\(SpaceSwitcher.maxSpaces)") {
                    ForEach(11 ... SpaceSwitcher.maxSpaces, id: \.self) { number in
                        shortcutRow("Space \(number)", .switchToSpace(number))
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("These work even when macOS uses the same keys, like ⌃← and ⌃→. If the recorder says a shortcut is used by the system, choose Use Anyway.")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name) { _ in
                windowManager.resolveShortcutConflict(preferring: name)
            }
        }
    }
}
