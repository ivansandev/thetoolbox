import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaySettingsView()
                .tabItem { Label("Displays", systemImage: "display") }
            WindowSettingsView()
                .tabItem { Label("Windows", systemImage: "macwindow") }
        }
        .frame(width: 520, height: 420)
    }
}
