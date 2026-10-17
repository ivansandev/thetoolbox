import KeyboardShortcuts

/// Stable names for the built-in shortcuts. The recorded key combos are persisted
/// automatically by KeyboardShortcuts, keyed by these names. Custom sizes use dynamic names
/// derived from their UUID (see `WindowManager.shortcutName(for:)`).
extension KeyboardShortcuts.Name {
    static let windowLeftHalf = Self("windowLeftHalf")
    static let windowRightHalf = Self("windowRightHalf")
    static let windowTopHalf = Self("windowTopHalf")
    static let windowBottomHalf = Self("windowBottomHalf")
    static let windowMaximize = Self("windowMaximize")
    static let windowCenter = Self("windowCenter")
    static let windowCenterFit = Self("windowCenterFit")
    static let windowDisplayLeft = Self("windowDisplayLeft")
    static let windowDisplayRight = Self("windowDisplayRight")

    static let windowShortcuts: [Self] = [
        .windowLeftHalf, .windowRightHalf, .windowTopHalf,
        .windowBottomHalf, .windowMaximize, .windowCenter, .windowCenterFit,
        .windowDisplayLeft, .windowDisplayRight,
    ]

    static let spacePrevious = Self("spacePrevious")
    static let spaceNext = Self("spaceNext")

    /// Jump straight to space `number` (1-based).
    static func switchToSpace(_ number: Int) -> Self {
        Self("switchToSpace\(number)")
    }

    static let spaceShortcuts: [Self] =
        [.spacePrevious, .spaceNext]
            + (1 ... SpaceSwitcher.maxSpaces).map { KeyboardShortcuts.Name.switchToSpace($0) }
}
