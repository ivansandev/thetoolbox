import Foundation

/// Serializes and coalesces slow hardware writes (a DDC/CI write is ~20-40 ms) so a rapid
/// slider drag never floods the I2C bus. For each key only the most recent write is kept;
/// a single background drain always converges to the latest value. Because every key shares
/// one serial queue, only one hardware write runs at a time across all displays/controls.
final class WriteCoalescer {
    private let queue = DispatchQueue(label: "com.ivansandev.thetoolbox.hwwrite", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [String: () -> Void] = [:]
    private var scheduled: Set<String> = []

    func submit(key: String, _ work: @escaping () -> Void) {
        lock.lock()
        pending[key] = work
        let needsSchedule = !scheduled.contains(key)
        if needsSchedule { scheduled.insert(key) }
        lock.unlock()

        guard needsSchedule else { return }
        queue.async { [weak self] in self?.drain(key: key) }
    }

    private func drain(key: String) {
        while true {
            lock.lock()
            guard let work = pending.removeValue(forKey: key) else {
                scheduled.remove(key)
                lock.unlock()
                return
            }
            lock.unlock()
            work()
        }
    }
}
