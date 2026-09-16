# AI usage authentication

## Findings

Claude Code reported a signed-in Claude Max subscription during investigation, while its saved
Keychain access token had expired. Login status indicates that credentials exist; it does not
guarantee that an access token copied by another app is still usable. The previous implementation
kept that token indefinitely, then allowed only one reload per hour after a 401 or 403. This could
miss subsequent CLI rotations and incorrectly instruct an otherwise signed-in user to log in again.

The previous Keychain query also allowed macOS authorization UI during automatic refreshes.
Its denial cooldown only applied to reads requested after an HTTP failure, and only worked when a
credential was already cached. An initial denied read could therefore request a password every
five minutes, after wake, or after reconnect. Every Keychain failure was described as a missing login.

## Implemented behavior

- Polling, wake, reconnect, and the normal Refresh button use noninteractive Keychain queries.
  Both the authentication context and legacy login-Keychain UI policy prohibit interaction.
  macOS's file-based Keychain shim ignores the SecItem UI flags, so reads and cache writes
  also scope `SecKeychainSetUserInteractionAllowed(false)`, serialize those operations, and
  restore the previous process policy on exit. Without this guard, an unauthorized build can
  stall awaiting a legacy ACL dialog even with the SecItem flags set.
- The credential cache respects expiry, silently checks for changes at the normal five-minute
  interval, and immediately reloads after HTTP 401. Successful rotations have no hour-long lockout.
  Failed reads, including the initial read, have a one-minute retry cooldown.
- A Toolbox-owned Keychain item holds only an imported access token, expiry, scopes, and plan.
  It is scoped to the selected Claude configuration directory and is not synchronized to iCloud.
  It can bridge a lost foreign-item access grant until expiry. Reads and writes of this cache also
  prohibit UI; a signing/ACL problem falls back to memory. Tokens without expiry stay in memory.
- If the CLI credential is missing or malformed, the imported cache is not used. This avoids
  reviving credentials after a detected logout. A token rejected with HTTP 401 is not retried from
  the imported cache during recovery.
- **Allow Claude Access…** is an explicit authorization retry. **Refresh Claude Access…** starts
  Claude Code in an isolated terminal for its local `/status` command, then re-reads the result.
  The probe disables tools, hooks, MCP servers, and Remote Control startup. It does not submit a
  model prompt, and completion is determined by the credential/request result, not CLI output.
  macOS may request authorization during this explicit action. No CLI is launched by polling.
- HTTP 403 reports denied usage access or missing `user:profile` scope rather than claiming the
  CLI login expired. Rate-limit cooldowns and stale usage snapshots remain in place.
- Existing `~/.claude/.credentials.json` files are supported. `CLAUDE_CONFIG_DIR` selects one
  literal directory; a custom profile without a credentials file never uses the global Keychain
  account. Custom profile Keychain service names are not inferred.
- ChatGPT continues to use `codex app-server` and `account/rateLimits/read`. The Toolbox does
  not read or duplicate Codex credentials, change its configured store, or own its refresh token.

## Storage and refresh options

| Option | Experience | Tradeoff |
| --- | --- | --- |
| CLI access token plus app-owned Keychain cache (implemented for Claude) | Silent polling and cached access across launches; explicit repair when needed | CLI still owns renewal. If it is idle or its ACL is replaced, an expired imported token needs the explicit access action. |
| Provider CLI manages authentication (implemented for ChatGPT) | Uses the existing login and provider-managed refresh | Requires the CLI. A provider process controls its own Keychain behavior. |
| Separate app OAuth session in its own Keychain | Could refresh independently without reading the CLI item | Requires a separate sign-in flow, provider integration, and an independently issued refresh token. Importing the CLI's refresh token is unsafe. |
| Existing CLI credentials file | No Keychain authorization prompt to read the file | Tokens are plaintext. We read an existing file but do not export Keychain secrets to one. |
| Claude CLI `/usage` scraping | No app access-token copy; CLI handles its authentication | Slower terminal startup, changing output formats, and possible provider-owned authorization UI. |
| Browser session cookies | Uses a web session instead of a CLI token | Separate expiry and browser permission/decryption requirements can introduce more prompts. |

The implemented combination preserves existing logins and removes password dialogs from Toolbox
background reads. It does not promise indefinite access from an expired imported token. A separate
OAuth session would be the next step if independent unattended Claude renewal is required.

Codex supports `cli_auth_credentials_store = "file"`, `"keyring"`, `"auto"`, or `"ephemeral"`
in its own configuration. `keyring` uses the macOS credential store; `file` avoids Keychain reads
but keeps tokens in `auth.json`. Changing that setting is unnecessary for this fix and can affect
the user's existing CLI login.

## Open source and official references

- [Chromium: scoped Keychain interaction](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc)
  documents the file-based Keychain UI suppression bug (FB16959400) and scopes the legacy
  interaction policy while restoring its prior value.
- [Apple: SecItem pitfalls](https://developer.apple.com/forums/thread/724013)
  explains the limitations of the macOS file-based Keychain shim.
- [CodexBar: Claude sources](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)
  documents OAuth, credentials-file, Keychain, web, and terminal sources, as well as credential rotation.
- [CodexBar: Keychain prompts](https://github.com/steipete/CodexBar/blob/main/docs/keychain-prompts.md)
  explains noninteractive background reads, explicit repair, ACL replacement, and stable signing.
- [CodexBar: delegated refresh](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthDelegatedRefreshCoordinator.swift)
  delegates CLI-owned token renewal and keeps opaque CLI invocations behind its interaction policy.
- [CodexBar issue #1161](https://github.com/steipete/CodexBar/issues/1161)
  reports a suspected refresh-token rotation race when an app consumes CLI credentials directly.
- [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker)
  uses app-owned Keychain credentials and explicit CLI synchronization. Its current releases moved
  credentials away from cleartext disk storage.
- [Codex authentication](https://developers.openai.com/codex/auth/)
  documents credential stores and automatic managed-session token refresh.
- [Codex app-server authentication](https://developers.openai.com/codex/app-server/#auth-endpoints)
  documents managed auth, `account/read`, and `account/rateLimits/read`.
