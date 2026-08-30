import SwiftUI

/// The single menu-bar label. Enabled metrics replace the app symbol with live readings while
/// retaining one click target for thetoolbox's menu.
struct StatusBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var usageManager: AIUsageManager
    @AppStorage(PreferenceKey.statusBarCPU) private var showCPU = false
    @AppStorage(PreferenceKey.statusBarMemory) private var showMemory = false
    @AppStorage(PreferenceKey.statusBarStorage) private var showStorage = false
    @AppStorage(PreferenceKey.statusBarClaudeFiveHour) private var showClaudeFiveHour = false
    @AppStorage(PreferenceKey.statusBarChatGPTFiveHour) private var showChatGPTFiveHour = false
    @AppStorage(PreferenceKey.aiUsageEnabled) private var aiUsageEnabled = true

    var body: some View {
        Group {
            if !hasSelectedMetric {
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
        .onChange(of: showClaudeFiveHour) { _, _ in updateAIUsage() }
        .onChange(of: showChatGPTFiveHour) { _, _ in updateAIUsage() }
        .onChange(of: aiUsageEnabled) { _, _ in updateAIUsage() }
    }

    private var metricsText: Text {
        var parts: [Text] = []
        if showCPU { parts.append(metricText(value: monitor.cpuUsage)) }
        if showMemory { parts.append(metricText(value: monitor.pressureFraction)) }
        if showStorage { parts.append(metricText(value: monitor.diskUsage)) }
        if aiUsageEnabled && showClaudeFiveHour {
            parts.append(aiMetricText(label: "Claude", provider: .claude))
        }
        if aiUsageEnabled && showChatGPTFiveHour {
            parts.append(aiMetricText(label: "Codex", provider: .chatGPT))
        }

        guard let first = parts.first else { return Text("") }
        return parts.dropFirst().reduce(first) { $0 + Text("  ") + $1 }
    }

    private func metricText(value: Double) -> Text {
        Text(percent(value))
    }

    private func aiMetricText(label: String, provider: AIProviderID) -> Text {
        Text("\(label) \(fiveHourPercent(for: provider))")
    }

    private var hasSelectedMetric: Bool {
        !selectedMetrics.isEmpty || (aiUsageEnabled && (showClaudeFiveHour || showChatGPTFiveHour))
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
        if aiUsageEnabled && showClaudeFiveHour {
            readings.append("Claude five-hour usage remaining \(fiveHourPercent(for: .claude))")
        }
        if aiUsageEnabled && showChatGPTFiveHour {
            readings.append("Codex five-hour usage remaining \(fiveHourPercent(for: .chatGPT))")
        }
        return readings.joined(separator: ", ")
    }

    private func updatePolling() {
        monitor.setStatusBarMetrics(selectedMetrics)
        updateAIUsage()
    }

    private func updateAIUsage() {
        guard aiUsageEnabled else {
            usageManager.stop()
            return
        }
        var providers: Set<AIProviderID> = []
        if showClaudeFiveHour { providers.insert(.claude) }
        if showChatGPTFiveHour { providers.insert(.chatGPT) }
        usageManager.start(providers: providers)
    }

    private func fiveHourPercent(for provider: AIProviderID) -> String {
        guard let window = usageManager.states[provider]?.snapshot?.fiveHourSummaryWindow else {
            return "—"
        }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
