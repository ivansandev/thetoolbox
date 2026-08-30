import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(PreferenceKey.statusBarCPU) private var showCPU = false
    @AppStorage(PreferenceKey.statusBarMemory) private var showMemory = false
    @AppStorage(PreferenceKey.statusBarStorage) private var showStorage = false
    @AppStorage(PreferenceKey.statusBarClaudeFiveHour) private var showClaudeFiveHour = false
    @AppStorage(PreferenceKey.statusBarChatGPTFiveHour) private var showChatGPTFiveHour = false
    @AppStorage(PreferenceKey.aiUsageEnabled) private var aiUsageEnabled = true

    var body: some View {
        Form {
            Toggle("Launch thetoolbox at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        NSLog("thetoolbox: launch-at-login toggle failed: \(error)")
                    }
                }

            Section {
                Toggle("Enable AI usage", isOn: $aiUsageEnabled)
            } footer: {
                Text("Shows Claude and Codex subscription limits in the menu and allows their five-hour limits in the status bar. Turning this off stops usage requests.")
            }

            Section("Status bar metrics") {
                Toggle("CPU utilization", isOn: $showCPU)
                Toggle("RAM pressure", isOn: $showMemory)
                Toggle("SSD usage", isOn: $showStorage)
                Divider()
                Toggle("Claude 5-hour limit", isOn: $showClaudeFiveHour)
                    .disabled(!aiUsageEnabled)
                Toggle("Codex 5-hour limit", isOn: $showChatGPTFiveHour)
                    .disabled(!aiUsageEnabled)
            }
            .toggleStyle(.checkbox)

            Section {
                Toggle("Brightness keys control the display under the pointer", isOn: Binding(
                    get: { displayManager.brightnessKeysFollowCursor },
                    set: { displayManager.brightnessKeysFollowCursor = $0 }
                ))
            } footer: {
                Text("Requires Accessibility permission. The built-in display keeps the standard macOS behavior.")
            }
        }
        .formStyle(.grouped)
    }
}
