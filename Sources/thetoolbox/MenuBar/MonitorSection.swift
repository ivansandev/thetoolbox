import SwiftUI

/// Which monitor's detail card is expanded, if any. Owned by `MenuBarView` so it can switch the
/// popover to a scrolling layout while a (potentially tall) card is open.
enum MonitorMetric { case cpu, memory, storage }

/// The three system-monitor gauges (CPU / Memory / Storage) with click-to-expand detail cards.
/// Polling runs only while this view is on screen, i.e. while the menu is open.
struct MonitorSection: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var expanded: MonitorMetric?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                gauge(.cpu, "cpu", monitor.cpuUsage, "CPU",
                      tip: "CPU · \(pct(monitor.cpuUsage)) · load \(load1)")
                gauge(.memory, "memorychip", monitor.pressureFraction, "Memory",
                      tip: "Memory pressure · \(pressureLabel(monitor.pressure))")
                gauge(.storage, "internaldrive", monitor.diskUsage, "Storage",
                      tip: "\(monitor.diskName) · \(Format.bytes(monitor.diskUsed, style: .file)) / \(Format.bytes(monitor.diskTotal, style: .file))")
            }

            if let expanded {
                detail(for: expanded)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop(); expanded = nil }
    }

    private func gauge(_ metric: MonitorMetric, _ symbol: String, _ value: Double, _ label: String, tip: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                expanded = (expanded == metric) ? nil : metric
            }
        } label: {
            VStack(spacing: 5) {
                RingGauge(value: value, systemImage: symbol)
                Text(pct(value))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(heatColor(value))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(expanded == metric ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    @ViewBuilder
    private func detail(for metric: MonitorMetric) -> some View {
        switch metric {
        case .cpu: CPUDetail()
        case .memory: MemoryDetail()
        case .storage: StorageDetail()
        }
    }

    private var load1: String {
        String(format: "%.1f", monitor.loadAverages.first ?? 0)
    }
}

/// A circular utilization ring with a centered SF Symbol; color tracks load.
struct RingGauge: View {
    let value: Double
    let systemImage: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(heatColor(value), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: value)
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .frame(width: 46, height: 46)
    }
}

/// Green ≤ 70%, amber 70–90%, red > 90% — a glance across the row shows what's under load.
func heatColor(_ value: Double) -> Color {
    value > 0.90 ? .red : value > 0.70 ? .orange : .green
}

private func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

private func pressureLabel(_ pressure: MemPressure) -> String {
    switch pressure {
    case .normal: return "Normal"
    case .warning: return "Warning"
    case .critical: return "Critical"
    }
}

// MARK: - Detail cards

private struct DetailCard<Content: View>: View {
    let title: String
    let systemImage: String
    let trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text(trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

private struct KV: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }
}

private struct TopList: View {
    let title: String
    let items: [ProcInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            if items.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(item.value).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5))
            }
        }
    }
}

private struct CPUDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var body: some View {
        DetailCard(title: "CPU", systemImage: "cpu", trailing: pct(monitor.cpuUsage)) {
            SplitBar(user: monitor.cpuUser, system: monitor.cpuSystem)
            KV(key: "Load average (1 · 5 · 15 min)", value: monitor.loadAverages.map { String(format: "%.1f", $0) }.joined(separator: " · "))
            KV(key: "Cores", value: monitor.coreSummary)
            if !monitor.fans.isEmpty {
                Text("Fans")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                ForEach(monitor.fans) { fan in
                    KV(key: fan.name, value: "\(fan.rpm) RPM")
                }
            }
            Divider().padding(.vertical, 1)
            TopList(title: "Top by CPU", items: monitor.topCPU)
        }
    }
}

/// User (accent) vs system (grey) share of total CPU, drawn as one proportional bar.
private struct SplitBar: View {
    let user: Double
    let system: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * user)
                    Rectangle().fill(Color.secondary).frame(width: geo.size.width * system)
                    Rectangle().fill(Color.primary.opacity(0.10))
                }
            }
            .frame(height: 7)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 12) {
                legend(.accentColor, "User", user)
                legend(.secondary, "System", system)
            }
        }
    }
    private func legend(_ color: Color, _ label: String, _ value: Double) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(label) \(pct(value))").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var body: some View {
        DetailCard(title: "Memory", systemImage: "memorychip",
                   trailing: "\(pressureLabel(monitor.pressure)) · \(pct(monitor.pressureFraction))") {
            MemoryBar(app: fraction(monitor.memApp), wired: fraction(monitor.memWired),
                      compressed: fraction(monitor.memCompressed))
            HStack(spacing: 12) {
                legend(.accentColor, "App", monitor.memApp)
                legend(.secondary, "Wired", monitor.memWired)
                legend(.orange, "Compressed", monitor.memCompressed)
            }
            KV(key: "Memory used", value: "\(Format.bytes(monitor.memUsed)) / \(Format.bytes(monitor.memTotal)) · \(pct(monitor.memUsage))")
            KV(key: "Swap used", value: Format.bytes(monitor.swapUsed))
            Divider().padding(.vertical, 1)
            TopList(title: "Top by memory", items: monitor.topMemory)
        }
    }
    private func fraction(_ bytes: UInt64) -> Double {
        monitor.memTotal > 0 ? Double(bytes) / Double(monitor.memTotal) : 0
    }
    private func legend(_ color: Color, _ label: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(label) \(Format.bytes(bytes))").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryBar: View {
    let app: Double
    let wired: Double
    let compressed: Double
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: geo.size.width * app)
                Rectangle().fill(Color.secondary).frame(width: geo.size.width * wired)
                Rectangle().fill(Color.orange).frame(width: geo.size.width * compressed)
                Rectangle().fill(Color.primary.opacity(0.10))
            }
        }
        .frame(height: 7)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct StorageDetail: View {
    @EnvironmentObject private var monitor: SystemMonitor
    var body: some View {
        DetailCard(title: "Storage — \(monitor.diskName)", systemImage: "internaldrive",
                   trailing: "\(Format.bytes(monitor.diskUsed, style: .file)) / \(Format.bytes(monitor.diskTotal, style: .file))") {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(heatColor(monitor.diskUsage)).frame(width: geo.size.width * monitor.diskUsage)
                    Rectangle().fill(Color.primary.opacity(0.10))
                }
            }
            .frame(height: 7)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            KV(key: "Free", value: Format.bytes(freeBytes, style: .file))
            KV(key: "Used", value: "\(Format.bytes(monitor.diskUsed, style: .file)) · \(pct(monitor.diskUsage))")
        }
    }
    private var freeBytes: UInt64 {
        monitor.diskTotal > monitor.diskUsed ? monitor.diskTotal - monitor.diskUsed : 0
    }
}
