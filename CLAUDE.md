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
Bump the tag (semver `vMAJOR.MINOR.PATCH`) each release. Last: v0.6.0.

## Release signing (so Accessibility survives updates)
macOS ties the Accessibility (TCC) grant to the app's **code-signing identity**, not its version.
Ad-hoc signing (`CODE_SIGN_IDENTITY = -`) produces a new signature each build, so every update
re-prompts. The release workflow re-signs the built `.app` with a **stable self-signed identity**
when these repo secrets are present (otherwise it falls back to ad-hoc):

- `SIGNING_CERTIFICATE_P12_BASE64` — base64 of a `.p12` export of a self-signed **Code Signing** cert
- `SIGNING_CERTIFICATE_PASSWORD` — the `.p12` export password
- `SIGNING_IDENTITY` — the cert's common name (e.g. `thetoolbox Signing`)

One-time setup:
1. **Keychain Access → Certificate Assistant → Create a Certificate…** — Name `thetoolbox Signing`,
   Identity Type **Self-Signed Root**, Certificate Type **Code Signing**.
2. Right-click it in the *login* keychain → **Export…** → save `thetoolbox-signing.p12` with a password.
3. Add the secrets (or paste them into the repo's Settings → Secrets → Actions):
   ```sh
   base64 -i thetoolbox-signing.p12 | gh secret set SIGNING_CERTIFICATE_P12_BASE64
   gh secret set SIGNING_CERTIFICATE_PASSWORD   # paste the export password
   gh secret set SIGNING_IDENTITY               # type: thetoolbox Signing
   ```
The first signed release still needs Accessibility granted **once** (identity changed from ad-hoc);
every release after that keeps the grant. The cert is self-signed, so Gatekeeper still needs a
one-time right-click → Open. Local dev builds stay ad-hoc unless you set `DEVELOPMENT_TEAM` in
`project.yml`.
