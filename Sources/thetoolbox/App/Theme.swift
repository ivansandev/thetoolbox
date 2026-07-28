import AppKit
import SwiftUI

extension Color {
    /// A semantic success/healthy color that remains legible in both appearances.
    static let statusGreen = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? .systemGreen
            : NSColor(srgbRed: 0.075, green: 0.478, blue: 0.231, alpha: 1)
    })
}
