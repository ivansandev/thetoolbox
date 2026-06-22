import AppKit

/// Coordinate helpers for window placement. AppKit uses a bottom-left origin with y growing
/// up; the Accessibility API uses a top-left origin (of the primary display) with y growing
/// down. These helpers convert between the two and pick the screen a window lives on.
enum ScreenGeometry {
    /// The primary display's frame (the screen whose origin is (0, 0)).
    static var primaryFrame: CGRect {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
            ?? NSScreen.main?.frame
            ?? .zero
    }

    /// Flip a global rect between AppKit (bottom-left origin) and AX/CG (top-left origin)
    /// coordinates. The transform is its own inverse.
    static func flipY(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryFrame.height - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The screen a window (given as an AppKit-coordinate rect) is on: the one containing its
    /// center, else the one it overlaps most.
    static func screen(forAppKitRect rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        return NSScreen.screens.max {
            $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
