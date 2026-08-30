import AppKit
import Foundation
import Network

@MainActor
final class AIUsageManager: ObservableObject {
    @Published private(set) var states: [AIProviderID: AIProviderAvailability]
    @Published private(set) var isRefreshing = false

    private let store: AIUsageSnapshotStore
    private let pathMonitor = NWPathMonitor()
    private var hasStarted = false
    private var refreshLoop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(store: AIUsageSnapshotStore = .init()) {
        self.store = store
        let cached = store.load()
        states = Dictionary(uniqueKeysWithValues: AIProviderID.allCases.map { provider in
            if let snapshot = cached[provider] {
                return (provider, .available(snapshot, isStale: true))
            }
            return (provider, .loading)
        })
    }

    /// Defers account/keychain access until the user first opens the Toolbox menu.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.refresh() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.ivansandev.thetoolbox.ai-usage-network"))

        refreshLoop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    deinit {
        refreshLoop?.cancel()
        pathMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers: [any AIUsageProvider] = [ClaudeUsageProvider(), ChatGPTUsageProvider()]
        await withTaskGroup(of: (AIProviderID, Result<AIProviderSnapshot, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetchUsage())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }

            for await (provider, result) in group {
                switch result {
                case let .success(snapshot):
                    states[provider] = .available(snapshot, isStale: false)
                case let .failure(error):
                    if let previous = states[provider]?.snapshot {
                        states[provider] = .available(previous, isStale: true)
                    } else {
                        states[provider] = .unavailable(error.localizedDescription)
                    }
                }
            }
        }

        store.save(AIProviderID.allCases.compactMap { states[$0]?.snapshot })
    }

    func summary(for provider: AIProviderID) -> String {
        guard let windows = states[provider]?.snapshot?.windows, !windows.isEmpty else { return "—" }
        let lowest = windows.map(\.remainingPercent).min() ?? 0
        return "\(Int(lowest.rounded()))%"
    }
}

struct AIUsageSnapshotStore: Sendable {
    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appending(path: "thetoolbox", directoryHint: .isDirectory)
            .appending(path: "ai-usage-snapshots.json")
    }

    func load() -> [AIProviderID: AIProviderSnapshot] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshots = try? JSONDecoder().decode([AIProviderSnapshot].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.provider, $0) })
    }

    func save(_ snapshots: [AIProviderSnapshot]) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshots) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cached usage is optional; live provider refresh remains the source of truth.
        }
    }
}
