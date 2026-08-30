import XCTest
@testable import thetoolbox

final class AIUsageResponseTests: XCTestCase {
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
}
