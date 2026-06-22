import SwiftUI

struct DisplaySettingsView: View {
    @EnvironmentObject private var displayManager: DisplayManager

    var body: some View {
        if displayManager.displays.isEmpty {
            ContentUnavailableView(
                "No Displays",
                systemImage: "display",
                description: Text("Connect a display to configure its brightness and contrast caps.")
            )
        } else {
            Form {
                Text("Each control can't go above its cap. In the menu the slider greys out the range above the cap and the thumb stops there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(displayManager.displays) { display in
                    Section(display.name) {
                        if display.canBrightness {
                            CapSliderRow(title: "Max brightness", value: Binding(
                                get: { displayManager.brightnessCap(for: display) },
                                set: { displayManager.setBrightnessCap($0, for: display) }
                            ))
                        }
                        if display.canContrast {
                            CapSliderRow(title: "Max contrast", value: Binding(
                                get: { displayManager.contrastCap(for: display) },
                                set: { displayManager.setContrastCap($0, for: display) }
                            ))
                        }
                        if display.kind == .external && display.canBrightness && displayManager.hasBuiltInDisplay {
                            BrightnessSyncControls(display: display)
                        }
                        if !display.canBrightness && !display.canContrast {
                            Text("No adjustable controls for this display.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct CapSliderRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Floor the cap at 10%: capping lower would make the slider effectively unusable.
            Slider(value: $value, in: 0.1 ... 1.0)
        }
    }
}

/// Per-external-display controls to follow the built-in display's brightness, with a
/// configurable linear mapping (external level at built-in 0% and at built-in 100%).
private struct BrightnessSyncControls: View {
    @EnvironmentObject private var displayManager: DisplayManager
    let display: ManagedDisplay

    var body: some View {
        Toggle("Follow built-in brightness", isOn: Binding(
            get: { displayManager.isBrightnessSynced(display) },
            set: { displayManager.setSyncEnabled($0, for: display) }
        ))
        if displayManager.isBrightnessSynced(display) {
            let range = displayManager.syncRange(for: display)
            SyncRangeRow(title: "External when built-in at 0%", value: Binding(
                get: { range.atMin },
                set: { displayManager.setSyncRange(atMin: $0, atMax: displayManager.syncRange(for: display).atMax, for: display) }
            ))
            SyncRangeRow(title: "External when built-in at 100%", value: Binding(
                get: { range.atMax },
                set: { displayManager.setSyncRange(atMin: displayManager.syncRange(for: display).atMin, atMax: $0, for: display) }
            ))
        }
    }
}

private struct SyncRangeRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0 ... 1)
        }
    }
}
