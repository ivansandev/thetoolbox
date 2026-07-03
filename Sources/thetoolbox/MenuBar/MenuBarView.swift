import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showSystemMonitors.v1") private var showMonitors = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("thetoolbox")
                .font(.headline)

            if showMonitors {
                MonitorSection()
                Divider()
            }

            if displayManager.displays.isEmpty {
                Text("No controllable displays detected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayManager.displays) { display in
                    DisplayControlRow(display: display)
                }
            }

            Divider()

            WindowSection()

            Divider()

            PowerSection()

            Divider()

            DesktopSection()

            Divider()

            HStack {
                Button("Settings…") {
                    // Accessory (LSUIElement) apps don't auto-activate when a window opens, so
                    // the Settings window can appear behind others. Activate first, then open.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Quick window actions for the frontmost app, plus the user's custom sizes.
private struct WindowSection: View {
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 6) {
                actionButton("rectangle.lefthalf.inset.filled", "Left Half") { windowManager.perform(.leftHalf) }
                actionButton("rectangle.righthalf.inset.filled", "Right Half") { windowManager.perform(.rightHalf) }
                actionButton("rectangle.center.inset.filled", "Center") { windowManager.center() }
                actionButton("rectangle.inset.filled", "Maximize") { windowManager.perform(.maximize) }
            }

            ForEach(windowManager.customSizes) { size in
                Button {
                    windowManager.apply(size)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.center.inset.filled")
                            .foregroundStyle(.secondary)
                        Text(size.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionButton(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

/// Caffeine-style controls: keep the Mac awake for a chosen duration, and turn the display off.
private struct PowerSection: View {
    @EnvironmentObject private var powerManager: PowerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                Text("Keep Mac awake")
                Spacer()
                statusLabel
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Snaps to the discrete stops; moving off "Off" starts keep-awake at that duration.
            Slider(
                value: Binding(
                    get: { Double(powerManager.stop.rawValue) },
                    set: { powerManager.setStop(KeepAwakeStop(rawValue: Int($0.rounded())) ?? .off) }
                ),
                in: 0 ... Double(KeepAwakeStop.allCases.count - 1),
                step: 1
            )

            HStack(spacing: 0) {
                ForEach(KeepAwakeStop.allCases) { stop in
                    Text(stop.label)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .fontWeight(stop == powerManager.stop ? .bold : .regular)
                        .foregroundStyle(stop == powerManager.stop ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            Button {
                powerManager.turnOffDisplay()
            } label: {
                Label("Turn Off Display", systemImage: "display")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Sleeps the display now. With keep-awake on, the system stays running.")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if powerManager.stop == .off {
            EmptyView()
        } else if powerManager.autoOffDeadline != nil {
            // Counts down live; ticks only while the menu is open.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("Auto-off in \(powerManager.autoOffRemainingText)")
                    .monospacedDigit()
            }
        } else {
            Text("Keeping awake")
        }
    }
}

/// Toggles for desktop icons and desktop widgets.
private struct DesktopSection: View {
    @EnvironmentObject private var desktopManager: DesktopManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Desktop")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle("Desktop icons", isOn: Binding(
                get: { desktopManager.iconsVisible },
                set: { desktopManager.setIconsVisible($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("Desktop widgets", isOn: Binding(
                get: { desktopManager.widgetsVisible },
                set: { desktopManager.setWidgetsVisible($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

/// Brightness / contrast / volume sliders for a single display.
private struct DisplayControlRow: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @ObservedObject var display: ManagedDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(display.name)
                .font(.subheadline)
                .fontWeight(.medium)

            if display.canBrightness {
                let synced = display.kind == .external && displayManager.isBrightnessSynced(display)
                SliderRow(icon: synced ? "link" : "sun.max", value: Binding(
                    get: { display.brightnessUI },
                    set: { displayManager.setBrightness($0, for: display) }
                ), cap: displayManager.brightnessCap(for: display))
                .disabled(synced)
            }
            if display.canContrast {
                SliderRow(icon: "circle.lefthalf.filled", value: Binding(
                    get: { display.contrastUI },
                    set: { displayManager.setContrast($0, for: display) }
                ), cap: displayManager.contrastCap(for: display))
            }
            if display.canVolume {
                SliderRow(icon: "speaker.wave.2.fill", value: Binding(
                    get: { display.volumeUI },
                    set: { displayManager.setVolume($0, for: display) }
                ))
            }
            if !display.canBrightness && !display.canContrast && !display.canVolume {
                Text("No DDC control available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliderRow: View {
    let icon: String
    @Binding var value: Double
    var cap: Double = 1.0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            CappedSlider(value: $value, cap: cap)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
