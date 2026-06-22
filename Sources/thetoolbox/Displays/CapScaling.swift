import Foundation

/// Hard cap for a display control: the slider shows the panel's real fraction and can never
/// exceed the cap. Both value and cap are treated as 0...1.
enum CapScaling {
    /// Clamp `value` to `[0, cap]` (each also clamped to `[0, 1]`).
    static func clamped(_ value: Double, to cap: Double) -> Double {
        min(max(0, value), min(1, max(0, cap)))
    }
}
