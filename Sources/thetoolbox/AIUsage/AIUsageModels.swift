import Foundation

enum ToolboxBuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

enum AIProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case chatGPT

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        }
    }
}

struct AIUsageWindow: Codable, Hashable, Identifiable, Sendable {
    let provider: AIProviderID
    let identifier: String
    let displayName: String
    let usedPercent: Double
    let resetsAt: Date?

    var id: String { "\(provider.rawValue):\(identifier)" }
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct AIProviderSnapshot: Codable, Hashable, Sendable {
    let provider: AIProviderID
    let windows: [AIUsageWindow]
    let fetchedAt: Date
    let planName: String?

    /// The collapsed menu should describe the shared weekly quota, not whichever short or
    /// model-specific window happens to have the least usage remaining.
    var quickSummaryWindow: AIUsageWindow? {
        let exactSharedWeekly: AIUsageWindow?
        switch provider {
        case .claude:
            exactSharedWeekly = windows.first {
                $0.identifier == "seven_day" || $0.identifier == "weekly_all"
            }
        case .chatGPT:
            exactSharedWeekly = windows.first {
                $0.identifier.hasPrefix("codex:")
                    && $0.displayName.caseInsensitiveCompare("Weekly") == .orderedSame
            }
        }

        return exactSharedWeekly
            ?? windows.first { $0.displayName.caseInsensitiveCompare("Weekly") == .orderedSame }
            ?? windows.first { $0.displayName.localizedCaseInsensitiveContains("weekly") }
            ?? windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    /// The shared five-hour window used by the optional status-bar reading. Model-specific
    /// windows are deliberately secondary so the compact label has stable meaning.
    var fiveHourSummaryWindow: AIUsageWindow? {
        let exactSharedFiveHour: AIUsageWindow?
        switch provider {
        case .claude:
            exactSharedFiveHour = windows.first {
                $0.identifier == "five_hour" || $0.identifier == "session"
            }
        case .chatGPT:
            exactSharedFiveHour = windows.first {
                $0.identifier.hasPrefix("codex:")
                    && $0.displayName.caseInsensitiveCompare("5-hour") == .orderedSame
            }
        }

        return exactSharedFiveHour
            ?? windows.first { $0.displayName.caseInsensitiveCompare("5-hour") == .orderedSame }
            ?? windows.first { $0.displayName.localizedCaseInsensitiveContains("5-hour") }
    }
}

enum AIProviderAvailability: Equatable, Sendable {
    case loading
    case available(AIProviderSnapshot, isStale: Bool)
    case unavailable(String)

    var snapshot: AIProviderSnapshot? {
        if case let .available(snapshot, _) = self { return snapshot }
        return nil
    }
}

enum AIUsageError: LocalizedError, Sendable {
    case executableMissing(String)
    case credentialsMissing(String)
    case authenticationRequired(String)
    case incompatibleCLI(String)
    case invalidResponse(String)
    case requestFailed(String)
    case rateLimited(String, retryAfter: Date)
    case timedOut(String)

    var retryAfter: Date? {
        if case let .rateLimited(_, retryAfter) = self { return retryAfter }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case let .executableMissing(message), let .credentialsMissing(message),
             let .authenticationRequired(message), let .incompatibleCLI(message),
             let .invalidResponse(message), let .requestFailed(message),
             let .rateLimited(message, _), let .timedOut(message):
            return message
        }
    }
}

protocol AIUsageProvider: Sendable {
    var id: AIProviderID { get }
    func fetchUsage() async throws -> AIProviderSnapshot
}
