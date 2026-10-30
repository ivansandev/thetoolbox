import AppKit
import ScreenCaptureKit

/// Small window images for the switcher, from ScreenCaptureKit. Kept in memory only, with an
/// LRU limit. `cached` and the cache itself are main-thread only; `capture` hops back to the
/// main thread for each image.
final class ThumbnailCapturer {
    static let maxCached = 100
    static let maxConcurrent = 4

    private var cache: [CGWindowID: CGImage] = [:]
    private var lastUse: [CGWindowID: UInt64] = [:]
    private var clock: UInt64 = 0

    func cached(_ id: CGWindowID) -> CGImage? {
        guard let image = cache[id] else { return nil }
        touch(id)
        return image
    }

    /// Captures `ids`, at most `maxConcurrent` at a time, calling `onImage` on the main thread as
    /// each image arrives. Does nothing without Screen Recording access. Stops when cancelled.
    func capture(_ ids: [CGWindowID], maxSize: CGSize, onImage: @escaping (CGWindowID, CGImage) -> Void) async {
        guard ScreenRecordingPermission.isGranted, !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = ids.compactMap { byID[$0] }.makeIterator()

        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for _ in 0 ..< Self.maxConcurrent {
                guard let window = pending.next() else { break }
                group.addTask { (window.windowID, await Self.image(of: window, maxSize: maxSize)) }
            }
            while let result = await group.next() {
                let (id, image) = result
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if let image {
                    await MainActor.run {
                        self.store(image, for: id)
                        onImage(id, image)
                    }
                }
                if let window = pending.next() {
                    group.addTask { (window.windowID, await Self.image(of: window, maxSize: maxSize)) }
                }
            }
        }
    }

    private static func image(of window: SCWindow, maxSize: CGSize) async -> CGImage? {
        let frame = window.frame.size
        guard frame.width > 0, frame.height > 0 else { return nil }
        // Fit inside maxSize, at 2× for Retina.
        let scale = min(maxSize.width / frame.width, maxSize.height / frame.height, 1) * 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func store(_ image: CGImage, for id: CGWindowID) {
        cache[id] = image
        touch(id)
        while cache.count > Self.maxCached,
              let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
            cache.removeValue(forKey: oldest)
            lastUse.removeValue(forKey: oldest)
        }
    }

    private func touch(_ id: CGWindowID) {
        clock &+= 1
        lastUse[id] = clock
    }
}
