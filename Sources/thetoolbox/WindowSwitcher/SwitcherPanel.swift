import AppKit
import SwiftUI

/// What the panel shows. `WindowSwitcher` updates it as the selection moves and thumbnails
/// arrive.
final class SwitcherViewModel: ObservableObject {
    @Published var windows: [WindowRecord] = []
    @Published var selectedIndex = 0
    @Published var thumbnails: [CGWindowID: CGImage] = [:]
    @Published var icons: [pid_t: NSImage] = [:]
    @Published var columns = 1
    @Published var layout = SwitcherLayout(tileWidth: SwitcherLayout.minTileWidth)
    /// Pixels per point of the screen the panel is on, so thumbnails draw sharp.
    @Published var scale: CGFloat = 2
}

/// A floating HUD panel in the style of the system ⌘Tab switcher.
final class SwitcherPanel {
    let model = SwitcherViewModel()

    var onHover: ((Int) -> Void)? {
        get { hostingView.onHover }
        set { hostingView.onHover = newValue }
    }

    var onClick: ((Int) -> Void)? {
        get { hostingView.onClick }
        set { hostingView.onClick = newValue }
    }

    private let panel: NSPanel
    private let hostingView: SwitcherHostingView

    init() {
        hostingView = SwitcherHostingView(rootView: SwitcherView(model: model))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(hostingView)

        panel = NonKeyPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = background
    }

    func show(
        windows: [WindowRecord],
        icons: [pid_t: NSImage],
        thumbnails: [CGWindowID: CGImage],
        selectedIndex: Int,
        columns: Int,
        layout: SwitcherLayout,
        on screen: NSScreen
    ) {
        model.layout = layout
        model.scale = screen.backingScaleFactor
        model.columns = columns
        model.icons = icons
        model.thumbnails = thumbnails
        model.windows = windows
        model.selectedIndex = selectedIndex
        hostingView.layout = layout
        hostingView.columns = columns
        hostingView.count = windows.count

        let size = layout.panelSize(count: windows.count, columns: columns)
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Never becomes key, so the app being switched away from keeps keyboard focus.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI tiles and handles the mouse itself: an always-active tracking area works
/// while thetoolbox isn't the active app.
private final class SwitcherHostingView: NSHostingView<SwitcherView> {
    var layout = SwitcherLayout(tileWidth: SwitcherLayout.minTileWidth)
    var columns = 1
    var count = 0
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private var mouseArea: NSTrackingArea?

    required init(rootView: SwitcherView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseArea { removeTrackingArea(mouseArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseArea = area
    }

    // Mouse-moved events only arrive when the pointer actually moves, so a panel that opens
    // under a resting pointer keeps its keyboard selection.
    override func mouseMoved(with event: NSEvent) {
        if let index = tileIndex(for: event) { onHover?(index) }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = tileIndex(for: event) { onClick?(index) }
    }

    private func tileIndex(for event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        return layout.tileIndex(at: CGPoint(x: point.x, y: fromTop), columns: columns, count: count)
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: SwitcherLayout.titleSpacing) {
            VStack(alignment: .leading, spacing: SwitcherLayout.spacing) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: SwitcherLayout.spacing) {
                        ForEach(row, id: \.self) { index in
                            let window = model.windows[index]
                            SwitcherTile(
                                window: window,
                                icon: model.icons[window.pid],
                                thumbnail: model.thumbnails[window.id],
                                isSelected: index == model.selectedIndex,
                                layout: model.layout,
                                scale: model.scale
                            )
                        }
                    }
                }
            }
            Text(selectedTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    width: model.layout.gridSize(count: model.windows.count, columns: model.columns).width,
                    height: SwitcherLayout.titleHeight
                )
        }
        .padding(SwitcherLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rows: [[Int]] {
        let count = model.windows.count
        let columns = max(1, model.columns)
        return stride(from: 0, to: count, by: columns).map { Array($0 ..< min($0 + columns, count)) }
    }

    private var selectedTitle: String {
        model.windows.indices.contains(model.selectedIndex) ? model.windows[model.selectedIndex].displayTitle : ""
    }
}

private struct SwitcherTile: View {
    let window: WindowRecord
    let icon: NSImage?
    let thumbnail: CGImage?
    let isSelected: Bool
    let layout: SwitcherLayout
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: scale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: layout.placeholderIconSize, height: layout.placeholderIconSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if thumbnail != nil, let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: layout.badgeIconSize, height: layout.badgeIconSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: layout.badgeIconSize * 0.2, y: layout.badgeIconSize * 0.2)
            }
        }
        .padding(layout.tileInset)
        .frame(width: layout.tileSize.width, height: layout.tileSize.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.18) : Color.clear)
        )
        .opacity(window.isMinimized || window.isAppHidden ? 0.6 : 1)
    }
}
