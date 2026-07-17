import Foundation

/// Estimated luminance specs for this Mac's built-in display.
///
/// macOS exposes no API for a display's true measured nits — every brightness API works in a 0...1
/// fraction. The best a clean implementation can do is estimate: map the 0...1 brightness against the
/// panel's published **SDR peak nits**. The SDR peaks below come from Apple's public tech specs (facts,
/// not code — no third-party source is copied). The 1000/1600-nit figures for XDR panels are HDR/EDR
/// peaks, which the normal brightness slider never reaches, so this table uses the SDR peak only.
enum BuiltInDisplaySpecs {
    /// SDR peak nits for the machine running the app, resolved once from `hw.model`. Falls back to 500
    /// (the typical Apple-Silicon SDR peak) for models not in the table.
    static let maxNits: Double = sdrPeakNits(forModel: machineModel())

    /// Approximate nits for a 0...1 *perceptual* brightness — the macOS slider position returned by
    /// `DisplayServicesGetBrightness`. macOS's perceptual→luminance mapping isn't public, so this uses
    /// a piecewise curve (the same shape as the MIT-licensed Lunar project): linear 0→140 nits across
    /// the lower half of the slider, then logarithmic 140→`maxNits` across the upper half. It is exact
    /// at the endpoints (0, and full = `maxNits`) and an estimate in between. Deriving nits directly
    /// from the slider value — rather than a hardware read — lets the reading track a drag in real time.
    static func nits(brightness: Double) -> Double {
        let b = max(0, min(1, brightness))
        guard maxNits > 140 else { return b * maxNits }   // degenerate panels: plain linear
        if b <= 0.5 { return b * 280 }                    // 0 → 140 nits at the half-slider
        let t = (b - 0.5) / 0.5                            // 0 → 1 across the upper half
        return 140 * pow(maxNits / 140, t)                // 140 → maxNits
    }

    /// The machine's model identifier (e.g. "Mac15,3"), or "" if the sysctl is unavailable.
    static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    private static func sdrPeakNits(forModel model: String) -> Double {
        peakByModel[model] ?? defaultPeak
    }

    private static let defaultPeak: Double = 500

    /// Model identifier → SDR peak nits, from Apple's published specs.
    private static let peakByModel: [String: Double] = [
        // MacBook Air
        "MacBookAir10,1": 400,          // M1, 2020
        "Mac14,2": 500,                 // M2 13″, 2022
        "Mac14,15": 500,                // M2 15″, 2023
        "Mac15,12": 500,                // M3 13″, 2024
        "Mac15,13": 500,                // M3 15″, 2024
        "Mac16,12": 500,                // M4 13″, 2025
        "Mac16,13": 500,                // M4 15″, 2025

        // MacBook Pro 13″ (Touch Bar)
        "MacBookPro17,1": 500,          // M1, 2020
        "Mac14,7": 500,                 // M2, 2022

        // MacBook Pro 14″/16″ Liquid Retina XDR — M1/M2 (SDR peak 500)
        "MacBookPro18,1": 500,          // 16″ M1 Pro/Max
        "MacBookPro18,2": 500,          // 16″ M1 Max
        "MacBookPro18,3": 500,          // 14″ M1 Pro/Max
        "MacBookPro18,4": 500,          // 14″ M1 Max
        "Mac14,5": 500,                 // 14″ M2 Max
        "Mac14,6": 500,                 // 16″ M2 Max
        "Mac14,9": 500,                 // 14″ M2 Pro
        "Mac14,10": 500,                // 16″ M2 Pro

        // MacBook Pro 14″/16″ Liquid Retina XDR — M3 (SDR peak 600, the "20% brighter" bump)
        "Mac15,3": 600,                 // 14″ M3
        "Mac15,6": 600,                 // 14″ M3 Pro
        "Mac15,8": 600,                 // 14″ M3 Max
        "Mac15,10": 600,                // 14″ M3 Max
        "Mac15,7": 600,                 // 16″ M3 Pro
        "Mac15,9": 600,                 // 16″ M3 Max
        "Mac15,11": 600,                // 16″ M3 Max

        // MacBook Pro 14″/16″ Liquid Retina XDR — M4/M5 (SDR raised to 1000 nits)
        "Mac16,1": 1000,                // 14″ M4
        "Mac16,6": 1000,                // 14″ M4 Max
        "Mac16,8": 1000,                // 14″ M4 Pro
        "Mac16,5": 1000,                // 16″ M4 Max
        "Mac16,7": 1000,                // 16″ M4 Pro
        "Mac17,9": 1000,                // 16″ M5 Pro
    ]
}
