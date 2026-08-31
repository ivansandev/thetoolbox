import Foundation
import Security

struct ClaudeUsageProvider: AIUsageProvider {
    let id = AIProviderID.claude

    private let credentialReader: ClaudeCredentialReader
    private let session: URLSession
    private let endpoint: URL

    init(
        credentialReader: ClaudeCredentialReader = .init(),
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1")!
    ) {
        self.credentialReader = credentialReader
        self.session = session
        self.endpoint = endpoint
    }

    func fetchUsage() async throws -> AIProviderSnapshot {
        let credential = try await credentialReader.read()
        let (data, response) = try await requestUsage(using: credential)

        if response.statusCode == 401 || response.statusCode == 403 {
            // Claude Code rotates OAuth tokens while thetoolbox can stay open for days. Reload
            // the Keychain item at most once per hour and retry only when the token changed.
            let refreshedCredential = try await credentialReader.read(refreshIfAllowed: true)
            guard refreshedCredential.accessToken != credential.accessToken else {
                throw AIUsageError.authenticationRequired(
                    "Claude Code login expired. Run `claude` and sign in again."
                )
            }
            let (retryData, retryResponse) = try await requestUsage(using: refreshedCredential)
            return try decode(data: retryData, response: retryResponse, credential: refreshedCredential)
        }

        return try decode(data: data, response: response, credential: credential)
    }

    private func requestUsage(using credential: ClaudeCredential) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("thetoolbox/\(ToolboxBuildInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIUsageError.requestFailed("Claude usage could not be reached.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIUsageError.invalidResponse("Claude returned an invalid response.")
        }
        return (data, http)
    }

    private func decode(
        data: Data,
        response http: HTTPURLResponse,
        credential: ClaudeCredential
    ) throws -> AIProviderSnapshot {
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AIUsageError.authenticationRequired("Claude Code login expired. Run `claude` and sign in again.")
        }
        if http.statusCode == 429 {
            throw AIUsageError.rateLimited(
                "Claude is rate-limited; retrying automatically.",
                retryAfter: Self.retryDate(from: http)
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIUsageError.requestFailed("Claude usage request failed (HTTP \(http.statusCode)).")
        }

        do {
            let payload = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            let windows = payload.usageWindows
            guard !windows.isEmpty else {
                throw AIUsageError.invalidResponse("Claude returned no active usage limits.")
            }
            return AIProviderSnapshot(
                provider: .claude,
                windows: windows,
                fetchedAt: .now,
                planName: credential.subscriptionType
            )
        } catch let error as AIUsageError {
            throw error
        } catch {
            throw AIUsageError.invalidResponse("Claude usage data could not be decoded.")
        }
    }

    static func retryDate(from response: HTTPURLResponse, now: Date = .now) -> Date {
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
                return now.addingTimeInterval(seconds)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(date, now) }
        }

        // The internal endpoint does not always send Retry-After. A short cooldown prevents a
        // reconnect/wake burst from extending the server-side throttle.
        return now.addingTimeInterval(15 * 60)
    }
}

struct ClaudeCredential: Sendable {
    let accessToken: String
    let subscriptionType: String?
}

struct ClaudeCredentialReader: Sendable {
    private let cache: ClaudeCredentialCache

    init(cache: ClaudeCredentialCache = .shared) {
        self.cache = cache
    }

    func read(refreshIfAllowed: Bool = false) async throws -> ClaudeCredential {
        try await cache.read(refreshIfAllowed: refreshIfAllowed)
    }
}

/// Claude Code owns this Keychain item. Reading it on every five-minute refresh can repeatedly
/// trigger macOS's access dialog on machines where the item's ACL does not retain "Always Allow".
/// Keep the decoded credential only in process memory so each app launch asks at most once.
actor ClaudeCredentialCache {
    static let shared = ClaudeCredentialCache()

    typealias Loader = @Sendable () throws -> ClaudeCredential
    typealias Clock = @Sendable () -> Date

    private let loader: Loader
    private let now: Clock
    private var credential: ClaudeCredential?
    private var nextCredentialReload = Date.distantPast

    init() {
        loader = { try ClaudeKeychainCredentialLoader.read() }
        now = { .now }
    }

    init(loader: @escaping Loader, now: @escaping Clock = { .now }) {
        self.loader = loader
        self.now = now
    }

    func read(refreshIfAllowed: Bool = false) throws -> ClaudeCredential {
        if !refreshIfAllowed, let credential { return credential }

        let currentTime = now()
        if refreshIfAllowed, let credential, currentTime < nextCredentialReload {
            return credential
        }

        // Set the cooldown before touching Keychain, including when the user denies access. That
        // keeps a failed refresh from causing the password dialog every five minutes.
        if refreshIfAllowed {
            nextCredentialReload = currentTime.addingTimeInterval(60 * 60)
        }
        let loadedCredential = try loader()
        credential = loadedCredential
        return loadedCredential
    }
}

private enum ClaudeKeychainCredentialLoader {
    static func read() throws -> ClaudeCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw AIUsageError.credentialsMissing("Sign in to Claude Code to show usage.")
        }

        struct CredentialPayload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let subscriptionType: String?
            }

            let claudeAiOauth: OAuth?
            let oauthAccount: OAuth?
        }

        guard let payload = try? JSONDecoder().decode(CredentialPayload.self, from: data),
              let oauth = payload.claudeAiOauth ?? payload.oauthAccount,
              !oauth.accessToken.isEmpty else {
            throw AIUsageError.credentialsMissing("Claude Code login could not be read.")
        }
        return ClaudeCredential(accessToken: oauth.accessToken, subscriptionType: oauth.subscriptionType)
    }
}

struct ClaudeUsageResponse: Decodable {
    struct Bucket: Decodable {
        let utilization: Double
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey { case utilization, resetsAt = "resets_at" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try values.decode(Double.self, forKey: .utilization)
            resetsAt = UsageDateParser.parse(try values.decodeIfPresent(String.self, forKey: .resetsAt))
        }
    }

    struct DynamicLimit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }

            let model: Model?
        }

        let kind: String
        let group: String
        let percent: Double
        let resetsAt: Date?
        let isActive: Bool
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(String.self, forKey: .kind)
            group = try values.decode(String.self, forKey: .group)
            percent = try values.decode(Double.self, forKey: .percent)
            resetsAt = UsageDateParser.parse(try values.decodeIfPresent(String.self, forKey: .resetsAt))
            isActive = try values.decode(Bool.self, forKey: .isActive)
            scope = try values.decodeIfPresent(Scope.self, forKey: .scope)
        }

        var displayName: String {
            if kind == "session" { return "5-hour limit" }
            if kind == "weekly_all" { return "Weekly" }
            if kind == "weekly_scoped", let model = scope?.model?.displayName, !model.isEmpty {
                return "Weekly \(model)"
            }
            return group.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    let fiveHour: Bucket?
    let sevenDay: Bucket?
    let sevenDayOpus: Bucket?
    let sevenDaySonnet: Bucket?
    let limits: [DynamicLimit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try values.decodeIfPresent(Bucket.self, forKey: .fiveHour)
        sevenDay = try values.decodeIfPresent(Bucket.self, forKey: .sevenDay)
        sevenDayOpus = try values.decodeIfPresent(Bucket.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try values.decodeIfPresent(Bucket.self, forKey: .sevenDaySonnet)
        limits = try values.decodeIfPresent([DynamicLimit].self, forKey: .limits) ?? []
    }

    var usageWindows: [AIUsageWindow] {
        var result: [AIUsageWindow] = []

        func append(_ bucket: Bucket?, id: String, name: String) {
            guard let bucket else { return }
            result.append(.init(
                provider: .claude,
                identifier: id,
                displayName: name,
                usedPercent: bucket.utilization,
                resetsAt: bucket.resetsAt
            ))
        }

        append(fiveHour, id: "five_hour", name: "5-hour limit")
        append(sevenDay, id: "seven_day", name: "Weekly")
        append(sevenDayOpus, id: "seven_day_opus", name: "Weekly Opus")
        append(sevenDaySonnet, id: "seven_day_sonnet", name: "Weekly Sonnet")

        var duplicateAliases = Set<String>()
        if fiveHour != nil { duplicateAliases.insert("session") }
        if sevenDay != nil { duplicateAliases.insert("weekly_all") }
        if sevenDayOpus != nil { duplicateAliases.insert("weekly_opus") }
        if sevenDaySonnet != nil { duplicateAliases.insert("weekly_sonnet") }

        let existing = Set(result.map(\.identifier))
        for limit in limits where limit.isActive
            && !existing.contains(limit.kind)
            && !duplicateAliases.contains(limit.kind) {
            result.append(.init(
                provider: .claude,
                identifier: limit.kind,
                displayName: limit.displayName,
                usedPercent: limit.percent,
                resetsAt: limit.resetsAt
            ))
        }
        return result
    }
}

private enum UsageDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
