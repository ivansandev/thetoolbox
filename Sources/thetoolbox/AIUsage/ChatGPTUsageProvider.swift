import Darwin
import Foundation

/// ChatGPT subscription limits are exposed by the signed-in Codex CLI's supported app-server
/// protocol. The Toolbox never reads or copies Codex authentication files.
struct ChatGPTUsageProvider: AIUsageProvider {
    let id = AIProviderID.chatGPT

    private let locator: AIUsageCLILocator
    private let rpc: CodexRateLimitsProcess

    init(locator: AIUsageCLILocator = .init(), rpc: CodexRateLimitsProcess = .init()) {
        self.locator = locator
        self.rpc = rpc
    }

    func fetchUsage() async throws -> AIProviderSnapshot {
        guard let executable = locator.find("codex") else {
            throw AIUsageError.executableMissing("Install the Codex CLI to show ChatGPT usage.")
        }

        let line = try await rpc.requestRateLimits(executable: executable)
        do {
            let envelope = try JSONDecoder().decode(CodexRateLimitsEnvelope.self, from: line)
            let snapshots: [(String, CodexRateLimitSnapshot)]
            if let buckets = envelope.result.rateLimitsByLimitId, !buckets.isEmpty {
                snapshots = buckets.sorted(by: { $0.key < $1.key })
            } else {
                snapshots = [(envelope.result.rateLimits.limitId ?? "codex", envelope.result.rateLimits)]
            }

            let windows = snapshots.flatMap { key, snapshot in
                snapshot.usageWindows(fallbackID: key)
            }
            guard !windows.isEmpty else {
                throw AIUsageError.invalidResponse("ChatGPT returned no subscription usage windows.")
            }

            return AIProviderSnapshot(
                provider: .chatGPT,
                windows: windows,
                fetchedAt: .now,
                planName: snapshots.compactMap { $0.1.planType }.first
            )
        } catch let error as AIUsageError {
            throw error
        } catch {
            throw AIUsageError.invalidResponse("ChatGPT usage data could not be decoded.")
        }
    }
}

struct CodexRateLimitsEnvelope: Decodable {
    let result: Result

    struct Result: Decodable {
        let rateLimits: CodexRateLimitSnapshot
        let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
    }
}

struct CodexRateLimitSnapshot: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: TimeInterval?
    }

    let limitId: String?
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let planType: String?

    func usageWindows(fallbackID: String) -> [AIUsageWindow] {
        let root = limitId ?? fallbackID
        let name = limitName ?? root.replacingOccurrences(of: "_", with: " ").capitalized
        return [("primary", primary), ("secondary", secondary)].compactMap { suffix, window in
            guard let window else { return nil }
            let duration = window.windowDurationMins.map(Self.durationName)
            let displayName = duration.map { name == "Codex" ? $0 : "\(name) · \($0)" } ?? name
            return AIUsageWindow(
                provider: .chatGPT,
                identifier: "\(root):\(suffix)",
                displayName: displayName,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    private static func durationName(_ minutes: Int) -> String {
        switch minutes {
        case 0..<60: return "\(minutes)-minute"
        case 60..<1440 where minutes.isMultiple(of: 60): return "\(minutes / 60)-hour"
        case 1440..<10080 where minutes.isMultiple(of: 1440): return "\(minutes / 1440)-day"
        case 10080: return "Weekly"
        default: return "Usage window"
        }
    }
}

struct AIUsageCLILocator: Sendable {
    func find(_ name: String) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.asdf/shims/\(name)",
            "\(home)/.local/share/mise/shims/\(name)",
            "/usr/bin/\(name)"
        ]

        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            candidates.append(contentsOf: versions.sorted().reversed().map { "\(nvmRoot)/\($0)/bin/\(name)" })
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
        }

        return candidates.first(where: fileManager.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}

final class CodexRateLimitsProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?

    init() {
        // A CLI can exit between a response and the next write. Treat that closed pipe as a
        // regular write failure rather than allowing SIGPIPE to terminate the menu-bar app.
        signal(SIGPIPE, SIG_IGN)
    }

    func requestRateLimits(executable: URL, timeout: Duration = .seconds(15)) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.run(executable: executable) }
            group.addTask {
                try await Task.sleep(for: timeout)
                self.stop()
                throw AIUsageError.timedOut("ChatGPT usage did not answer within 15 seconds.")
            }

            guard let result = try await group.next() else {
                throw AIUsageError.requestFailed("The Codex app server stopped unexpectedly.")
            }
            group.cancelAll()
            stop()
            return result
        }
    }

    private func run(executable: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.blockingRun(executable: executable))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func blockingRun(executable: URL) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]

        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executableDirectory):/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        lock.withLock { activeProcess = process }
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            lock.withLock { activeProcess = nil }
        }

        do {
            try process.run()
        } catch {
            throw AIUsageError.requestFailed("The Codex CLI could not be started.")
        }

        try write([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "thetoolbox",
                    "title": "thetoolbox",
                    "version": ToolboxBuildInfo.version
                ],
                "capabilities": ["experimentalApi": true, "requestAttestation": false]
            ]
        ], to: input.fileHandleForWriting)

        var buffer = Data()
        var requestedLimits = false
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if (object["id"] as? Int) == 1 && !requestedLimits {
                    requestedLimits = true
                    try write(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
                    try write(["method": "account/rateLimits/read", "id": 2], to: input.fileHandleForWriting)
                } else if (object["id"] as? Int) == 2 {
                    if let error = object["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "Unknown app-server error"
                        throw AIUsageError.requestFailed("ChatGPT: \(message)")
                    }
                    return line
                }
            }
        }
        throw AIUsageError.incompatibleCLI("Update the Codex CLI, then sign in with ChatGPT.")
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func stop() {
        lock.withLock {
            if activeProcess?.isRunning == true { activeProcess?.terminate() }
        }
    }
}
