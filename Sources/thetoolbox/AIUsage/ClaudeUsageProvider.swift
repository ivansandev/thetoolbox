import Foundation

struct ClaudeUsageProvider: AIUsageProvider {
    let id = AIProviderID.claude

    private let credentialReader: ClaudeCredentialReader
    private let session: URLSession
    private let endpoint: URL
    private let allowCredentialInteraction: Bool
    private let refreshSession: @Sendable () async throws -> Void

    init(
        credentialReader: ClaudeCredentialReader = .init(),
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1")!,
        allowCredentialInteraction: Bool = false,
        refreshSession: @escaping @Sendable () async throws -> Void = { try await ClaudeSessionRefresher.refresh() }
    ) {
        self.credentialReader = credentialReader
        self.session = session
        self.endpoint = endpoint
        self.allowCredentialInteraction = allowCredentialInteraction
        self.refreshSession = refreshSession
    }

    func fetchUsage() async throws -> AIProviderSnapshot {
        var credential = try await credentialReader.read(allowUserInteraction: allowCredentialInteraction)
        var didRefreshSession = false
        if credential.isExpired() {
            guard allowCredentialInteraction else { throw ClaudeCredential.expiredError }
            try await refreshSession()
            didRefreshSession = true
            credential = try await credentialReader.read(refreshIfAllowed: true, allowUserInteraction: true)
            guard !credential.isExpired() else { throw ClaudeCredential.expiredError }
        }
        try credential.validateUsageScope()
        let (data, response) = try await requestUsage(using: credential)

        if response.statusCode == 401 {
            // Only the owning CLI can refresh its rotating refresh token. Background checks
            // can adopt its new access token, but must never launch an interactive CLI.
            if allowCredentialInteraction, !didRefreshSession {
                try await refreshSession()
            }
            let refreshedCredential = try await credentialReader.read(
                refreshIfAllowed: true,
                allowUserInteraction: allowCredentialInteraction
            )
            guard !refreshedCredential.isExpired() else { throw ClaudeCredential.expiredError }
            try refreshedCredential.validateUsageScope()
            guard refreshedCredential.accessToken != credential.accessToken else {
                throw Self.rejectedCredentialError
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        if http.statusCode == 401 {
            throw Self.rejectedCredentialError
        }
        if http.statusCode == 403 {
            // Missing scopes and gateway/challenge failures do not mean the CLI is signed out.
            if String(data: data, encoding: .utf8)?.contains("user:profile") == true {
                throw ClaudeCredential.scopeError
            }
            throw AIUsageError.requestFailed("Claude denied the usage request (HTTP 403). Your CLI login may still be valid; try again later.")
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

    private static var rejectedCredentialError: AIUsageError {
        .authenticationRequired("Claude rejected the saved usage token. Use Refresh Claude Access to renew it through Claude Code.")
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
