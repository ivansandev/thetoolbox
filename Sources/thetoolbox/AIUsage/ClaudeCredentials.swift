import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// An imported access token is read-only. Claude Code retains ownership of its refresh token.
struct ClaudeCredential: Codable, Sendable {
    let accessToken: String
    let subscriptionType: String?
    var expiresAt: Date? = nil
    var scopes: [String]? = nil

    func isExpired(at now: Date = .now) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    func validateUsageScope() throws {
        if let scopes, !scopes.contains("user:profile") { throw Self.scopeError }
    }

    static var expiredError: AIUsageError {
        .authenticationRequired("Claude's saved usage token expired. Use Refresh Claude Access to renew it through Claude Code.")
    }

    static var scopeError: AIUsageError {
        .requestFailed("Claude's token does not allow reading usage (missing user:profile). Use a Claude Code subscription login rather than a setup-token credential.")
    }

    static func decodeCLI(_ data: Data) throws -> ClaudeCredential {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let subscriptionType: String?
                let expiresAt: Double?
                let scopes: [String]?
            }
            let claudeAiOauth: OAuth?
            let oauthAccount: OAuth?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let oauth = payload.claudeAiOauth ?? payload.oauthAccount,
              !oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIUsageError.credentialsMissing("Claude Code has no saved subscription token for usage. Open Claude Code and check /status.")
        }
        return ClaudeCredential(
            accessToken: oauth.accessToken,
            subscriptionType: oauth.subscriptionType,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            scopes: oauth.scopes
        )
    }
}

struct ClaudeCredentialReader: Sendable {
    private let cache: ClaudeCredentialCache

    init(cache: ClaudeCredentialCache = .shared) { self.cache = cache }

    func read(refreshIfAllowed: Bool = false, allowUserInteraction: Bool = false) async throws -> ClaudeCredential {
        try await cache.read(refreshIfAllowed: refreshIfAllowed, allowUserInteraction: allowUserInteraction)
    }
}

actor ClaudeCredentialCache {
    static let shared = ClaudeCredentialCache()

    typealias Loader = @Sendable (_ allowUserInteraction: Bool) throws -> ClaudeCredential
    typealias Clock = @Sendable () -> Date
    private let loader: Loader
    private let loadSaved: @Sendable () -> ClaudeCredential?
    private let save: @Sendable (ClaudeCredential) -> Void
    private let now: Clock
    private var credential: ClaudeCredential?
    private var lastError: AIUsageError?
    private var nextReload = Date.distantPast
    private var nextFailureRetry = Date.distantPast
    private var didReadSaved = false

    init() {
        let source = ClaudeCredentialSource()
        let store = ClaudeCredentialStore(profile: source.configDirectory.path)
        loader = { try source.read(allowUserInteraction: $0) }
        loadSaved = { store.load() }
        save = { store.save($0) }
        now = { .now }
    }

    init(
        loader: @escaping Loader,
        now: @escaping Clock = { .now },
        loadSaved: @escaping @Sendable () -> ClaudeCredential? = { nil },
        save: @escaping @Sendable (ClaudeCredential) -> Void = { _ in }
    ) {
        self.loader = loader
        self.now = now
        self.loadSaved = loadSaved
        self.save = save
    }

    func read(refreshIfAllowed: Bool = false, allowUserInteraction: Bool = false) throws -> ClaudeCredential {
        let currentTime = now()
        if !allowUserInteraction, let lastError, currentTime < nextFailureRetry {
            if !refreshIfAllowed, let credential, !credential.isExpired(at: currentTime) { return credential }
            throw lastError
        }
        if !refreshIfAllowed, !allowUserInteraction, let credential,
           !credential.isExpired(at: currentTime), currentTime < nextReload { return credential }

        do {
            let loaded = try loader(allowUserInteraction)
            credential = loaded
            lastError = nil
            nextReload = currentTime.addingTimeInterval(300)
            // Credentials without expiry metadata stay in memory only.
            if loaded.expiresAt != nil, !loaded.isExpired(at: currentTime) { save(loaded) }
            return loaded
        } catch {
            let failure = error as? AIUsageError ?? .requestFailed("Claude credentials could not be read.")
            lastError = failure
            nextFailureRetry = currentTime.addingTimeInterval(60)
            // Only authorization failures can reuse an imported token. Absence/malformed data
            // must not resurrect a signed-out account, and a 401 must not retry the rejected cache.
            if case .credentialAccessRequired = failure, !refreshIfAllowed, !allowUserInteraction {
                if !didReadSaved, credential == nil {
                    didReadSaved = true
                    credential = loadSaved()
                }
                if let credential, !credential.isExpired(at: currentTime) { return credential }
            }
            credential = nil
            throw failure
        }
    }
}

struct ClaudeCredentialSource: Sendable {
    let configDirectory: URL
    private let isDefaultProfile: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let defaultDirectory = home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
        if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            configDirectory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            configDirectory = defaultDirectory
        }
        isDefaultProfile = configDirectory == defaultDirectory
    }

    func read(allowUserInteraction: Bool) throws -> ClaudeCredential {
        let file = configDirectory.appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file) else {
                throw AIUsageError.requestFailed("Claude's credentials file could not be read.")
            }
            return try ClaudeCredential.decodeCLI(data)
        }
        // An explicitly selected profile must never silently use the global account.
        guard isDefaultProfile else {
            throw AIUsageError.credentialsMissing("The selected Claude profile has no credentials file for usage.")
        }
        return try ClaudeCredential.decodeCLI(ClaudeKeychain.readCLI(allowUserInteraction: allowUserInteraction))
    }
}

enum ClaudeKeychain {
    private static let interactionLock = NSLock()

    /// SecItem's UI flags are ignored by the file-based Keychain shim. Scope the
    /// legacy process-wide policy too, serialize our calls, and restore it on exit.
    /// See Chromium's ScopedKeychainUserInteractionAllowed (FB16959400).
    static func withInteraction<T>(allowed: Bool, _ operation: () throws -> T) throws -> T {
        try interactionLock.withLock {
            var previous: DarwinBoolean = false
            try check(SecKeychainGetUserInteractionAllowed(&previous))
            try check(SecKeychainSetUserInteractionAllowed(allowed))
            defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return try operation()
        }
    }

    static func query(service: String, allowUserInteraction: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // Defense in depth for the SecItem/data-protection API. Legacy ACLs
            // additionally require withInteraction around the actual operation.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    static func readCLI(allowUserInteraction: Bool) throws -> Data {
        try withInteraction(allowed: allowUserInteraction) {
            try readCLIItem(allowUserInteraction: allowUserInteraction)
        }
    }

    private static func readCLIItem(allowUserInteraction: Bool) throws -> Data {
        var candidatesQuery = query(service: "Claude Code-credentials", allowUserInteraction: allowUserInteraction)
        candidatesQuery[kSecReturnAttributes as String] = true
        candidatesQuery[kSecReturnPersistentRef as String] = true
        candidatesQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(candidatesQuery as CFDictionary, &result)
        try check(status)
        guard let candidates = result as? [[String: Any]], !candidates.isEmpty else {
            throw AIUsageError.credentialsMissing("Sign in to Claude Code to show usage.")
        }
        let userItems = candidates.filter { ($0[kSecAttrAccount as String] as? String) == NSUserName() }
        let selected = (userItems.isEmpty ? candidates : userItems).max {
            ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)
                < ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast)
        }!
        guard let reference = selected[kSecValuePersistentRef as String] as? Data else {
            throw AIUsageError.requestFailed("Claude's Keychain item could not be identified.")
        }
        var dataQuery = query(service: "Claude Code-credentials", allowUserInteraction: allowUserInteraction)
        dataQuery[kSecAttrService as String] = nil
        dataQuery[kSecValuePersistentRef as String] = reference
        dataQuery[kSecReturnData as String] = true
        dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        result = nil
        try check(SecItemCopyMatching(dataQuery as CFDictionary, &result))
        guard let data = result as? Data else {
            throw AIUsageError.requestFailed("Claude's Keychain item returned no credential data.")
        }
        return data
    }

    static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound:
            throw AIUsageError.credentialsMissing("Sign in to Claude Code to show usage.")
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem, errAuthorizationDenied:
            throw AIUsageError.credentialAccessRequired("Claude usage access is blocked by macOS. Use Allow Claude Access to authorize it once.")
        default:
            throw AIUsageError.requestFailed("Claude credentials could not be read from Keychain (error \(status)).")
        }
    }
}

/// Separate from the usage snapshot cache; contains no refresh token or account password.
private struct ClaudeCredentialStore: Sendable {
    private let account: String
    private let service = "com.ivansandev.thetoolbox.claude-access"

    init(profile: String) {
        account = SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load() -> ClaudeCredential? {
        try? ClaudeKeychain.withInteraction(allowed: false) { loadItem() }
    }

    private func loadItem() -> ClaudeCredential? {
        var query = ClaudeKeychain.query(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(ClaudeCredential.self, from: data),
              credential.expiresAt != nil, !credential.isExpired(), !credential.accessToken.isEmpty else { return nil }
        return credential
    }

    func save(_ credential: ClaudeCredential) {
        try? ClaudeKeychain.withInteraction(allowed: false) { saveItem(credential) }
    }

    private func saveItem(_ credential: ClaudeCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        var query = ClaudeKeychain.query(service: service)
        query[kSecAttrAccount as String] = account
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(query as CFDictionary, nil)
        }
        // If a changed development signature cannot access the cache, keep using memory.
        // Never delete/recreate a foreign item or show UI to repair our own cache.
    }
}
