import Foundation
import Darwin
import LocalAuthentication
import Security
import XCTest
@testable import thetoolbox

final class ClaudeAuthenticationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailedInitialReadHasCooldownAndNeverRequestsBackgroundInteraction() async {
        let state = CredentialState(results: [.failure(.credentialAccessRequired("Blocked"))], date: origin)
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() })
        for _ in 0..<3 {
            do { _ = try await cache.read(); XCTFail("Expected blocked access") }
            catch { XCTAssertEqual(error.localizedDescription, "Blocked") }
        }
        XCTAssertEqual(state.interactions, [false])
        state.advance(61)
        _ = try? await cache.read()
        XCTAssertEqual(state.interactions, [false, false])
    }

    func testExplicitAccessActionBypassesDeniedReadCooldown() async throws {
        let state = CredentialState(results: [
            .failure(.credentialAccessRequired("Blocked")), .success(token("new"))
        ], date: origin)
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() })
        _ = try? await cache.read()
        let result = try await cache.read(allowUserInteraction: true)
        XCTAssertEqual(result.accessToken, "new")
        XCTAssertEqual(state.interactions, [false, true])
    }

    func testExpiryReloadsCredentialBeforeFiveMinuteCacheInterval() async throws {
        let state = CredentialState(results: [
            .success(token("old", expiresAt: origin.addingTimeInterval(10))),
            .success(token("new", expiresAt: origin.addingTimeInterval(600)))
        ], date: origin)
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() })
        _ = try await cache.read()
        state.advance(11)
        let result = try await cache.read()
        XCTAssertEqual(result.accessToken, "new")
        XCTAssertEqual(state.interactions, [false, false])
    }

    func testPeriodicSilentReadAdoptsAccountOrTokenChanges() async throws {
        let state = CredentialState(results: [.success(token("old")), .success(token("new"))], date: origin)
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() })
        _ = try await cache.read()
        state.advance(300)
        let result = try await cache.read()
        XCTAssertEqual(result.accessToken, "new")
        XCTAssertEqual(state.interactions, [false, false])
    }

    func testOwnedCacheSurvivesLossOfForeignKeychainGrant() async throws {
        let state = CredentialState(results: [.failure(.credentialAccessRequired("Blocked"))], date: origin)
        let saved = token("imported", expiresAt: origin.addingTimeInterval(600))
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() }, loadSaved: { saved })
        let result = try await cache.read()
        let cached = try await cache.read()
        XCTAssertEqual(result.accessToken, "imported")
        XCTAssertEqual(cached.accessToken, "imported")
        XCTAssertEqual(state.interactions, [false])
    }

    func testExpiredOwnedCacheCannotBeReused() async {
        let saved = token("expired", expiresAt: origin.addingTimeInterval(-1))
        let cache = ClaudeCredentialCache(
            loader: { _ in throw AIUsageError.credentialAccessRequired("Blocked") },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, loadSaved: { saved }
        )
        do { _ = try await cache.read(); XCTFail("Expected blocked access") }
        catch { XCTAssertEqual(error.localizedDescription, "Blocked") }
    }

    func testSignOutDoesNotResurrectOwnedCache() async {
        let saved = token("imported", expiresAt: origin.addingTimeInterval(600))
        let state = CredentialState(results: [.success(saved), .failure(.credentialsMissing("Signed out"))], date: origin)
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() }, loadSaved: { saved })
        _ = try? await cache.read()
        state.advance(300)
        for _ in 0..<2 {
            do { _ = try await cache.read(); XCTFail("Expected signed out") }
            catch { XCTAssertEqual(error.localizedDescription, "Signed out") }
        }
    }

    func testRejectedTokenCannotBeRecoveredFromOwnedCache() async throws {
        let saved = token("rejected", expiresAt: origin.addingTimeInterval(600))
        let state = CredentialState(results: [.failure(.credentialAccessRequired("Blocked"))], date: origin)
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() }, loadSaved: { saved })
        _ = try await cache.read()
        state.advance(61)
        do { _ = try await cache.read(refreshIfAllowed: true); XCTFail("Expected blocked access") }
        catch { XCTAssertEqual(error.localizedDescription, "Blocked") }
    }

    func testCLIPayloadPreservesExpiryAndScopesWithoutCopyingRefreshToken() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"access","refreshToken":"never-copy-this","expiresAt":1800000000000,"scopes":["user:profile"],"subscriptionType":"max"}}"#.utf8)
        let credential = try ClaudeCredential.decodeCLI(data)
        XCTAssertEqual(credential.expiresAt, origin)
        XCTAssertEqual(credential.scopes, ["user:profile"])
        XCTAssertEqual(credential.subscriptionType, "max")
        let persisted = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        XCTAssertFalse(persisted.contains("refreshToken"))
        XCTAssertFalse(persisted.contains("never-copy-this"))
    }

    func testInferenceOnlyTokenCannotReadUsage() throws {
        let credential = ClaudeCredential(accessToken: "inference-only", subscriptionType: nil, scopes: ["user:inference"])
        XCTAssertThrowsError(try credential.validateUsageScope()) { error in
            XCTAssertTrue(error.localizedDescription.contains("user:profile"))
            XCTAssertFalse(error.localizedDescription.contains("expired"))
        }
    }

    func testKeychainPermissionFailuresAreDistinctFromMissingLogin() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem, errAuthorizationDenied] {
            XCTAssertThrowsError(try ClaudeKeychain.check(status)) { error in
                guard case .credentialAccessRequired = error as? AIUsageError else {
                    return XCTFail("Expected an authorization error, received \(error)")
                }
            }
        }
        XCTAssertThrowsError(try ClaudeKeychain.check(errSecItemNotFound)) { error in
            guard case .credentialsMissing = error as? AIUsageError else { return XCTFail("Expected missing credentials") }
        }
    }

    func testBackgroundKeychainQueriesDisableBothAuthenticationUIPaths() {
        let query = ClaudeKeychain.query(service: "test")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        let interactive = ClaudeKeychain.query(service: "test", allowUserInteraction: true)
        XCTAssertNil(interactive[kSecUseAuthenticationUI as String])
        XCTAssertNil(interactive[kSecUseAuthenticationContext as String])
    }

    func testLegacyKeychainInteractionPolicyRestoresAfterFailure() throws {
        func interactionAllowed() throws -> Bool {
            var value: DarwinBoolean = false
            try ClaudeKeychain.check(SecKeychainGetUserInteractionAllowed(&value))
            return value.boolValue
        }
        let original = try interactionAllowed()
        XCTAssertThrowsError(try ClaudeKeychain.withInteraction(allowed: false) {
            XCTAssertFalse(try interactionAllowed())
            throw AIUsageError.credentialAccessRequired("Denied")
        })
        XCTAssertEqual(try interactionAllowed(), original)
        try ClaudeKeychain.withInteraction(allowed: true) {
            XCTAssertTrue(try interactionAllowed())
        }
        XCTAssertEqual(try interactionAllowed(), original)
    }

    func testSelectedProfileReadsItsFileAndTreatsCommasLiterally() throws {
        let directory = try temporaryDirectory().appendingPathComponent("profile,one", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"selected-profile"}}"#.utf8)
            .write(to: directory.appendingPathComponent(".credentials.json"))
        let source = ClaudeCredentialSource(environment: ["CLAUDE_CONFIG_DIR": directory.path])
        XCTAssertEqual(try source.read(allowUserInteraction: false).accessToken, "selected-profile")
    }

    func testSelectedProfileNeverFallsBackToGlobalKeychain() throws {
        let directory = try temporaryDirectory()
        let source = ClaudeCredentialSource(environment: ["CLAUDE_CONFIG_DIR": directory.path])
        XCTAssertThrowsError(try source.read(allowUserInteraction: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("selected Claude profile"))
        }
    }

    func test401SilentlyAdoptsCLIRotationAndRetriesOnce() async throws {
        let state = CredentialState(results: [.success(token("old")), .success(token("new"))], date: origin)
        let session = mockSession(responses: [(401, Data()), (200, usageData)])
        let cache = ClaudeCredentialCache(loader: { try state.read($0) }, now: { state.now() })
        let provider = ClaudeUsageProvider(credentialReader: .init(cache: cache), session: session, refreshSession: {
            XCTFail("A background check must never launch Claude")
        })
        let result = try await provider.fetchUsage()
        XCTAssertEqual(result.windows.first?.remainingPercent, 75)
        XCTAssertEqual(ClaudeUsageURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer old", "Bearer new"])
        XCTAssertEqual(state.interactions, [false, false])
    }

    func test403DoesNotReloadCredentialsOrMisreportLoginExpiry() async {
        let state = CredentialState(results: [.success(token("valid"))], date: origin)
        let session = mockSession(responses: [(403, Data("<html>Challenge</html>".utf8))])
        let provider = ClaudeUsageProvider(
            credentialReader: .init(cache: .init(loader: { try state.read($0) }, now: { state.now() })), session: session,
            refreshSession: { XCTFail("403 must not trigger session refresh") }
        )
        do { _ = try await provider.fetchUsage(); XCTFail("Expected HTTP 403") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
            XCTAssertFalse(error.localizedDescription.contains("expired"))
        }
        XCTAssertEqual(state.interactions, [false])
        XCTAssertEqual(ClaudeUsageURLProtocol.requests.count, 1)
    }

    func test403ScopeErrorExplainsMissingPermission() async {
        let state = CredentialState(results: [.success(token("valid"))], date: origin)
        let provider = ClaudeUsageProvider(
            credentialReader: .init(cache: .init(loader: { try state.read($0) }, now: { state.now() })),
            session: mockSession(responses: [(403, Data(#"{"error":{"message":"Missing user:profile scope"}}"#.utf8))])
        )
        do { _ = try await provider.fetchUsage(); XCTFail("Expected a scope error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("missing user:profile")) }
        XCTAssertEqual(state.interactions, [false])
    }

    func testExpiredTokenDoesNotMakeRequestsOrLaunchCLIInBackground() async {
        let state = CredentialState(results: [.success(token("expired", expiresAt: .distantPast))], date: origin)
        let provider = ClaudeUsageProvider(
            credentialReader: .init(cache: .init(loader: { try state.read($0) }, now: { state.now() })),
            session: mockSession(responses: []),
            refreshSession: { XCTFail("Background refresh must not launch Claude") }
        )
        do { _ = try await provider.fetchUsage(); XCTFail("Expected expiry") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Refresh Claude Access")) }
        XCTAssertTrue(ClaudeUsageURLProtocol.requests.isEmpty)
    }

    func testExplicitActionDelegatesExpiredSessionToOwnerAndUsesNewToken() async throws {
        let state = CredentialState(results: [
            .success(token("expired", expiresAt: .distantPast)),
            .success(token("renewed", expiresAt: .distantFuture))
        ], date: origin)
        let refreshed = expectation(description: "Session refreshed through its owner")
        refreshed.assertForOverFulfill = true
        let provider = ClaudeUsageProvider(
            credentialReader: .init(cache: .init(loader: { try state.read($0) }, now: { state.now() })),
            session: mockSession(responses: [(200, usageData)]), allowCredentialInteraction: true,
            refreshSession: { refreshed.fulfill() }
        )
        _ = try await provider.fetchUsage()
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(state.interactions, [true, true])
        XCTAssertEqual(ClaudeUsageURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
    }

    func testRetryStopsWhenRenewedTokenIsAlsoRejected() async {
        let state = CredentialState(results: [.success(token("old")), .success(token("new"))], date: origin)
        let provider = ClaudeUsageProvider(
            credentialReader: .init(cache: .init(loader: { try state.read($0) }, now: { state.now() })),
            session: mockSession(responses: [(401, Data()), (401, Data())])
        )
        do { _ = try await provider.fetchUsage(); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rejected")) }
        XCTAssertEqual(ClaudeUsageURLProtocol.requests.count, 2)
        XCTAssertEqual(state.interactions.count, 2)
    }

    func testOwnerProbeRunsOnlyLocalStatusWithIntegrationsDisabled() async throws {
        let directory = try temporaryDirectory()
        let executable = directory.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > arguments.txt\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await ClaudeSessionRefresher.refresh(executable: executable, timeout: .seconds(2), directory: directory)
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments.txt"))
            .components(separatedBy: "\n")
        XCTAssertEqual(arguments.first, "/status")
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains(#"{"mcpServers":{}}"#))
        XCTAssertTrue(arguments.contains(#"{"disableAllHooks":true,"remoteControlAtStartup":false}"#))
        XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--tools")) + 1], "")
        XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--setting-sources")) + 1], "")
    }

    func testCancellingOwnerProbeTerminatesItsCLI() async throws {
        let directory = try temporaryDirectory()
        let executable = directory.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > pid.txt\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let task = Task {
            try await ClaudeSessionRefresher.refresh(executable: executable, timeout: .seconds(30), directory: directory)
        }
        let file = directory.appendingPathComponent("pid.txt")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: file)))
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(pid, 0), -1, "The owner probe must not leave a CLI running")
    }

    private func token(_ value: String, expiresAt: Date? = nil) -> ClaudeCredential {
        ClaudeCredential(accessToken: value, subscriptionType: "max", expiresAt: expiresAt)
    }

    private var usageData: Data { Data(#"{"five_hour":{"utilization":25,"resets_at":null}}"#.utf8) }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-auth-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func mockSession(responses: [(Int, Data)]) -> URLSession {
        ClaudeUsageURLProtocol.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }
}

private final class CredentialState: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Result<ClaudeCredential, AIUsageError>]
    private var date: Date
    private var flags: [Bool] = []

    init(results: [Result<ClaudeCredential, AIUsageError>], date: Date) {
        self.results = results
        self.date = date
    }
    var interactions: [Bool] { lock.withLock { flags } }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    func read(_ allowInteraction: Bool) throws -> ClaudeCredential {
        let result = lock.withLock {
            let result = results[min(flags.count, results.count - 1)]
            flags.append(allowInteraction)
            return result
        }
        return try result.get()
    }
}

private final class ClaudeUsageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [(Int, Data)] = []
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func reset(_ responses: [(Int, Data)]) {
        lock.withLock { self.responses = responses; captured = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.lock.withLock {
            Self.captured.append(request)
            return Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
