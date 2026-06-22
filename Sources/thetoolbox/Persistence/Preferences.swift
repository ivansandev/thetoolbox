import Foundation

/// Persisted per-display settings. Keyed by the display's stable UUID so they survive
/// reconnects and reboots.
struct DisplaySettings: Codable {
    var brightnessCap: Double = 1.0
    var contrastCap: Double = 1.0
    var lastBrightnessUI: Double = 1.0
    var lastContrastUI: Double = 1.0
    var lastVolumeUI: Double = 0.25
    // External-only: follow the built-in display's brightness, mapped linearly so that
    // built-in 0% -> syncExternalAtMin and built-in 100% -> syncExternalAtMax (UI fractions).
    var syncFromBuiltIn: Bool = false
    var syncExternalAtMin: Double = 0.0
    var syncExternalAtMax: Double = 1.0

    init() {}

    // Custom decoder so older stored settings (missing the newer keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightnessCap = try c.decodeIfPresent(Double.self, forKey: .brightnessCap) ?? 1.0
        contrastCap = try c.decodeIfPresent(Double.self, forKey: .contrastCap) ?? 1.0
        lastBrightnessUI = try c.decodeIfPresent(Double.self, forKey: .lastBrightnessUI) ?? 1.0
        lastContrastUI = try c.decodeIfPresent(Double.self, forKey: .lastContrastUI) ?? 1.0
        lastVolumeUI = try c.decodeIfPresent(Double.self, forKey: .lastVolumeUI) ?? 0.25
        syncFromBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .syncFromBuiltIn) ?? false
        syncExternalAtMin = try c.decodeIfPresent(Double.self, forKey: .syncExternalAtMin) ?? 0.0
        syncExternalAtMax = try c.decodeIfPresent(Double.self, forKey: .syncExternalAtMax) ?? 1.0
    }
}

final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private let storeKey = "displaySettings.v1"
    private let customSizesKey = "customWindowSizes.v1"
    private let followCursorKey = "brightnessKeysFollowCursor.v1"
    private var displays: [String: DisplaySettings]

    private init() {
        if let data = defaults.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([String: DisplaySettings].self, from: data) {
            displays = decoded
        } else {
            displays = [:]
        }
    }

    func settings(for key: String) -> DisplaySettings {
        displays[key] ?? DisplaySettings()
    }

    func update(_ key: String, _ mutate: (inout DisplaySettings) -> Void) {
        var settings = displays[key] ?? DisplaySettings()
        mutate(&settings)
        displays[key] = settings
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(displays) {
            defaults.set(data, forKey: storeKey)
        }
    }

    // MARK: Custom window sizes

    func loadCustomSizes() -> [CustomSize] {
        guard let data = defaults.data(forKey: customSizesKey),
              let sizes = try? JSONDecoder().decode([CustomSize].self, from: data) else { return [] }
        return sizes
    }

    func saveCustomSizes(_ sizes: [CustomSize]) {
        if let data = try? JSONEncoder().encode(sizes) {
            defaults.set(data, forKey: customSizesKey)
        }
    }

    // MARK: Brightness keys

    var brightnessKeysFollowCursor: Bool {
        get { defaults.object(forKey: followCursorKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: followCursorKey) }
    }
}
