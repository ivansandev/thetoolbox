import KeyboardShortcuts

/// Stable names for the built-in window shortcuts. The recorded key combos are persisted
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
}
