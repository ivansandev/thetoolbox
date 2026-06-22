import CoreGraphics
import Foundation

/// Controls brightness of the built-in / Apple displays via the private DisplayServices
/// framework, resolved at runtime with dlopen/dlsym so there is no link-time dependency on
/// a private framework. Brightness is expressed as 0...1.
final class BuiltInDisplayControl {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private let getFn: GetBrightness?
    private let setFn: SetBrightness?
    private let canFn: CanChange?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        // Intentionally not dlclose'd: the resolved symbols live for the process lifetime.
        guard let handle = dlopen(path, RTLD_LAZY) else {
            getFn = nil; setFn = nil; canFn = nil
            return
        }
        getFn = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
        setFn = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        canFn = dlsym(handle, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChange.self) }
    }

    var isAvailable: Bool { setFn != nil }

    func canControl(_ id: CGDirectDisplayID) -> Bool {
        canFn?(id) ?? false
    }

    func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(id, &value) == 0 ? value : nil
    }

    @discardableResult
    func setBrightness(_ value: Float, _ id: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        return setFn(id, min(1, max(0, value))) == 0
    }
}
