import AppKit
import CoreGraphics

/// Central display-control state. Enumerates displays, observes hot-plug, and routes slider
/// intents through the per-display cap to the correct hardware backend (DDC for external,
/// DisplayServices for built-in). UI state lives on the main thread; hardware writes are
/// coalesced onto a single background queue.
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [ManagedDisplay] = []

    private let ddc = DDCControl()
    private let builtIn = BuiltInDisplayControl()
    private let coalescer = WriteCoalescer()
    private let brightnessKeyTap = BrightnessKeyTap()
    private let prefs = Preferences.shared
    private var maxValues: [CGDirectDisplayID: [VCPCode: UInt16]] = [:]
    /// Color-profile options per display key. Kept across `refresh()` (which rebuilds the
    /// display objects) so the slow capabilities read happens once per monitor, not per hot-plug.
    private var colorProfileCache: [String: [ColorProfileOptions]] = [:]
    private var colorProfileLoads: Set<String> = []
    private var screenObserver: NSObjectProtocol?
    private var syncTimer: Timer?
    private var lastBuiltInBrightness: Double = -1

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        setupBrightnessKeys()
        startBrightnessSync()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        syncTimer?.invalidate()
    }

    // MARK: Enumeration

    func refresh() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            displays = []
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }

        // Active, non-mirrored displays only.
        let active = ids.filter {
            CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay
        }
        let externalIDs = active.filter { CGDisplayIsBuiltin($0) == 0 }
        ddc.refresh(externalDisplayIDs: externalIDs)

        var result: [ManagedDisplay] = []
        for id in active {
            let key = Self.stableKey(for: id)
            let saved = prefs.settings(for: key)

            if CGDisplayIsBuiltin(id) != 0 {
                let canBrightness = builtIn.isAvailable && builtIn.canControl(id)
                let display = ManagedDisplay(
                    id: id, key: key,
                    name: Self.localizedName(for: id) ?? "Built-in Display",
                    kind: .builtIn,
                    canBrightness: canBrightness, canContrast: false, canVolume: false,
                    brightnessUI: saved.lastBrightnessUI,
                    contrastUI: saved.lastContrastUI,
                    volumeUI: saved.lastVolumeUI
                )
                // Built-in brightness reads are reliable: reflect the real current value.
                if canBrightness, let actual = builtIn.brightness(id) {
                    display.brightnessUI = CapScaling.clamped(Double(actual), to: saved.brightnessCap)
                    display.nits = BuiltInDisplaySpecs.nits(brightness: Double(actual))
                }
                result.append(display)
            } else {
                let hasDDC = ddc.service(for: id) != nil
                let display = ManagedDisplay(
                    id: id, key: key,
                    name: Self.localizedName(for: id) ?? "External Display",
                    kind: .external,
                    canBrightness: hasDDC, canContrast: hasDDC, canVolume: hasDDC,
                    brightnessUI: saved.lastBrightnessUI,
                    contrastUI: saved.lastContrastUI,
                    volumeUI: saved.lastVolumeUI
                )
                result.append(display)
                if hasDDC {
                    learnBrightnessMax(for: id)
                    // Enforce the saved state + cap on (re)connect so the panel can never sit
                    // above the configured safe maximum.
                    applyBrightness(display)
                    applyContrast(display)
                    if let cached = colorProfileCache[key] {
                        display.colorProfiles = cached
                    } else {
                        loadColorProfiles(for: display)
                    }
                }
            }
        }
        displays = result
        #if DEBUG
        let summary = result.map { display in
            "\(display.name)[\(display.kind == .builtIn ? "builtin" : "external") b:\(display.canBrightness) c:\(display.canContrast) v:\(display.canVolume)]"
        }.joined(separator: " | ")
        NSLog("thetoolbox displays: %@", summary.isEmpty ? "none" : summary)
        #endif
    }

    // MARK: Slider intents (from the menu UI)

    func setBrightness(_ value: Double, for display: ManagedDisplay) {
        display.brightnessUI = CapScaling.clamped(value, to: brightnessCap(for: display))
        if display.kind == .builtIn {
            // Update the nits estimate in lockstep with the slider — before the async hardware write —
            // so the reading tracks a drag in real time instead of waiting for the next poll tick.
            display.nits = BuiltInDisplaySpecs.nits(brightness: display.brightnessUI)
        }
        applyBrightness(display)
    }

    func setContrast(_ value: Double, for display: ManagedDisplay) {
        display.contrastUI = CapScaling.clamped(value, to: contrastCap(for: display))
        applyContrast(display)
    }

    func setVolume(_ ui: Double, for display: ManagedDisplay) {
        display.volumeUI = ui
        applyVolume(display)
    }

    // MARK: Caps (from Settings)

    func brightnessCap(for display: ManagedDisplay) -> Double { prefs.settings(for: display.key).brightnessCap }
    func contrastCap(for display: ManagedDisplay) -> Double { prefs.settings(for: display.key).contrastCap }

    func setBrightnessCap(_ cap: Double, for display: ManagedDisplay) {
        prefs.update(display.key) { $0.brightnessCap = cap }
        display.brightnessUI = CapScaling.clamped(display.brightnessUI, to: cap)
        objectWillChange.send()
        applyBrightness(display)
    }

    func setContrastCap(_ cap: Double, for display: ManagedDisplay) {
        prefs.update(display.key) { $0.contrastCap = cap }
        display.contrastUI = CapScaling.clamped(display.contrastUI, to: cap)
        objectWillChange.send()
        applyContrast(display)
    }

    // MARK: Color profiles (from Settings)

    func setColorProfile(_ value: UInt16, feature: ColorProfileFeature, for display: ManagedDisplay) {
        guard var options = colorProfileCache[display.key],
              let index = options.firstIndex(where: { $0.feature == feature }) else { return }
        options[index].current = value
        publishColorProfiles(options, forKey: display.key)

        let code = feature.code.rawValue
        updateColorProfileSelection(for: display, jobKey: "\(display.id).\(code)") { service in
            _ = AppleSiliconDDC.write(service: service, command: code, value: value)
            usleep(500_000)   // let the monitor finish switching before reading back
        }
    }

    /// Re-reads the current selection of each color-profile feature, e.g. to pick up a change
    /// made with the monitor's own buttons.
    func refreshColorProfileSelection(for display: ManagedDisplay) {
        updateColorProfileSelection(for: display, jobKey: "\(display.id).colorprofiles") { _ in }
    }

    /// Runs `work` on the hardware queue, then reads every feature's selection back. Monitors
    /// couple these features (on Dell, picking a color preset resets the preset mode and vice
    /// versa), so after a write all of them are re-read rather than trusting the value sent.
    private func updateColorProfileSelection(for display: ManagedDisplay, jobKey: String,
                                             after work: @escaping (IOAVService) -> Void) {
        guard let service = ddc.service(for: display.id) else { return }
        let key = display.key
        let features = display.colorProfiles.map(\.feature)
        guard !features.isEmpty else { return }
        coalescer.submit(key: jobKey) { [weak self] in
            work(service)
            let current = Self.readColorProfileSelection(features, service: service)
            DispatchQueue.main.async {
                guard let self, var options = self.colorProfileCache[key] else { return }
                for index in options.indices {
                    if let value = current[options[index].feature] { options[index].current = value }
                }
                self.publishColorProfiles(options, forKey: key)
            }
        }
    }

    /// Asks the monitor which color-profile values it supports (its DDC capabilities string).
    private func loadColorProfiles(for display: ManagedDisplay) {
        guard let service = ddc.service(for: display.id) else { return }
        let key = display.key
        guard colorProfileLoads.insert(key).inserted else { return }
        coalescer.submit(key: "\(display.id).capabilities") { [weak self] in
            var options: [ColorProfileOptions]?
            if let capabilities = DDCCapabilities.read(service: service) {
                let features = ColorProfileFeature.allCases.filter { !capabilities.values(for: $0.code).isEmpty }
                let current = Self.readColorProfileSelection(features, service: service)
                options = features.map {
                    ColorProfileOptions(feature: $0, values: capabilities.values(for: $0.code), current: current[$0])
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.colorProfileLoads.remove(key)
                // No answer: leave it uncached so the next refresh tries again.
                if let options { self.publishColorProfiles(options, forKey: key) }
            }
        }
    }

    private func publishColorProfiles(_ options: [ColorProfileOptions], forKey key: String) {
        colorProfileCache[key] = options
        displays.first { $0.key == key }?.colorProfiles = options
    }

    private static func readColorProfileSelection(_ features: [ColorProfileFeature],
                                                  service: IOAVService) -> [ColorProfileFeature: UInt16] {
        var current: [ColorProfileFeature: UInt16] = [:]
        for feature in features {
            if let reply = AppleSiliconDDC.read(service: service, command: feature.code.rawValue) {
                current[feature] = reply.current & 0xFF   // the value is the low byte; the high byte is unspecified
            }
        }
        return current
    }

    // MARK: Brightness sync (built-in -> external)

    var hasBuiltInDisplay: Bool {
        displays.contains { $0.kind == .builtIn }
    }

    func isBrightnessSynced(_ display: ManagedDisplay) -> Bool {
        prefs.settings(for: display.key).syncFromBuiltIn
    }

    func syncRange(for display: ManagedDisplay) -> (atMin: Double, atMax: Double) {
        let settings = prefs.settings(for: display.key)
        return (settings.syncExternalAtMin, settings.syncExternalAtMax)
    }

    func setSyncEnabled(_ enabled: Bool, for display: ManagedDisplay) {
        prefs.update(display.key) { $0.syncFromBuiltIn = enabled }
        objectWillChange.send()
        lastBuiltInBrightness = -1   // force the next tick to re-apply
        syncTick()
    }

    func setSyncRange(atMin: Double, atMax: Double, for display: ManagedDisplay) {
        prefs.update(display.key) {
            $0.syncExternalAtMin = atMin
            $0.syncExternalAtMax = atMax
        }
        objectWillChange.send()
        lastBuiltInBrightness = -1
        syncTick()
    }

    private func startBrightnessSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Retry installing the brightness-key tap until Accessibility is granted.
            if !self.brightnessKeyTap.isRunning { self.brightnessKeyTap.start() }
            self.syncTick()
        }
    }

    /// Polls the built-in brightness; when it changes, reflects it in the built-in slider and
    /// drives any external displays set to follow it (mapped linearly, then through their cap).
    private func syncTick() {
        guard let builtInDisplay = displays.first(where: { $0.kind == .builtIn && $0.canBrightness }),
              let actual = builtIn.brightness(builtInDisplay.id) else { return }
        let builtInActual = Double(actual)
        guard abs(builtInActual - lastBuiltInBrightness) > 0.001 else { return }
        lastBuiltInBrightness = builtInActual

        // Keep the built-in slider in step with the hardware brightness keys.
        let builtInCap = prefs.settings(for: builtInDisplay.key).brightnessCap
        builtInDisplay.brightnessUI = CapScaling.clamped(builtInActual, to: builtInCap)
        builtInDisplay.nits = BuiltInDisplaySpecs.nits(brightness: builtInActual)

        for display in displays where display.kind == .external && display.canBrightness {
            let settings = prefs.settings(for: display.key)
            guard settings.syncFromBuiltIn else { continue }
            let mapped = settings.syncExternalAtMin
                + builtInActual * (settings.syncExternalAtMax - settings.syncExternalAtMin)
            setBrightness(min(1, max(0, mapped)), for: display)
        }
    }

    // MARK: Brightness keys (route to the display under the pointer)

    var brightnessKeysFollowCursor: Bool {
        get { prefs.brightnessKeysFollowCursor }
        set {
            prefs.brightnessKeysFollowCursor = newValue
            objectWillChange.send()
        }
    }

    private func setupBrightnessKeys() {
        brightnessKeyTap.handler = { [weak self] up, isKeyDown in
            self?.handleBrightnessKey(up: up, isKeyDown: isKeyDown) ?? false
        }
        let started = brightnessKeyTap.start()
        #if DEBUG
        NSLog("thetoolbox brightness-key tap installed: \(started) (needs Accessibility)")
        #endif
    }

    /// Returns true when we handle the key (consuming it). For external DDC displays we always
    /// take over (the keys otherwise change the built-in, not the external). For the built-in we
    /// take over only when a brightness cap is set — uncapped, we let macOS handle it natively
    /// (keeping the native HUD); with a cap we must intercept so the keys can't exceed it.
    private func handleBrightnessKey(up: Bool, isKeyDown: Bool) -> Bool {
        guard prefs.brightnessKeysFollowCursor,
              let display = displayUnderCursor(),
              display.canBrightness else { return false }

        if display.kind == .builtIn, brightnessCap(for: display) >= 1.0 {
            return false   // no cap on the built-in → let macOS handle the keys natively
        }

        if isKeyDown {
            let step = 1.0 / 16.0
            let newValue = min(1, max(0, display.brightnessUI + (up ? step : -step)))
            setBrightness(newValue, for: display)
            if let screen = screen(for: display.id) {
                BrightnessOSD.shared.show(value: display.brightnessUI, on: screen)
            }
        }
        return true
    }

    private func displayUnderCursor() -> ManagedDisplay? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return displays.first { $0.id == number }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }

    // MARK: Applying values to hardware

    private func applyBrightness(_ display: ManagedDisplay) {
        let cap = prefs.settings(for: display.key).brightnessCap
        let actual = CapScaling.clamped(display.brightnessUI, to: cap)
        prefs.update(display.key) { $0.lastBrightnessUI = display.brightnessUI }

        switch display.kind {
        case .builtIn:
            let value = Float(actual)
            let id = display.id
            let control = builtIn
            coalescer.submit(key: "\(id).brightness") { control.setBrightness(value, id) }
        case .external:
            writeVCP(.brightness, actual: actual, display: display)
        }
    }

    private func applyContrast(_ display: ManagedDisplay) {
        guard display.kind == .external else { return }
        let cap = prefs.settings(for: display.key).contrastCap
        let actual = CapScaling.clamped(display.contrastUI, to: cap)
        prefs.update(display.key) { $0.lastContrastUI = display.contrastUI }
        writeVCP(.contrast, actual: actual, display: display)
    }

    private func applyVolume(_ display: ManagedDisplay) {
        guard display.kind == .external else { return }
        let actual = min(1, max(0, display.volumeUI))   // volume is not capped
        prefs.update(display.key) { $0.lastVolumeUI = display.volumeUI }
        writeVCP(.audioVolume, actual: actual, display: display)
    }

    private func writeVCP(_ code: VCPCode, actual: Double, display: ManagedDisplay) {
        guard let service = ddc.service(for: display.id) else { return }
        let maxValue = maxValues[display.id]?[code] ?? 100
        let raw = UInt16((actual * Double(maxValue)).rounded())
        coalescer.submit(key: "\(display.id).\(code.rawValue)") {
            _ = AppleSiliconDDC.write(service: service, command: code.rawValue, value: raw)
        }
    }

    /// Best-effort: learn the panel's brightness VCP maximum so we scale to its real range.
    private func learnBrightnessMax(for id: CGDirectDisplayID) {
        guard let service = ddc.service(for: id) else { return }
        coalescer.submit(key: "\(id).learnmax") { [weak self] in
            guard let reply = AppleSiliconDDC.read(service: service, command: VCPCode.brightness.rawValue),
                  reply.max > 0 else { return }
            DispatchQueue.main.async {
                self?.maxValues[id, default: [:]][.brightness] = reply.max
            }
        }
    }

    // MARK: Identity helpers

    static func stableKey(for id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(id)"
    }

    static func localizedName(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? CGDirectDisplayID, number == id {
                return screen.localizedName
            }
        }
        return nil
    }
}
