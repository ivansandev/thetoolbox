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
                shortcutRow("Center", .windowCenterFit)
                shortcutRow("Move to Left Display", .windowDisplayLeft)
                shortcutRow("Move to Right Display", .windowDisplayRight)
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
            KeyboardShortcuts.Recorder(for: name) { _ in
                windowManager.resolveShortcutConflict(preferring: name)
            }
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
                KeyboardShortcuts.Recorder(for: WindowManager.shortcutName(for: size.id)) { _ in
                    windowManager.resolveShortcutConflict(preferring: WindowManager.shortcutName(for: size.id))
                }
                Button(role: .destructive) {
                    windowManager.removeCustomSize(size)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            Text("\(percent(size.widthFraction)) × \(percent(size.heightFraction)) of screen · \(positionText(size))")
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
    @State private var xPos = 0.5
    @State private var yPos = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name (e.g. Top-right 40 × 50)", text: $name)
            sliderRow("Width", value: $width)
            sliderRow("Height", value: $height)
            sliderRow("Horizontal", value: $xPos, range: 0 ... 1)
            sliderRow("Vertical", value: $yPos, range: 0 ... 1)
            Text("Position: 0% = left/top edge · 50% = centered · 100% = right/bottom edge")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Add Custom Size") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                let centered = xPos == 0.5 && yPos == 0.5
                let fallback = centered
                    ? "Center \(percent(width)) × \(percent(height))"
                    : "\(percent(width)) × \(percent(height))"
                windowManager.addCustomSize(
                    name: trimmed.isEmpty ? fallback : trimmed,
                    widthFraction: width,
                    heightFraction: height,
                    xFraction: xPos,
                    yFraction: yPos
                )
                name = ""
            }
        }
        .padding(.top, 4)
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double> = 0.2 ... 1.0) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
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

private func positionText(_ size: CustomSize) -> String {
    if abs(size.xFraction - 0.5) < 0.001, abs(size.yFraction - 0.5) < 0.001 {
        return "centered"
    }
    return "pos H \(percent(size.xFraction)) · V \(percent(size.yFraction))"
}
