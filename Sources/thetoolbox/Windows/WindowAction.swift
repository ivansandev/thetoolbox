import CoreGraphics
import Foundation

/// A built-in window placement, expressed as a fraction of a screen's visible frame.
enum WindowAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .maximize: return "Maximize"
        }
    }

    /// Visual top-left fractional rect: x, y measured from the top-left; w, h as fractions.
    private var visualRect: (x: Double, y: Double, w: Double, h: Double) {
        let third = 1.0 / 3.0
        switch self {
        case .leftHalf: return (0, 0, 0.5, 1)
        case .rightHalf: return (0.5, 0, 0.5, 1)
        case .topHalf: return (0, 0, 1, 0.5)
        case .bottomHalf: return (0, 0.5, 1, 0.5)
        case .topLeft: return (0, 0, 0.5, 0.5)
        case .topRight: return (0.5, 0, 0.5, 0.5)
        case .bottomLeft: return (0, 0.5, 0.5, 0.5)
        case .bottomRight: return (0.5, 0.5, 0.5, 0.5)
        case .leftThird: return (0, 0, third, 1)
        case .centerThird: return (third, 0, third, 1)
        case .rightThird: return (2 * third, 0, third, 1)
        case .leftTwoThirds: return (0, 0, 2 * third, 1)
        case .rightTwoThirds: return (third, 0, 2 * third, 1)
        case .maximize: return (0, 0, 1, 1)
        }
    }

    /// Target rect in AppKit coordinates (bottom-left origin) within the given visible frame.
    func rect(in visibleFrame: CGRect) -> CGRect {
        let r = visualRect
        let width = visibleFrame.width * r.w
        let height = visibleFrame.height * r.h
        let x = visibleFrame.minX + visibleFrame.width * r.x
        // Convert visual y-from-top to AppKit y-from-bottom.
        let y = visibleFrame.minY + visibleFrame.height * (1 - r.y - r.h)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A user-defined size: width/height as fractions of the visible frame, placed centered.
/// Ideal for 4K screens where full-screen is rarely wanted.
struct CustomSize: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var widthFraction: Double
    var heightFraction: Double

    /// Centered target rect in AppKit coordinates within the given visible frame.
    func rect(in visibleFrame: CGRect) -> CGRect {
        let width = visibleFrame.width * min(1, max(0.05, widthFraction))
        let height = visibleFrame.height * min(1, max(0.05, heightFraction))
        return CGRect(x: visibleFrame.minX + (visibleFrame.width - width) / 2,
                      y: visibleFrame.minY + (visibleFrame.height - height) / 2,
                      width: width,
                      height: height)
    }
}
