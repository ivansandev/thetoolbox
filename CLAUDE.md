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
Bump the tag (semver `vMAJOR.MINOR.PATCH`) each release. Last: v0.6.6.

## Release signing + notarization (no Gatekeeper warning; Accessibility survives updates)
The release workflow signs the built `.app` with your **Developer ID Application** certificate,
enables the **hardened runtime**, then **notarizes** it with Apple and **staples** the ticket. A
notarized Developer ID build opens with no "developer cannot be verified" warning on any Mac.
macOS also ties the Accessibility (TCC) grant to the **code-signing identity**, so a stable
Developer ID keeps the grant alive across version updates. If the secrets below are unset, the
build falls back to ad-hoc signing (unnotarized, Gatekeeper-blocked, grant forgotten each update).

Signing secrets:
- `DEVELOPER_ID_CERT_P12_BASE64` — base64 of a `.p12` export of your **Developer ID Application** cert
- `DEVELOPER_ID_CERT_PASSWORD` — the `.p12` export password
- `DEVELOPER_ID_IDENTITY` — the cert's common name, e.g. `Developer ID Application: Your Name (TEAMID)`

Notarization secrets (App Store Connect API key):
- `AC_API_KEY_P8_BASE64` — base64 of the `.p8` key file downloaded from App Store Connect
- `AC_API_KEY_ID` — the key's Key ID
- `AC_API_ISSUER_ID` — the Issuer ID (App Store Connect → Users and Access → Integrations → Keys)

One-time setup:
1. In **developer.apple.com → Certificates**, create a **Developer ID Application** certificate
   (needs an Apple Developer Program membership). Download and double-click to install it in the
   *login* keychain.
2. Right-click it in Keychain Access → **Export…** → save `developer-id.p12` with a password.
3. In **App Store Connect → Users and Access → Integrations → App Store Connect API**, create a key
   with the **Developer** role; download the `.p8` (one-time download), and note its **Key ID** and
   the team **Issuer ID**.
4. Add the secrets:
   ```sh
   base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64
   gh secret set DEVELOPER_ID_CERT_PASSWORD   # paste the .p12 export password
   gh secret set DEVELOPER_ID_IDENTITY        # e.g. Developer ID Application: Your Name (TEAMID)
   base64 -i AuthKey_XXXX.p8 | gh secret set AC_API_KEY_P8_BASE64
   gh secret set AC_API_KEY_ID                # the Key ID
   gh secret set AC_API_ISSUER_ID             # the Issuer ID
   ```
If you're migrating from the old self-signed cert, the identity changes once, so existing installs
re-prompt for Accessibility a single time; every notarized release after that keeps the grant and
opens with no warning. Local dev builds stay ad-hoc unless you set `DEVELOPMENT_TEAM` in `project.yml`.
