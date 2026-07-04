import AppKit
import ApplicationServices
import SwiftUI

/// Temporarily disables the keyboard so it can be wiped without triggering anything. A session
/// CGEventTap swallows every key / modifier / media-key event while a full-screen overlay explains
/// how to stop (a mouse click on the button, or an automatic timeout). The mouse is left working
/// so there's always a way out; requires Accessibility permission (same as the brightness-key tap).
final class KeyboardCleaner: ObservableObject {
    @Published private(set) var isActive = false

    /// Safety net: re-enable the keyboard after this long even if the button is never clicked.
    private let maxDuration: TimeInterval = 120

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlay: NSWindow?
    private var timeout: Timer?

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.prompt()
            return
        }

        // keyDown / keyUp / flagsChanged cover normal + modifier keys; NX_SYSDEFINED (14) covers the
        // media, brightness, and volume keys.
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << 14)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardCleanerCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source

        showOverlay()
        timeout = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            self?.stop()
        }
        isActive = true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        timeout?.invalidate()
        timeout = nil
        overlay?.orderOut(nil)
        overlay = nil
        isActive = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow / interrupted tap; re-enable and pass this event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return nil   // swallow every keyboard event while cleaning
    }

    private func showOverlay() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.contentView = NSHostingView(
            rootView: KeyboardCleanOverlay(deadline: Date().addingTimeInterval(maxDuration)) { [weak self] in
                self?.stop()
            }
        )
        window.orderFrontRegardless()
        overlay = window
    }

    deinit { stop() }
}

private func keyboardCleanerCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let cleaner = Unmanaged<KeyboardCleaner>.fromOpaque(refcon).takeUnretainedValue()
    return cleaner.handle(type: type, event: event)
}

/// Full-screen overlay shown while the keyboard is disabled: instructions, a live countdown, and a
/// mouse-clickable button to finish early.
private struct KeyboardCleanOverlay: View {
    let deadline: Date
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "keyboard")
                    .font(.system(size: 68, weight: .light))
                    .foregroundStyle(.white)
                Text("Keyboard disabled for cleaning")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Wipe away — every key press is ignored. The mouse still works.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Auto re-enables in \(max(0, Int(deadline.timeIntervalSinceNow.rounded())))s")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                Button(action: onExit) {
                    Text("Done — re-enable keyboard")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
    }
}
