import CoreGraphics
import Foundation

/// Runtime state for one display the app can control. Slider values are stored as 0...1
/// "UI positions"; `DisplayManager` maps them through the per-display cap to the value sent
/// to hardware.
final class ManagedDisplay: ObservableObject, Identifiable {
    enum Kind { case builtIn, external }

    let id: CGDirectDisplayID
    let key: String            // stable across reconnects (display UUID)
    let name: String
    let kind: Kind
    let canBrightness: Bool
    let canContrast: Bool
    let canVolume: Bool

    @Published var brightnessUI: Double
    @Published var contrastUI: Double
    @Published var volumeUI: Double

    /// Approximate current luminance in nits (built-in display only; nil for external displays or when
    /// brightness can't be read). Estimated from the brightness slider position — see `BuiltInDisplaySpecs`.
    @Published var nits: Double? = nil

    init(id: CGDirectDisplayID, key: String, name: String, kind: Kind,
         canBrightness: Bool, canContrast: Bool, canVolume: Bool,
         brightnessUI: Double, contrastUI: Double, volumeUI: Double) {
        self.id = id
        self.key = key
        self.name = name
        self.kind = kind
        self.canBrightness = canBrightness
        self.canContrast = canContrast
        self.canVolume = canVolume
        self.brightnessUI = brightnessUI
        self.contrastUI = contrastUI
        self.volumeUI = volumeUI
    }
}
