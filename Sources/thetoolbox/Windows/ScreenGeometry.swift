import AppKit

/// Coordinate helpers for window placement. AppKit uses a bottom-left origin with y growing
/// up; the Accessibility API uses a top-left origin (of the primary display) with y growing
/// down. These helpers convert between the two and pick the screen a window lives on.
enum ScreenGeometry {
    /// Stage Manager's recent-app thumbnails are not excluded from `NSScreen.visibleFrame`.
    /// Reserve a proportional strip, capped in points so it remains useful at different display
    /// sizes and scaling settings.
    private static let stageManagerStripFraction: CGFloat = 0.14
    private static let maximumStageManagerStripWidth: CGFloat = 200

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

    /// The frame window actions should use when the user wants Stage Manager's recent apps to
    /// remain visible. Apple places that strip on the left, but does not include it in the normal
    /// AppKit safe/visible-frame insets.
    static func leavingRoomForStageManager(in visibleFrame: CGRect) -> CGRect {
        let stripWidth = min(visibleFrame.width * stageManagerStripFraction,
                             maximumStageManagerStripWidth)
        return CGRect(x: visibleFrame.minX + stripWidth,
                      y: visibleFrame.minY,
                      width: max(0, visibleFrame.width - stripWidth),
                      height: visibleFrame.height)
    }
}

enum StageManagerState {
    private static let defaults = UserDefaults(suiteName: "com.apple.WindowManager")

    /// `GloballyEnabled` is the system preference macOS itself updates when Stage Manager is
    /// toggled from Control Center or Desktop & Dock settings.
    static var isEnabled: Bool {
        defaults?.bool(forKey: "GloballyEnabled") == true
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
