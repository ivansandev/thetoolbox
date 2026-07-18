import Foundation

/// Coarse memory-pressure buckets, mirroring Activity Monitor's green / yellow / red.
enum MemPressure { case normal, warning, critical }

/// Metrics that can keep the monitor polling while the menu is closed.
struct StatusBarMetrics: OptionSet, Equatable {
    let rawValue: Int

    static let cpu = StatusBarMetrics(rawValue: 1 << 0)
    static let memory = StatusBarMetrics(rawValue: 1 << 1)
    static let storage = StatusBarMetrics(rawValue: 1 << 2)
    static let all: StatusBarMetrics = [.cpu, .memory, .storage]
}

/// One entry in a "top consumers" list (already formatted for display).
struct ProcInfo: Identifiable {
    let id = UUID()
    let name: String
    let value: String
}

/// One fan's current speed, read from the SMC. Fanless Macs (e.g. MacBook Air) simply report zero
/// fans.
struct FanReading: Identifiable {
    let id: Int
    let name: String
    let rpm: Int
}

/// Live CPU / memory / storage readings for the menu's monitor row. Everything is read from
/// native Darwin APIs (`host_statistics`, `getloadavg`, `sysctl`, `URL.resourceValues`) plus one
/// `ps` invocation for the top-consumer lists — no third-party dependencies.
///
/// Lightweight sampling runs while at least one status-bar metric is enabled. Opening the menu
/// samples all metrics and additionally reads details such as top processes and fans. CPU% is a
/// delta between successive tick snapshots, so the previous snapshot is kept across polling
/// transitions.
final class SystemMonitor: ObservableObject {
    // CPU
    @Published private(set) var cpuUsage: Double = 0        // 0…1, busy fraction
    @Published private(set) var cpuUser: Double = 0         // 0…1 of total
    @Published private(set) var cpuSystem: Double = 0       // 0…1 of total
    @Published private(set) var loadAverages: [Double] = [0, 0, 0]
    @Published private(set) var coreSummary: String = ""

    // Memory
    @Published private(set) var memUsage: Double = 0        // 0…1
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memApp: UInt64 = 0
    @Published private(set) var memWired: UInt64 = 0
    @Published private(set) var memCompressed: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var pressure: MemPressure = .normal
    @Published private(set) var pressureFraction: Double = 0 // 0…1, matches Activity Monitor's pressure graph

    // Storage (boot volume)
    @Published private(set) var diskUsage: Double = 0       // 0…1
    @Published private(set) var diskUsed: UInt64 = 0
    @Published private(set) var diskTotal: UInt64 = 0
    @Published private(set) var diskName: String = "Macintosh HD"

    // Top consumers
    @Published private(set) var topCPU: [ProcInfo] = []
    @Published private(set) var topMemory: [ProcInfo] = []

    // Fans (SMC; empty on fanless Macs)
    @Published private(set) var fans: [FanReading] = []

    private var timer: Timer?
    private let queue = DispatchQueue(label: "thetoolbox.systemmonitor")
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var statusBarMetrics: StatusBarMetrics = []
    private var isMenuVisible = false

    init() {
        coreSummary = Self.coreSummary()
        #if DEBUG
        if ProcessInfo.processInfo.environment["THETOOLBOX_MONITOR_TEST"] == "1" {
            queue.sync { self.sample(metrics: .all, includeDetails: true) }   // prime baseline
            Thread.sleep(forTimeInterval: 1.0)
            queue.sync { self.sample(metrics: .all, includeDetails: true) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))   // let the async publish flush
            NSLog("thetoolbox monitor test: cpu=\(Int(cpuUsage*100))%% mem=\(Int(memUsage*100))%% (\(memUsed)/\(memTotal)) disk=\(Int(diskUsage*100))%% topCPU=\(topCPU.map{ "\($0.name) \($0.value)" }) topMem=\(topMemory.map{ "\($0.name) \($0.value)" }) fans=\(fans.map { "\($0.name) \($0.rpm)rpm" })")
            assert((0...1).contains(cpuUsage) && (0...1).contains(memUsage) && (0...1).contains(diskUsage))
            assert(fans.allSatisfy { (0...10000).contains($0.rpm) })
        }
        #endif
    }

    /// Updates the metrics that should remain live while the menu is closed.
    func setStatusBarMetrics(_ metrics: StatusBarMetrics) {
        guard statusBarMetrics != metrics else { return }
        statusBarMetrics = metrics
        reconcilePolling()
    }

    /// Opening the menu temporarily requests every metric plus the more expensive detail reads.
    func startMenuSampling() {
        guard !isMenuVisible else { return }
        isMenuVisible = true
        reconcilePolling()
    }

    func stopMenuSampling() {
        guard isMenuVisible else { return }
        isMenuVisible = false
        reconcilePolling()
    }

    deinit { timer?.invalidate() }

    private func reconcilePolling() {
        let shouldPoll = isMenuVisible || !statusBarMetrics.isEmpty
        guard shouldPoll else {
            timer?.invalidate()
            timer = nil
            return
        }

        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        let metrics = isMenuVisible ? StatusBarMetrics.all : statusBarMetrics
        let includeDetails = isMenuVisible
        queue.async { self.sample(metrics: metrics, includeDetails: includeDetails) }
    }

    /// Reads the requested metrics on the serial queue, then publishes results on the main actor.
    private func sample(metrics: StatusBarMetrics, includeDetails: Bool) {
        let cpu = metrics.contains(.cpu) ? readCPU() : nil
        let loads = metrics.contains(.cpu) ? Self.loadAverage() : nil
        let mem = metrics.contains(.memory) ? readMemory() : nil
        let disk = metrics.contains(.storage) ? readDisk() : nil
        let procs = includeDetails ? topProcesses() : nil
        let fans = includeDetails ? Self.readFans() : nil

        DispatchQueue.main.async {
            if let cpu {
                self.cpuUsage = cpu.busy; self.cpuUser = cpu.user; self.cpuSystem = cpu.system
            }
            if let loads { self.loadAverages = loads }
            if let mem {
                self.memUsage = mem.usage; self.memUsed = mem.used; self.memTotal = mem.total
                self.memApp = mem.app; self.memWired = mem.wired; self.memCompressed = mem.compressed
                self.swapUsed = mem.swap; self.pressure = mem.pressure; self.pressureFraction = mem.pressureFraction
            }
            if let disk {
                self.diskUsage = disk.usage; self.diskUsed = disk.used
                self.diskTotal = disk.total; self.diskName = disk.name
            }
            if let procs {
                self.topCPU = procs.cpu
                self.topMemory = procs.mem
            }
            if let fans { self.fans = fans }
        }
    }

    // MARK: Fans

    /// Reads every fan's current RPM via the SMC. Returns an empty list on fanless Macs or if the
    /// SMC is unreachable — both are treated the same by callers (no "Fans" section shown).
    private static func readFans() -> [FanReading] {
        guard let count = SMC.readValue("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let rpm = SMC.readValue("F\(i)Ac") else { return nil }
            return FanReading(id: i, name: "Fan \(i + 1)", rpm: Int(rpm.rounded()))
        }
    }

    // MARK: CPU

    private func readCPU() -> (busy: Double, user: Double, system: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        defer { previousTicks = (user, system, idle, nice) }
        guard let prev = previousTicks else { return (0, 0, 0) }

        let dUser = user &- prev.user, dSystem = system &- prev.system
        let dIdle = idle &- prev.idle, dNice = nice &- prev.nice
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return (cpuUsage, cpuUser, cpuSystem) }
        let busy = Double(dUser + dSystem + dNice) / Double(total)
        return (busy, Double(dUser + dNice) / Double(total), Double(dSystem) / Double(total))
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads
    }

    private static func coreSummary() -> String {
        let total = ProcessInfo.processInfo.activeProcessorCount
        if let p = sysctlInt("hw.perflevel0.logicalcpu"), let e = sysctlInt("hw.perflevel1.logicalcpu"), e > 0 {
            return "\(total) (\(p)P + \(e)E)"
        }
        return "\(total)"
    }

    // MARK: Memory

    private func readMemory() -> (usage: Double, used: UInt64, total: UInt64, app: UInt64,
                                  wired: UInt64, compressed: UInt64, swap: UInt64, pressure: MemPressure,
                                  pressureFraction: Double)? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let ps = UInt64(page)
        let total = ProcessInfo.processInfo.physicalMemory
        let wired = UInt64(vm.wire_count) * ps
        let compressed = UInt64(vm.compressor_page_count) * ps
        // App memory ≈ internal pages that aren't purgeable (matches Activity Monitor closely).
        let app = UInt64(max(0, Int64(vm.internal_page_count) - Int64(vm.purgeable_count))) * ps
        let used = app + wired + compressed
        let usage = total > 0 ? min(1, Double(used) / Double(total)) : 0

        return (usage, used, total, app, wired, compressed, Self.swapUsed(),
                Self.pressure(usedFraction: usage), Self.pressureFraction(usedFraction: usage))
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Prefers the kernel's real pressure level; falls back to used-fraction thresholds if the
    /// sysctl is unavailable. ponytail: threshold fallback is a proxy, not true pressure.
    private static func pressure(usedFraction: Double) -> MemPressure {
        if let level = sysctlInt("kern.memorystatus_vm_pressure_level") {
            switch level { case 4: return .critical; case 2: return .warning; default: return .normal }
        }
        return usedFraction > 0.90 ? .critical : usedFraction > 0.70 ? .warning : .normal
    }

    /// The same figure Activity Monitor's pressure graph tracks: 100% minus the kernel's
    /// "available memory" percentage (reclaimable/free headroom), not raw bytes used — so it can
    /// read very differently from `usedFraction`. Falls back to used-fraction if unavailable.
    private static func pressureFraction(usedFraction: Double) -> Double {
        guard let level = sysctlInt("kern.memorystatus_level") else { return usedFraction }
        return max(0, min(1, Double(100 - level) / 100))
    }

    // MARK: Storage

    private func readDisk() -> (usage: Double, used: UInt64, total: UInt64, name: String)? {
        let url = URL(fileURLWithPath: "/")
        // Plain available capacity (real free space), NOT ...ForImportantUsage — the latter counts
        // purgeable space as free and under-reports usage vs. df / Finder's Storage view.
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey
        ]), let total = values.volumeTotalCapacity else { return nil }

        let free = UInt64(values.volumeAvailableCapacity ?? 0)
        let totalU = UInt64(total)
        let used = totalU > free ? totalU - free : 0
        let usage = totalU > 0 ? Double(used) / Double(totalU) : 0
        return (usage, used, totalU, values.volumeName ?? "Macintosh HD")
    }

    // MARK: Top processes (single `ps`, parsed twice)

    private func topProcesses() -> (cpu: [ProcInfo], mem: [ProcInfo]) {
        guard let output = Self.runPS() else { return ([], []) }
        struct Sample { let name: String; let cpu: Double; let rss: UInt64 }
        var samples: [Sample] = []
        for line in output.split(separator: "\n") {
            let tokens = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " })
            guard tokens.count >= 3, let cpu = Double(tokens[0]), let rssKB = Double(tokens[1]) else { continue }
            samples.append(Sample(name: tokens[2...].joined(separator: " "),
                                  cpu: cpu, rss: UInt64(rssKB) * 1024))
        }
        let cpu = samples.sorted { $0.cpu > $1.cpu }.prefix(3)
            .map { ProcInfo(name: $0.name, value: "\(Int($0.cpu.rounded()))%") }
        let mem = samples.sorted { $0.rss > $1.rss }.prefix(3)
            .map { ProcInfo(name: $0.name, value: Format.bytes($0.rss)) }
        return (Array(cpu), Array(mem))
    }

    private static func runPS() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-c", "-o", "pcpu=", "-o", "rss=", "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// Reads a scalar integer sysctl by name; nil if the key is absent (e.g. perflevels on Intel).
private func sysctlInt(_ name: String) -> Int? {
    var value: Int = 0
    var size = MemoryLayout<Int>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
}

/// Byte formatting shared by the monitor cards.
enum Format {
    static func bytes(_ bytes: UInt64, style: ByteCountFormatter.CountStyle = .memory) -> String {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowedUnits = bytes < 1_000_000_000 ? [.useMB] : [.useGB]
        return f.string(fromByteCount: Int64(bytes))
    }

    /// Compact whole-unit free capacity for the monitor gauge, using TB once it is clearer.
    static func storage(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 GB" }
        let useTB = bytes >= 1_000_000_000_000
        let divisor = useTB ? 1_000_000_000_000.0 : 1_000_000_000.0
        let amount = Int((Double(bytes) / divisor).rounded())
        return "\(amount) \(useTB ? "TB" : "GB")"
    }
}
