import AppKit
import SwiftUI

/// A lightweight on-screen overlay (like the macOS brightness HUD) shown on a specific screen
/// when we adjust an external display's brightness from the keyboard. Used on the main thread.
final class BrightnessOSD {
    static let shared = BrightnessOSD()

    private var panel: NSPanel?
    private let model = OSDModel()
    private var hideWork: DispatchWorkItem?

    func show(value: Double, on screen: NSScreen) {
        model.value = min(1, max(0, value))

        let panel = ensurePanel()
        let side: CGFloat = 200
        panel.setFrame(
            NSRect(x: screen.frame.midX - side / 2,
                   y: screen.frame.minY + screen.frame.height * 0.10,
                   width: side, height: side),
            display: true
        )
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OSDView(model: model))
        self.panel = panel
        return panel
    }
}

final class OSDModel: ObservableObject {
    @Published var value: Double = 0
}

private struct OSDView: View {
    @ObservedObject var model: OSDModel
    private let segmentCount = 16

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 54))
            HStack(spacing: 3) {
                ForEach(0 ..< segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Double(index) / Double(segmentCount) < model.value
                              ? Color.primary
                              : Color.primary.opacity(0.18))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: 200, height: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
