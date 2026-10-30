import Darwin

/// Looks up private C functions at runtime, so a symbol that a macOS update removes returns nil
/// instead of stopping the app from launching.
enum PrivateSymbols {
    private static let handles: [UnsafeMutableRawPointer] = {
        let paths: [String] = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        ]
        return paths.compactMap { path in path.withCString { dlopen($0, RTLD_LAZY) } }
    }()

    /// `T` must be a `@convention(c)` function type matching the symbol's real signature.
    static func function<T>(_ name: String, as _: T.Type) -> T? {
        for handle in handles {
            if let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: T.self)
            }
        }
        return nil
    }
}
