# thetoolbox

[![Build](https://github.com/ivansandev/thetoolbox/actions/workflows/build.yml/badge.svg)](https://github.com/ivansandev/thetoolbox/actions/workflows/build.yml)

A background (menu-bar-only) macOS app bundling quality-of-life utilities.
Apple Silicon, macOS 14+.

<img width="339" height="508" alt="image" src="https://github.com/user-attachments/assets/edc50497-56b0-47e6-9411-2d3a8cee57ca" />


## Features

- **System monitors** — CPU, memory, and storage utilization as circular gauges at the top of the
  menu, colored by load (green / amber / red). Hover for the exact reading; click one to expand a
  detail card — CPU shows user/system split, load average, cores, and top processes; memory shows
  the App / Wired / Compressed breakdown, pressure, swap, and top processes; storage shows the boot
  volume's used / free. All read from native APIs (no dependencies); polling runs only while the
  menu is open. Toggle the row in **Settings → General**.
- **Monitor control** — brightness / contrast / volume for external monitors over DDC/CI,
  plus built-in display brightness. Each display+control supports a **max cap**: the menu slider
  shows the panel's real %, the thumb stops at the cap, and the over-cap range is greyed out
  (e.g. cap Dell contrast at 75% to avoid washout).
- **Window management** — move/resize the frontmost window via global keyboard shortcuts,
  including user-defined **custom sizes and positions** (e.g. "top-right 40% × 50%"), ideal for
  4K screens. Each shortcut is unique — reassigning a combo moves it off whatever had it.
  Sensible defaults (⌃⌥ + arrows / return, ⌃⌥C center, ⌃⌥⌘↵ center-and-fit, ⌃⌥⌘ + ←/→ to
  push the window to the next/previous display) are seeded on first launch and are fully editable.
  **Center** fits the window to the screen — almost-maximized on small/normal displays, a
  comfortable centered size on large/high-res ones. **Move to display** keeps the window's
  position and size relative to the new screen.
- **Brightness sync** — make an external monitor follow the built-in display's brightness via a
  configurable linear mapping (its level at built-in 0% and at built-in 100%).
- **Power (Caffeine)** — keep the Mac awake (prevent idle system sleep) and turn the display off
  on demand, so the screen can be dark while the system keeps running.
- **Brightness keys → display under the pointer** — the hardware brightness keys adjust
  whichever display the pointer is over (external monitors via DDC, with an on-screen overlay);
  the built-in display keeps its native behavior.
- **Desktop toggles** — show/hide desktop icons (Finder `CreateDesktop`) and desktop widgets
  (WindowManager `StandardHideWidgets`) from the menu.

## Usage

- **Monitor control:** click the menu bar icon for per-display brightness / contrast / volume
  sliders. Set per-display caps in **Settings → Displays**; each menu slider then greys out the
  range above the cap and the thumb won't go past it (e.g. cap a Dell's contrast at 75%).
- **Brightness sync:** in **Settings → Displays**, turn on "Follow built-in brightness" for an
  external monitor and set the mapping endpoints; its brightness then tracks the built-in (and
  its menu slider shows a link icon and is disabled).
- **Window management:** ⌃⌥ + arrows / return snap halves & maximize, ⌃⌥C centers, ⌃⌥⌘↵
  centers-and-fits to the screen, ⌃⌥⌘ + ←/→ moves it to the next/previous display — all editable,
  plus add custom sizes & positions, in
  **Settings → Windows**. The menu also has Left/Right/Center/Maximize buttons. The first window
  action triggers the Accessibility prompt — grant it once. DDC monitor control needs no
  permission.
- **Power:** the menu's **Power** section has a keep-awake **duration slider**
  (Off · 15m · 30m · 1h · 2h · 4h · ∞) — dragging right of Off starts keep-awake and shows a live
  "Auto-off in …" countdown; drag back to Off to stop. Plus a "Turn Off Display" button.
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
- **Brightness-key routing** (to the display under the pointer) uses a session event tap, which
  also requires Accessibility.
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
  `Windows`, `Settings`, `Shortcuts`, `Persistence`).
- Dependencies: [`AppleSiliconDDC`](https://github.com/waydabber/AppleSiliconDDC) (DDC over I2C),
  [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (global shortcuts).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — in short: edit `project.yml` (not the generated
`.xcodeproj`), run `xcodegen generate`, and build.

## License

[MIT](LICENSE) © 2026 Ivan Sandev. Third-party components and their licenses are listed in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) — the vendored AppleSiliconDDC is MIT © Istvan T.,
and KeyboardShortcuts is MIT © Sindre Sorhus.
