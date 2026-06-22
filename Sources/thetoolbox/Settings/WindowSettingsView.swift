import KeyboardShortcuts
import SwiftUI

struct WindowSettingsView: View {
    @EnvironmentObject private var windowManager: WindowManager
    @State private var accessibilityGranted = AccessibilityPermission.isGranted

    var body: some View {
        Form {
            Section("Permission") {
                HStack(spacing: 8) {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                    Text(accessibilityGranted
                         ? "Accessibility access granted."
                         : "Accessibility access is required to move windows.")
                    Spacer()
                    if !accessibilityGranted {
                        Button("Grant…") { AccessibilityPermission.prompt() }
                    }
                }
            }

            Section("Built-in Shortcuts") {
                shortcutRow("Left Half", .windowLeftHalf)
                shortcutRow("Right Half", .windowRightHalf)
                shortcutRow("Top Half", .windowTopHalf)
                shortcutRow("Bottom Half", .windowBottomHalf)
                shortcutRow("Maximize", .windowMaximize)
                shortcutRow("Center (keep size)", .windowCenter)
            }

            Section("Custom Sizes") {
                if windowManager.customSizes.isEmpty {
                    Text("No custom sizes yet. Add one below — perfect for centering an app at, say, 60% × 80% on a 4K screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(windowManager.customSizes) { size in
                    CustomSizeRow(size: size)
                }
                AddCustomSizeRow()
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
        }
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

private struct CustomSizeRow: View {
    @EnvironmentObject private var windowManager: WindowManager
    let size: CustomSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(size.name).fontWeight(.medium)
                Spacer()
                KeyboardShortcuts.Recorder(for: WindowManager.shortcutName(for: size.id))
                Button(role: .destructive) {
                    windowManager.removeCustomSize(size)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Text("\(percent(size.widthFraction)) × \(percent(size.heightFraction)) of screen, centered")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddCustomSizeRow: View {
    @EnvironmentObject private var windowManager: WindowManager
    @State private var name = ""
    @State private var width = 0.6
    @State private var height = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name (e.g. Center 60 × 80)", text: $name)
            sliderRow("Width", value: $width)
            sliderRow("Height", value: $height)
            Button("Add Custom Size") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                let fallback = "Center \(percent(width)) × \(percent(height))"
                windowManager.addCustomSize(
                    name: trimmed.isEmpty ? fallback : trimmed,
                    widthFraction: width,
                    heightFraction: height
                )
                name = ""
            }
        }
        .padding(.top, 4)
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: value, in: 0.2 ... 1.0)
            Text(percent(value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}
