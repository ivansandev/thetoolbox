# Contributing to thetoolbox

Thanks for your interest! thetoolbox is a personal, non-commercial macOS menu-bar app, and
contributions are welcome.

## Requirements

- Apple Silicon Mac (M-series)
- macOS 14 (Sonoma) or later
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Building

```sh
xcodegen generate
open thetoolbox.xcodeproj      # or:
xcodebuild -scheme thetoolbox -configuration Debug build
```

- **`project.yml` is the source of truth.** Do not edit `thetoolbox.xcodeproj` — it is generated
  by XcodeGen and is git-ignored. Re-run `xcodegen generate` after changing `project.yml` or
  adding/removing source files (new files under `Sources/thetoolbox/` are picked up automatically).

## Running the permission-gated features

Window management and the brightness-key routing use the **Accessibility** API. Because the
default build is ad-hoc signed, macOS forgets the grant on every rebuild. For comfortable
development, set a stable `DEVELOPMENT_TEAM` in `project.yml` (with `CODE_SIGN_STYLE: Automatic`)
so the permission persists across builds.

## Code style

- Swift, built in **Swift 5 language mode** (see `project.yml`). Match the surrounding style:
  small focused types, doc comments on non-obvious logic, and avoid force-unwraps in new code.
- Keep code grouped by feature folder: `Displays`, `Windows`, `Power`, `Desktop`, `MenuBar`,
  `Settings`, `Shortcuts`, `Persistence`.

## Pull requests

- Make sure the project builds: `xcodegen generate && xcodebuild -scheme thetoolbox
  -configuration Debug build` (CI runs this on every PR).
- Describe what changed and how you tested it (which Mac, macOS version, and display(s)).
- Update the README if behavior or usage changes.

## A note on private APIs

thetoolbox uses private frameworks (`IOAVService`, `DisplayServices`) and installs a
`CGEventTap`. It is **not App Store eligible** by design and is intended for personal/local use.
Keep that in mind when proposing changes.
