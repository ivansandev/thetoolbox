import KeyboardShortcuts
import SwiftUI

struct SpacesSettingsView: View {
    @EnvironmentObject private var spaceSwitcher: SpaceSwitcher
    @EnvironmentObject private var windowManager: WindowManager
    @State private var clashes: [SystemShortcuts.Clash] = []

    var body: some View {
        Form {
            Section("Permission") {
                AccessibilityStatusRow(purpose: "switch spaces")
            }

            if !clashes.isEmpty {
                Section {
                    clashWarning
                }
            }

            Section {
                Toggle("Instant trackpad swipes", isOn: $spaceSwitcher.instantSwipes)
            } footer: {
                Text("Swiping between spaces with three or four fingers switches instantly, without the slide animation.")
            }

            Section("Shortcuts") {
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
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshClashes)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClashes()
        }
    }

    private var clashWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text(clashMessage)
                Spacer()
                Button("Turn Off in macOS") {
                    spaceSwitcher.turnOffSystemShortcuts(clashes)
                    refreshClashes()
                }
            }
            Text("Turns off the matching shortcuts in System Settings → Keyboard → Keyboard Shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var clashMessage: String {
        var keys: [String] = []
        for clash in clashes where !keys.contains(clash.shortcut.description) {
            keys.append(clash.shortcut.description)
        }
        let list = ListFormatter.localizedString(byJoining: keys)
        return keys.count == 1
            ? "\(list) is also a macOS shortcut, which takes priority."
            : "\(list) are also macOS shortcuts, which take priority."
    }

    private func refreshClashes() {
        clashes = spaceSwitcher.systemShortcutClashes()
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name) { _ in
                windowManager.resolveShortcutConflict(preferring: name)
                refreshClashes()
            }
        }
    }
}
