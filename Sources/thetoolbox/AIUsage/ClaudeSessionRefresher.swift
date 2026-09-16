import Darwin
import Foundation

/// User-initiated only: the owning CLI can renew its session without another browser login.
/// Never run this during polling, wake, or reconnect: a provider process owns its own Keychain UI.
enum ClaudeSessionRefresher {
    static func refresh(locator: AIUsageCLILocator = .init(), timeout: Duration = .seconds(8)) async throws {
        guard let executable = locator.find("claude") else {
            throw AIUsageError.executableMissing("Install Claude Code to refresh Claude usage access.")
        }
        try await refresh(executable: executable, timeout: timeout)
    }

    static func refresh(executable: URL, timeout: Duration = .seconds(8), directory: URL? = nil) async throws {
        let workingDirectory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("thetoolbox-claude-auth", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw AIUsageError.requestFailed("Claude's session refresh could not be started.")
        }
        defer { close(master) }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        // /status is a local built-in command. No model prompt, tools, hooks, or MCP servers.
        process.arguments = [
            "/status", "--tools", "", "--setting-sources", "",
            "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#,
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        defer {
            if process.isRunning { process.terminate() }
            try? terminal.close()
        }
        do { try process.run() }
        catch { throw AIUsageError.requestFailed("Claude Code could not be started to refresh usage access.") }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var buffer = [UInt8](repeating: 0, count: 8192)
        var startupText = ""
        var acceptedProbeDirectory = false
        while clock.now < deadline {
            try Task.checkCancellation()
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                startupText += String(decoding: buffer.prefix(count), as: UTF8.self)
                startupText = String(startupText.suffix(16_384))
                // Trust only this empty app-created probe directory. Do not acknowledge any
                // sign-in/permission prompt or send input that could become a model request.
                if directory == nil, !acceptedProbeDirectory,
                   startupText.lowercased().contains("yes, i trust this folder") {
                    acceptedProbeDirectory = true
                    var enter: UInt8 = 13
                    _ = Darwin.write(master, &enter, 1)
                }
            } else if !process.isRunning {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Completion is verified by re-reading credentials, never by trusting CLI output.
    }
}
