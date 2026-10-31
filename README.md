# thetoolbox

[![Build](https://github.com/ivansandev/thetoolbox/actions/workflows/build.yml/badge.svg)](https://github.com/ivansandev/thetoolbox/actions/workflows/build.yml)

A background (menu-bar-only) macOS app bundling quality-of-life utilities.
Apple Silicon, macOS 14+.

<img width="362" height="662" alt="Screenshot 2026-07-17 at 13 52 11" src="https://github.com/user-attachments/assets/0a324c3e-9cee-4910-bc3d-c3e525dea61b" />


## Features

- **System status metrics** — optionally show CPU utilization, RAM pressure, SSD usage,
  or any combination directly in the menu bar. Enable each reading with its own checkbox in
  **Settings → General**; all are off by default, leaving the regular app icon in place. Enabling any system metric also
  shows circular CPU, memory, and storage gauges at the top of the menu, colored by load
  (green / amber / red). Click one to expand a detail card — CPU shows user/system split, load
  average, cores, and top processes; memory shows the App / Wired / Compressed breakdown, pressure,
  swap, and top processes; storage shows the boot volume's used / free. Lightweight enabled metrics
  refresh every two seconds; more expensive process and fan details are read only while the menu is
  open. All readings use native APIs with no additional dependencies.
- **Monitor control** — brightness / contrast / volume for external monitors over DDC/CI,
  plus built-in display brightness. Each display+control supports a **max cap**: the menu slider
  shows the panel's real %, the thumb stops at the cap, and the over-cap range is greyed out
  (e.g. cap Dell contrast at 75% to avoid washout). It also reads which **color profiles** a
  monitor supports (preset modes such as Standard / Movie / Game, and color presets such as
  6500 K) and lets you switch between them.
- **Window management** — move/resize the frontmost window via global keyboard shortcuts,
  including user-defined **custom sizes and positions** (e.g. "top-right 40% × 50%"), ideal for
  4K screens. Each shortcut is unique — reassigning a combo moves it off whatever had it.
  Sensible defaults (⌃⌥ + arrows / return, ⌃⌥C center, ⌃⌥⌘↵ center-and-fit, ⌃⌥⌘ + ←/→ to
  push the window to the next/previous display) are seeded on first launch and are fully editable.
  Repeating the left or right shortcut cycles that edge through ½, ⅓, and ⅔ widths.
  **Center** fits the window to the screen — almost-maximized on small/normal displays, a
  comfortable centered size on large/high-res ones. **Move to display** keeps the window's
  position and size relative to the new screen. An optional **Leave room for recent apps**
  setting keeps managed windows clear of Stage Manager's left-side app strip.
- **Instant space switching** — switch between macOS spaces (desktops) with no slide
  animation, adapted from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher).
  ⌃← / ⌃→ move to the previous/next space and ⌃1…⌃0 jump straight to spaces 1–10 (spaces 11–16
  can have shortcuts too). An optional **Instant trackpad swipes** setting makes your own
  three/four-finger swipes skip the animation as well. Works with SIP on and uses native spaces.
  **Instant Mission Control and App Exposé** (optional) opens both without the zoom animation
  from their macOS keyboard shortcuts.
- **Window switcher** — ⌘Tab shows every window on the current desktop, not just every app,
  with live thumbnails in a native macOS-style panel. Hold ⌘ and press Tab (⇧Tab or the arrow
  keys to move back and around, or point and click), then release ⌘ to switch; a quick ⌘Tab flips
  to the previous window without showing the panel. It replaces the macOS app switcher while it's
  on. Inspired by [DockWindow](https://github.com/KIKOmanasijev/DockWindow).
- **Brightness sync** — make an external monitor follow the built-in display's brightness via a
  configurable linear mapping (its level at built-in 0% and at built-in 100%).
- **Power (Caffeine)** — keep the Mac awake (prevent idle display sleep), so the screen stays lit
  and the system keeps running. A separate administrator-authorized **Prevent all sleep** toggle
  applies macOS's system-wide `pmset disablesleep` setting, including lid-close sleep, with a
  safety warning before it is enabled.
- **Brightness keys → display under the pointer** — the hardware brightness keys adjust
  whichever display the pointer is over (external monitors via DDC, with an on-screen overlay);
  the built-in display keeps its native behavior.
- **Desktop toggles** — show/hide desktop icons (Finder `CreateDesktop`) and desktop widgets
  (WindowManager `StandardHideWidgets`) from the menu.

## Usage

- **Status-bar metrics:** open **Settings → General → Status bar metrics** and check CPU utilization,
  RAM pressure, SSD usage, or any combination.
  Selected readings share the app's single clickable menu-bar item; uncheck all metrics to restore the
  wrench-and-screwdriver icon.
- **Monitor control:** click the menu bar icon for per-display brightness / contrast / volume
  sliders. Set per-display caps in **Settings → Displays**; each menu slider then greys out the
  range above the cap and the thumb won't go past it (e.g. cap a Dell's contrast at 75%).
- **Color profiles:** in **Settings → Displays**, expand "Color profile" under an external monitor
  to pick its preset mode or color preset. Only the modes the monitor itself advertises are listed.
- **Brightness sync:** in **Settings → Displays**, turn on "Follow built-in brightness" for an
  external monitor and set the mapping endpoints; its brightness then tracks the built-in (and
  its menu slider shows a link icon and is disabled).
- **Window management:** ⌃⌥ + left/right cycles the matching edge through ½ → ⅓ → ⅔,
  ⌃⌥ + up/down/return snaps top/bottom/maximize, ⌃⌥C centers, ⌃⌥⌘↵ centers-and-fits to the
  screen, and ⌃⌥⌘ + ←/→ moves it to the next/previous display — all editable, plus add custom
  sizes & positions, in
  **Settings → Windows**. The menu also has Left/Right/Center/Maximize buttons. The first window
  action triggers the Accessibility prompt — grant it once. DDC monitor control needs no
  permission. If you use Stage Manager, enable **Leave room for recent apps** there to keep its
  left-side app strip unobstructed.
- **Spaces:** press ⌃← / ⌃→ to move one space left/right, or ⌃ + a number to jump to that
  space. These take priority over macOS's own (animated) Mission Control shortcuts on the same
  keys, so there's nothing to turn off. All shortcuts are editable in **Settings → Spaces** (if the
  recorder warns a combo is used by the system, choose **Use Anyway**; **Restore Defaults** puts
  them back), along with
  **Instant trackpad swipes** and **Instant Mission Control and App Exposé** (which uses the
  shortcuts set in System Settings → Keyboard → Keyboard Shortcuts → Mission Control). Needs
  Accessibility, like window management.
- **Window switcher:** hold ⌘ and press Tab to step through this desktop's windows (Esc cancels);
  release ⌘ to switch. **Settings → Switcher** has the on/off switch, the shortcut (**Restore
  Default** puts back ⌘Tab), and whether to include other desktops, minimized windows and hidden
  apps. Needs Accessibility; thumbnails also need Screen Recording (app icons otherwise).
- **Power:** the menu's **Power** section has a keep-awake **duration slider**
  (Off · 15m · 30m · 1h · 2h · 4h · ∞) — dragging right of Off starts keep-awake and shows a live
  "Auto-off in …" countdown; drag back to Off to stop. **Prevent all sleep** is the stronger,
  persistent system setting: enabling it warns that even closing a MacBook lid will not sleep the
  Mac, then asks for administrator approval. Turn it off to restore normal sleep.
- **Brightness keys:** with Accessibility granted, press the hardware brightness keys while the
  pointer is over an external monitor to change *that* monitor (toggle in **Settings → General**).
- **Desktop:** the menu's **Desktop** section toggles desktop icons and widgets (each briefly
  relaunches Finder / WindowManager to apply).

## Requirements

- **Apple Silicon** Mac (M-series) — the DDC path uses Apple-Silicon-only APIs.
- **macOS 14 (Sonoma)** or later.
- **Xcode 16+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build.

There is no notarized download — **build from source**. A copied build is unsigned, so Gatekeeper
may refuse to open it; run it from Xcode, or right-click the `.app` → Open.

## Install a release

Download `thetoolbox.zip` from [Releases](https://github.com/ivansandev/thetoolbox/releases),
unzip, and drag **thetoolbox.app** to `/Applications`. It's ad-hoc signed (not notarized), so on
first launch **right-click → Open** (or run `xattr -dr com.apple.quarantine thetoolbox.app`).

Maintainers cut a release by pushing a tag: `git tag v0.1.0 && git push origin v0.1.0` — CI builds
the app and attaches the zip.

## Build & run

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open thetoolbox.xcodeproj      # then Run, or:
xcodebuild -scheme thetoolbox -configuration Debug build
```

`project.yml` is the source of truth; re-run `xcodegen generate` after editing it.
`thetoolbox.xcodeproj` is generated and need not be committed.

## Permissions & signing

- The app is **not sandboxed** — DDC (`IOAVService`) and the Accessibility API both require it.
- **DDC monitor control** needs no special permission on Apple Silicon.
- **Window management** needs **Accessibility** permission
  (System Settings → Privacy & Security → Accessibility). The app prompts on first use.
- **Space switching** posts a synthetic trackpad swipe and uses session event taps — on key
  presses (so its shortcuts beat macOS's own) and on trackpad gestures (for instant swipes) —
  all of which require Accessibility.
- **Brightness-key routing** (to the display under the pointer) uses a session event tap, which
  also requires Accessibility.
- **Window switcher** uses a session event tap for its shortcut and Accessibility to read and
  focus windows. Thumbnails use ScreenCaptureKit, which needs **Screen Recording** permission
  (System Settings → Privacy & Security → Screen & System Audio Recording); without it the
  switcher shows app icons. Images stay in memory and are never saved.
- **Prevent all sleep:** macOS shows its administrator authorization dialog when changing the
  system-wide setting. thetoolbox never receives or stores the password.
- **Private APIs:** thetoolbox calls private frameworks (`IOAVService`, `DisplayServices`) and
  installs a `CGEventTap`. It is **not App Store eligible** and is intended for personal/local use.
- **Signing caveat:** the Accessibility grant is tied to the app's code signature. The default
  build uses ad-hoc signing (`CODE_SIGN_IDENTITY = -`), whose signature changes every build, so
  macOS forgets the grant on each rebuild. For day-to-day use of the window feature, set a stable
  **Development** team in `project.yml` (`DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE: Automatic`) so the
  permission persists.

## Layout

- `project.yml` — XcodeGen spec (targets, SPM deps, Info.plist, entitlements).
- `Sources/thetoolbox/` — app source, grouped by feature (`App`, `MenuBar`, `Displays`,
  `Windows`, `WindowSwitcher`, `Spaces`, `Settings`, `Shortcuts`, `Persistence`).
- Dependencies: [`AppleSiliconDDC`](https://github.com/waydabber/AppleSiliconDDC) (DDC over I2C),
  [`InstantSpaceSwitcher`](https://github.com/jurplel/InstantSpaceSwitcher) (instant space switching core),
  [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (global shortcuts).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — in short: edit `project.yml` (not the generated
`.xcodeproj`), run `xcodegen generate`, and build.

## License

[MIT](LICENSE) © 2026 Ivan Sandev. Third-party components and their licenses are listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) — the vendored AppleSiliconDDC is MIT © Istvan T.,
the vendored InstantSpaceSwitcher core is MIT © jurplel, and KeyboardShortcuts is MIT © Sindre Sorhus.
