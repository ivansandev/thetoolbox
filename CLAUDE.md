# thetoolbox

Menu-bar macOS app. `project.yml` is the source of truth — edit it, not the generated
`thetoolbox.xcodeproj` (git-ignored). New files under `Sources/` are auto-included on
`xcodegen generate`.

## Build
```sh
xcodegen generate
xcodebuild -scheme thetoolbox -configuration Debug -derivedDataPath build build
```

## Ship a new version
Commit changes to `main`, then push a version tag — CI builds the Release app and publishes
`thetoolbox.zip` to GitHub Releases (`.github/workflows/release.yml`):
```sh
git tag v0.2.0 && git push origin v0.2.0
```
Bump the tag (semver `vMAJOR.MINOR.PATCH`) each release. Last: v0.2.0.
