import CoreGraphics
import Foundation

/// Thin wrapper over the vendored AppleSiliconDDC. It owns the CGDirectDisplayID ->
/// IOAVService mapping (mutated and read on the main thread). The actual I2C reads/writes are
/// performed by callers on a background queue using a captured service handle, so this map is
/// never touched off the main thread.
final class DDCControl {
    private var services: [CGDirectDisplayID: IOAVService] = [:]

    /// Re-match the given external display IDs to their IOAVService handles.
    func refresh(externalDisplayIDs: [CGDirectDisplayID]) {
        guard !externalDisplayIDs.isEmpty else {
            services = [:]
            return
        }
        var map: [CGDirectDisplayID: IOAVService] = [:]
        for match in AppleSiliconDDC.getServiceMatches(displayIDs: externalDisplayIDs) {
            if let service = match.service, !match.dummy {
                map[match.displayID] = service
            }
        }
        services = map
    }

    func service(for id: CGDirectDisplayID) -> IOAVService? { services[id] }
}
