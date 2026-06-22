import SwiftUI

/// A horizontal slider whose thumb cannot move past `cap`. The portion of the track above the
/// cap is greyed to show that range is unavailable, with a tick at the cap. `value` is the real
/// fraction (0...1). When `cap >= 1` it looks and behaves like an ordinary full slider.
struct CappedSlider: View {
    @Binding var value: Double
    var cap: Double = 1.0

    @Environment(\.isEnabled) private var isEnabled

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(0, width - thumbSize)          // travel of the thumb centre
            let cap = min(1, max(0, self.cap))
            let value = min(max(0, self.value), cap)
            let capX = thumbSize / 2 + usable * cap
            let valueX = thumbSize / 2 + usable * value

            ZStack(alignment: .leading) {
                // Whole track — the faint baseline doubles as the "unavailable" look above the cap.
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: trackHeight)

                // Available range 0...cap rendered as a normal (darker) track.
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: capX, height: trackHeight)

                // Accent fill 0...value.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: valueX, height: trackHeight)

                // Tick marking the cap.
                if cap < 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 1.5, height: thumbSize * 0.7)
                        .offset(x: capX - 0.75)
                }

                // Thumb.
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12)))
                    .shadow(radius: 1, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: valueX - thumbSize / 2)
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled, usable > 0 else { return }
                        let frac = (drag.location.x - thumbSize / 2) / usable
                        self.value = min(max(0, frac), cap)
                    }
            )
            .opacity(isEnabled ? 1 : 0.5)
        }
        .frame(height: thumbSize)
    }
}
