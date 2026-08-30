import XCTest
@testable import thetoolbox

final class AIUsageResponseTests: XCTestCase {
    func testClaudeCredentialCacheReadsKeychainLoaderOnlyOncePerAppSession() async throws {
        let loader = ClaudeCredentialLoaderSpy()
        let cache = ClaudeCredentialCache(loader: { try loader.read() })

        let first = try await cache.read()
        let second = try await cache.read()

        XCTAssertEqual(first.accessToken, "cached-token")
        XCTAssertEqual(second.accessToken, "cached-token")
        XCTAssertEqual(loader.readCount, 1)
    }

    func testClaudeDecodesCanonicalAndActiveScopedWindowsWithoutDuplicates() throws {
        let data = Data(#"""
        {
          "five_hour": {"utilization": 7, "resets_at": "2026-08-30T17:30:00.085109+00:00"},
          "seven_day": {"utilization": 59, "resets_at": "2026-08-31T10:00:00.085133+00:00"},
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [
            {"kind":"session", "group":"session", "percent":7, "resets_at":null, "scope":null, "is_active":true},
            {"kind":"weekly_scoped", "group":"weekly", "percent":44, "resets_at":null,
             "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}, "is_active":true},
            {"kind":"inactive", "group":"hidden", "percent":99, "resets_at":null, "scope":null, "is_active":false}
          ]
        }
        """#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

        XCTAssertEqual(response.usageWindows.map(\.identifier), ["five_hour", "seven_day", "weekly_scoped"])
        XCTAssertEqual(response.usageWindows.map(\.displayName), ["5-hour limit", "Weekly", "Weekly Fable"])
        XCTAssertEqual(response.usageWindows[0].remainingPercent, 93)
        XCTAssertNotNil(response.usageWindows[0].resetsAt)
    }

    func testChatGPTDecodesCurrentMultiBucketRateLimitResponse() throws {
        let data = Data(#"""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId":"codex", "limitName":null,
              "primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1788111375},
              "secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1788698175},
              "planType":"plus"
            },
            "rateLimitsByLimitId": {
              "codex": {
                "limitId":"codex", "limitName":null,
                "primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1788111375},
                "secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1788698175},
                "planType":"plus"
              }
            },
            "rateLimitResetCredits":{"availableCount":0,"credits":[]}
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(CodexRateLimitsEnvelope.self, from: data)
        let windows = try XCTUnwrap(response.result.rateLimitsByLimitId?["codex"])
            .usageWindows(fallbackID: "codex")

        XCTAssertEqual(windows.map(\.displayName), ["5-hour", "Weekly"])
        XCTAssertEqual(windows.map(\.remainingPercent), [93, 99])
        XCTAssertEqual(response.result.rateLimits.planType, "plus")
    }

    func testRemainingUsageIsClampedToDisplayRange() {
        XCTAssertEqual(AIUsageWindow(
            provider: .claude,
            identifier: "over",
            displayName: "Over",
            usedPercent: 130,
            resetsAt: nil
        ).remainingPercent, 0)
        XCTAssertEqual(AIUsageWindow(
            provider: .chatGPT,
            identifier: "under",
            displayName: "Under",
            usedPercent: -5,
            resetsAt: nil
        ).remainingPercent, 100)
    }

    func testEffectiveSystemSleepStateParsing() {
        XCTAssertTrue(PowerManager.parseSystemSleepDisabled(#""SleepDisabled" = Yes"#))
        XCTAssertTrue(PowerManager.parseSystemSleepDisabled(#""SleepDisabled"=True"#))
        XCTAssertFalse(PowerManager.parseSystemSleepDisabled(#""SleepDisabled" = No"#))
    }

    func testQuickSummaryPrefersSharedWeeklyLimitOverLowestRemainingLimit() {
        let claude = AIProviderSnapshot(
            provider: .claude,
            windows: [
                usageWindow(.claude, "five_hour", "5-hour limit", remaining: 8),
                usageWindow(.claude, "weekly_scoped", "Weekly Fable", remaining: 95),
                usageWindow(.claude, "seven_day", "Weekly", remaining: 62)
            ],
            fetchedAt: .now,
            planName: nil
        )
        let chatGPT = AIProviderSnapshot(
            provider: .chatGPT,
            windows: [
                usageWindow(.chatGPT, "codex:primary", "5-hour", remaining: 4),
                usageWindow(.chatGPT, "codex_spark:secondary", "Spark · Weekly", remaining: 90),
                usageWindow(.chatGPT, "codex:secondary", "Weekly", remaining: 73)
            ],
            fetchedAt: .now,
            planName: nil
        )

        XCTAssertEqual(claude.quickSummaryWindow?.remainingPercent, 62)
        XCTAssertEqual(chatGPT.quickSummaryWindow?.remainingPercent, 73)
    }

    func testStatusSummaryPrefersSharedFiveHourLimit() {
        let claude = AIProviderSnapshot(
            provider: .claude,
            windows: [
                usageWindow(.claude, "weekly_scoped", "Weekly Fable", remaining: 20),
                usageWindow(.claude, "five_hour", "5-hour limit", remaining: 81)
            ],
            fetchedAt: .now,
            planName: nil
        )
        let chatGPT = AIProviderSnapshot(
            provider: .chatGPT,
            windows: [
                usageWindow(.chatGPT, "codex_spark:primary", "Spark · 5-hour", remaining: 92),
                usageWindow(.chatGPT, "codex:primary", "5-hour", remaining: 66),
                usageWindow(.chatGPT, "codex:secondary", "Weekly", remaining: 88)
            ],
            fetchedAt: .now,
            planName: nil
        )

        XCTAssertEqual(claude.fiveHourSummaryWindow?.remainingPercent, 81)
        XCTAssertEqual(chatGPT.fiveHourSummaryWindow?.remainingPercent, 66)
    }

    private func usageWindow(
        _ provider: AIProviderID,
        _ identifier: String,
        _ displayName: String,
        remaining: Double
    ) -> AIUsageWindow {
        AIUsageWindow(
            provider: provider,
            identifier: identifier,
            displayName: displayName,
            usedPercent: 100 - remaining,
            resetsAt: nil
        )
    }
}

private final class ClaudeCredentialLoaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func read() throws -> ClaudeCredential {
        lock.lock()
        count += 1
        lock.unlock()
        return ClaudeCredential(accessToken: "cached-token", subscriptionType: "max")
    }
}
