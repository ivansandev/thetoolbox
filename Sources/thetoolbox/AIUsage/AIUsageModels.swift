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
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .executableMissing(message), let .credentialsMissing(message),
             let .authenticationRequired(message), let .incompatibleCLI(message),
             let .invalidResponse(message), let .requestFailed(message),
             let .timedOut(message):
            return message
        }
    }
}

protocol AIUsageProvider: Sendable {
    var id: AIProviderID { get }
    func fetchUsage() async throws -> AIProviderSnapshot
}
