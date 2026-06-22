import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
