import Foundation

/// The monitor picture settings exposed as "color profiles". Both are discrete MCCS features:
/// the monitor lists the values it accepts in its capabilities string.
enum ColorProfileFeature: CaseIterable {
    case presetMode
    case colorPreset

    var code: VCPCode {
        switch self {
        case .presetMode: return .displayMode
        case .colorPreset: return .colorPreset
        }
    }

    var title: String {
        switch self {
        case .presetMode: return "Preset mode"
        case .colorPreset: return "Color preset"
        }
    }

    /// EDID manufacturer ID "DEL", as reported by `CGDisplayVendorNumber`.
    static let dellVendorID: UInt32 = 0x10AC

    /// MCCS names for the standard values; anything else shows its raw value. Dell monitors
    /// get the names their on-screen menu uses for the color presets instead.
    func name(for value: UInt16, vendorID: UInt32? = nil) -> String {
        if self == .colorPreset, vendorID == Self.dellVendorID,
           let name = [0x05: "Warm", 0x08: "Cool", 0x0B: "Custom Color", 0x0C: "Standard"][value] {
            return name
        }
        let names: [UInt16: String]
        switch self {
        case .presetMode:
            names = [0x00: "Standard", 0x01: "Productivity", 0x02: "Mixed", 0x03: "Movie",
                     0x04: "User Defined", 0x05: "Game", 0x06: "Sports", 0x07: "Professional",
                     0x08: "Standard (Reduced Power)", 0x09: "Standard (Low Power)",
                     0x0A: "Demonstration", 0xF0: "Dynamic Contrast"]
        case .colorPreset:
            names = [0x01: "sRGB", 0x02: "Display Native", 0x03: "4000 K", 0x04: "5000 K",
                     0x05: "6500 K", 0x06: "7500 K", 0x07: "8200 K", 0x08: "9300 K",
                     0x09: "10000 K", 0x0A: "11500 K", 0x0B: "User 1", 0x0C: "User 2",
                     0x0D: "User 3"]
        }
        if let name = names[value] { return name }
        return String(format: "%@ 0x%02X", self == .presetMode ? "Mode" : "Preset", Int(value))
    }
}

/// One color-profile feature of a display: the values its monitor advertises and the one
/// currently selected (nil until it has been read, or when the read fails).
struct ColorProfileOptions: Identifiable, Equatable {
    let feature: ColorProfileFeature
    let values: [UInt16]
    var current: UInt16?

    var id: ColorProfileFeature { feature }
}
