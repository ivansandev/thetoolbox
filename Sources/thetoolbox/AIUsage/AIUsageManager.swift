import AppKit
import Foundation
import Network

@MainActor
final class AIUsageManager: ObservableObject {
    @Published private(set) var states: [AIProviderID: AIProviderAvailability]
    @Published private(set) var isRefreshing = false

    private let store: AIUsageSnapshotStore
    private var pathMonitor: NWPathMonitor?
    private var hasStarted = false
    private var isEnabled = false
    private var lifecycleGeneration = 0
    private var requestedProviders: Set<AIProviderID> = []
    private var pendingProviders: Set<AIProviderID> = []
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

    /// Defers provider access until the menu opens or an AI status-bar metric requests it.
    func start(providers: Set<AIProviderID> = Set(AIProviderID.allCases)) {
        guard !providers.isEmpty else { return }
        isEnabled = true
        let newlyRequested = providers.subtracting(requestedProviders)
        requestedProviders.formUnion(providers)

        if hasStarted {
            if !newlyRequested.isEmpty {
                Task { await refresh(providers: newlyRequested) }
            }
            return
        }
        hasStarted = true

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        let pathMonitor = NWPathMonitor()
        self.pathMonitor = pathMonitor
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

    /// Stops provider access while preserving cached values and the user's metric selections.
    /// A later `start` call creates fresh wake/network observers and resumes normal refreshes.
    func stop() {
        guard isEnabled || hasStarted else { return }
        isEnabled = false
        hasStarted = false
        lifecycleGeneration += 1
        requestedProviders = []
        pendingProviders = []
        refreshLoop?.cancel()
        refreshLoop = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isRefreshing = false
    }

    deinit {
        refreshLoop?.cancel()
        pathMonitor?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func refresh() async {
        guard isEnabled else { return }
        await refresh(providers: requestedProviders)
    }

    private func refresh(providers providerIDs: Set<AIProviderID>) async {
        guard isEnabled, !providerIDs.isEmpty else { return }
        if isRefreshing {
            pendingProviders.formUnion(providerIDs)
            return
        }
        isRefreshing = true
        let generation = lifecycleGeneration

        var providersToRefresh = providerIDs
        while isEnabled, generation == lifecycleGeneration, !providersToRefresh.isEmpty {
            await fetch(providers: providersToRefresh, generation: generation)
            providersToRefresh = pendingProviders
            pendingProviders = []
        }

        guard isEnabled, generation == lifecycleGeneration else { return }
        isRefreshing = false
        store.save(AIProviderID.allCases.compactMap { states[$0]?.snapshot })
    }

    private func fetch(providers providerIDs: Set<AIProviderID>, generation: Int) async {
        let providers: [any AIUsageProvider] = providerIDs.map { provider in
            switch provider {
            case .claude: return ClaudeUsageProvider()
            case .chatGPT: return ChatGPTUsageProvider()
            }
        }
        await withTaskGroup(of: (AIProviderID, Result<AIProviderSnapshot, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetchUsage())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }

            for await (provider, result) in group {
                guard isEnabled, generation == lifecycleGeneration else { continue }
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
    }

    func summary(for provider: AIProviderID) -> String {
        guard let window = states[provider]?.snapshot?.quickSummaryWindow else { return "—" }
        return "\(Int(window.remainingPercent.rounded()))%"
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
