import SwiftUI

/// The single menu-bar label. Enabled metrics replace the app symbol with live readings while
/// retaining one click target for thetoolbox's menu.
struct StatusBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage(PreferenceKey.statusBarCPU) private var showCPU = false
    @AppStorage(PreferenceKey.statusBarMemory) private var showMemory = false
    @AppStorage(PreferenceKey.statusBarStorage) private var showStorage = false

    var body: some View {
        Group {
            if selectedMetrics.isEmpty {
                Image(systemName: "wrench.and.screwdriver")
                    .accessibilityLabel("thetoolbox")
            } else {
                // MenuBarExtra maps a label to one native status-item title. A single Text keeps
                // all selected readings, whereas an HStack is truncated to its first child by
                // AppKit's status-item bridge.
                metricsText
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
            }
        }
        .onAppear { updatePolling() }
        .onChange(of: showCPU) { _, _ in updatePolling() }
        .onChange(of: showMemory) { _, _ in updatePolling() }
        .onChange(of: showStorage) { _, _ in updatePolling() }
    }

    private var metricsText: Text {
        var text = Text("")
        if showCPU {
            text = text + metricText(value: monitor.cpuUsage)
        }
        if showMemory {
            text = text + Text("  ") + metricText(value: monitor.pressureFraction)
        }
        if showStorage {
            text = text + Text("  ") + metricText(value: monitor.diskUsage)
        }
        return text
    }

    private func metricText(value: Double) -> Text {
        Text(percent(value))
    }

    private var selectedMetrics: StatusBarMetrics {
        var metrics: StatusBarMetrics = []
        if showCPU { metrics.insert(.cpu) }
        if showMemory { metrics.insert(.memory) }
        if showStorage { metrics.insert(.storage) }
        return metrics
    }

    private var accessibilityDescription: String {
        var readings: [String] = []
        if showCPU { readings.append("CPU utilization \(percent(monitor.cpuUsage))") }
        if showMemory { readings.append("RAM pressure \(percent(monitor.pressureFraction))") }
        if showStorage { readings.append("SSD usage \(percent(monitor.diskUsage))") }
        return readings.joined(separator: ", ")
    }

    private func updatePolling() {
        monitor.setStatusBarMetrics(selectedMetrics)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
