import XCTest
@testable import thetoolbox

final class LiveAIUsageTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["THETOOLBOX_LIVE_AI_USAGE_TESTS"] == "1" else {
            throw XCTSkip("Set THETOOLBOX_LIVE_AI_USAGE_TESTS=1 to query signed-in local accounts.")
        }
    }

    func testLiveClaudeUsage() async throws {
        try requireOptIn()
        let snapshot = try await ClaudeUsageProvider().fetchUsage()
        XCTAssertFalse(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.windows.allSatisfy { (0...100).contains($0.remainingPercent) })
    }

    func testLiveChatGPTUsage() async throws {
        try requireOptIn()
        let snapshot = try await ChatGPTUsageProvider().fetchUsage()
        XCTAssertFalse(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.windows.allSatisfy { (0...100).contains($0.remainingPercent) })
    }
}
