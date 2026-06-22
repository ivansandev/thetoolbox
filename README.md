# thetoolbox

A background (menu-bar-only) macOS app bundling quality-of-life utilities.
Apple Silicon, macOS 14+.

## Features

- **Monitor control** — brightness / contrast / volume for external monitors over DDC/CI,
  plus built-in display brightness. Each display+control supports a **max cap**: the menu slider
  shows the panel's real %, the thumb stops at the cap, and the over-cap range is greyed out
  (e.g. cap Dell contrast at 75% to avoid washout).
- **Window management** — move/resize the frontmost window via global keyboard shortcuts,
  including user-defined **custom sizes** (e.g. "center 60% × 80%"), ideal for 4K screens.
  Sensible defaults (⌃⌥ + arrows / return, ⌃⌥C, custom Center 60 × 80 = ⌃⌥⌘↵) are seeded on
  first launch and are fully editable.
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
- **Window management:** ⌃⌥ + arrows / return snap halves & maximize, ⌃⌥C centers, and the
  seeded **Center 60 × 80** custom size uses ⌃⌥⌘↵ — all editable, plus add more custom sizes, in
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
