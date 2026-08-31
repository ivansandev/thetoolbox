import SwiftUI

/// Collapsible Claude and ChatGPT subscription usage, kept compact so the main Toolbox menu does
/// not grow until the user asks for the details.
struct AIUsageSection: View {
    @EnvironmentObject private var usageManager: AIUsageManager
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 8) {
                ForEach(AIProviderID.allCases) { provider in
                    AIProviderUsageCard(
                        provider: provider,
                        state: usageManager.states[provider] ?? .loading,
                        refreshError: usageManager.refreshErrors[provider]
                    )
                }

                HStack {
                    Text("Refreshes every 5 minutes")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await usageManager.refresh() }
                    } label: {
                        if usageManager.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh AI usage")
                    .disabled(usageManager.isRefreshing)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("AI Usage")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("Claude \(usageManager.summary(for: .claude)) · ChatGPT \(usageManager.summary(for: .chatGPT))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Shared weekly limits remaining")
            }
        }
        .onAppear { usageManager.start() }
    }
}

private struct AIProviderUsageCard: View {
    let provider: AIProviderID
    let state: AIProviderAvailability
    let refreshError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: provider == .claude ? "sparkles" : "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                Text(provider.displayName)
                    .fontWeight(.semibold)
                Spacer()
                if let plan = state.snapshot?.planName, !plan.isEmpty {
                    Text(plan.replacingOccurrences(of: "_", with: " ").capitalized)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))

            switch state {
            case .loading:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Loading usage…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            case let .available(snapshot, isStale):
                ForEach(snapshot.windows) { window in
                    AIUsageWindowRow(window: window)
                }

                HStack {
                    if isStale {
                        Label(
                            refreshError.map { "Saved · \($0)" } ?? "Saved usage",
                            systemImage: refreshError == nil ? "clock" : "exclamationmark.triangle.fill"
                        )
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        AIUsageUpdatedLabel(date: snapshot.fetchedAt)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .font(.system(size: 9))

            case let .unavailable(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
    }
}

private struct AIUsageWindowRow: View {
    let window: AIUsageWindow

    private var color: Color {
        switch window.remainingPercent {
        case ..<10: return .red
        case ..<25: return .orange
        default: return .statusGreen
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayName)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            .font(.system(size: 10.5))

            ProgressView(value: window.remainingPercent, total: 100)
                .progressViewStyle(.linear)
                .tint(color)
                .accessibilityLabel("\(window.displayName) remaining")
                .accessibilityValue("\(Int(window.remainingPercent.rounded())) percent")

            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct AIUsageUpdatedLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let minutes = max(0, Int(context.date.timeIntervalSince(date) / 60))
            Text(minutes == 0 ? "Updated now" : "Updated \(minutes) min ago")
        }
    }
}
