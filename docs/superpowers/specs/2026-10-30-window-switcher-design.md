# Window switcher and Dock previews — design

Date: 2026-10-30
Status: approved design, not yet implemented

## Goal

Add two features to thetoolbox, inspired by [DockWindow](https://github.com/KIKOmanasijev/DockWindow)
(used with the author's permission as a reference only — no code is copied):

1. **Window switcher (phase 1).** Cmd+Tab shows every window on the current desktop, not just
   every app, and replaces the macOS app switcher while the feature is on.
2. **Dock previews (phase 2).** Hovering an app's icon in the real macOS Dock shows thumbnails of
   that app's windows; clicking one focuses it.

The code is written from scratch in thetoolbox's style. The look is plain native macOS (HUD
material, system fonts, close to the system Cmd+Tab panel), not DockWindow's styling.

## Out of scope

- DockWindow's per-desktop replacement Dock (it rewrites the system Dock's preferences).
- Tiles for windowless apps and per-app "new window" rules.
- Theme, material, corner radius, selection color, thumbnail size and appearance-delay settings.
- In-switcher window actions (W/M/H/Q keys, traffic-light buttons on tiles).
- A same-app switcher (Cmd+` keeps its macOS behavior).
- Debug file logging.

## Settings

A new **Switcher** tab in Settings, stored through `Preferences`:

| Setting | Default |
|---|---|
| Window switcher enabled (takes over Cmd+Tab) | on |
| Switcher shortcut | Cmd+Tab |
| Show windows from | Current desktop (alternative: All desktops) |
| Include minimized windows | on |
| Include windows of hidden apps | on |
| Dock previews enabled | on |

The tab also shows permission status: the existing Accessibility row plus a new Screen Recording
row with a button that opens the matching System Settings pane.

The trigger defaults to Cmd+Tab (forward); adding Shift goes backward. It is editable with the
same `KeyboardShortcuts.Recorder` control the other tabs use. Only the recorder and stored value
are used (no KeyboardShortcuts handler is registered); `SwitcherKeyTap` reads the stored shortcut.
A shortcut must include at least one of Cmd, Option or Control, because releasing that modifier is
what picks the window; a recording without one is rejected. "Restore Defaults" puts back Cmd+Tab.
Below, "Cmd" means the trigger's modifier(s) and "Tab" means the trigger's key.

## Architecture

New code lives in `Sources/thetoolbox/WindowSwitcher/`. Each unit has one job.

### `SpacesAPI`

Thin wrapper over private SkyLight/CGS calls, resolved at runtime with `dlopen`/`dlsym` so a
missing symbol never crashes the app:

- main connection ID
- current desktop (space) ID for each display (`CGSCopyManagedDisplaySpaces`)
- desktop IDs that contain a set of window IDs (`CGSCopySpacesForWindows`)

Exposes `isAvailable`. When any required symbol is missing, callers treat every window as being
on the current desktop (i.e. fall back to "All desktops").

### `WindowInventory`

Builds a snapshot **on demand**, when the switcher opens or a Dock preview is requested; no
background tracker runs.

1. `CGWindowListCopyWindowInfo` (`.optionAll`, excluding desktop elements) gives window IDs, owner
   PIDs, bounds, layer and on-screen state in front-to-back order. That order is the
   most-recently-used order.
2. Keep normal windows only: layer 0, a regular-activation-policy owner, a reasonable minimum size,
   and not thetoolbox's own windows.
3. Scope: with "Current desktop", keep windows whose desktop set intersects the current desktops
   of all displays. Fullscreen windows are always kept (each lives on its own desktop).
4. Minimized windows (found through Accessibility `kAXMinimizedAttribute` on the app's windows)
   and windows of hidden apps are appended after the visible ones when their settings are on.
5. Titles come from Accessibility (`kAXTitleAttribute`), matched to window IDs with
   `_AXUIElementGetWindow`, so titles work without Screen Recording. If there is no title, the
   app name is used.

Output is an ordered `[WindowRecord]` (`id`, `pid`, `appName`, `appIcon`, `title`, `bounds`,
`isMinimized`, `isFullscreen`, `isHidden`). The filtering and ordering rules live in a pure
function, `WindowListPolicy`, that takes plain records and the current desktop info, so they can
be unit-tested.

Accessibility calls use a short messaging timeout (about 0.25 s per app) so a frozen app can't
stall the switcher.

### `WindowFocuser`

`focus(_ record: WindowRecord)`:

1. If the window is minimized, unminimize it through Accessibility.
2. If the app is hidden, unhide it.
3. Raise the specific window (`kAXRaiseAction`) and activate its app. For a window on another
   desktop or in another app, use the private front-process call
   (`_SLPSSetFrontProcessWithOptions` + key-window event record) so macOS switches to the right
   desktop and window.
4. If the window no longer exists, activate the app instead.

### `ThumbnailCapturer`

- Uses ScreenCaptureKit (`SCScreenshotManager.captureImage` with a single-window filter) at tile
  size (about 2x for Retina).
- In-memory LRU cache keyed by window ID (cap of about 100 images); nothing is written to disk.
- At most 4 captures run at once; captures run only while a switcher or preview panel is open.
- A cached image shows immediately; a fresh capture replaces it when it arrives.
- If Screen Recording is not granted (`CGPreflightScreenCaptureAccess` is false), it returns
  nothing and the UI shows the app icon. It never prompts for the permission on its own; the
  Settings row does that.

### `SwitcherKeys` (pure state machine)

Input: key-down / key-up / modifier-change events (key code, modifier flags, is-repeat).
Output: a command (`begin(forward|backward)`, `next`, `previous`, `move(direction)`, `commit`,
`cancel`) and whether to swallow the event.

Rules:
- Tab with Cmd held, and no session → `begin(forward)`; Shift+Tab → `begin(backward)`. Swallow.
- In a session: Tab → `next`, Shift+Tab → `previous`, arrows → `move`, Esc → `cancel`.
  All other key-downs are swallowed with no command (so Cmd+Q, Cmd+W etc. can't act on the
  frontmost app mid-switch).
- Releasing Cmd in a session → `commit`.
- Key-ups of keys swallowed on key-down are swallowed too, including after the session ends.
- Feature disabled → reset everything and pass every event through.

### `SwitcherKeyTap`

A session-level `CGEventTap` (keyDown, keyUp, flagsChanged) at the head of the queue, on a
**dedicated thread** with its own run loop, so a busy main thread can't make macOS disable the tap
mid-switch. It feeds events to `SwitcherKeys` and posts commands to the main thread. It re-enables
itself on `tapDisabledByTimeout` / `tapDisabledByUserInput`. It is separate from the existing
`KeyDownTap` (Spaces), which only sees key-downs and uses different keys.

### `SwitcherPanel`

- A non-activating `NSPanel` at a high window level, joining all desktops and floating over
  fullscreen apps. Its content is an `NSVisualEffectView` with `.hudWindow` material and rounded
  corners, hosting SwiftUI.
- Tiles: a window thumbnail (or the app icon when there is none), with a small app-icon badge.
  The selected tile gets a soft gray rounded highlight (`Color.primary` at low opacity), and its
  title is shown below the row, like the system switcher.
- Layout: a single row that wraps into a grid when it doesn't fit, sized to about 80% of the
  width of the display under the mouse, and centered on that display.
- Mouse: hovering selects a tile, but only after the pointer actually moves, so a panel opening
  under a resting pointer doesn't change the selection. Clicking commits.

### `WindowSwitcher` (manager)

An `ObservableObject`, created as a `@StateObject` in `ToolboxApp` like the other managers.

- Owns `SwitcherKeyTap`, `WindowInventory`, `WindowFocuser`, `ThumbnailCapturer`,
  `SwitcherPanel`, and in phase 2 the Dock preview pieces.
- Starts the tap only when the feature is on and Accessibility is granted; checks again when
  permission or preferences change. When it is off, the tap is stopped and macOS's own Cmd+Tab
  is untouched.

## Switch flow

1. Cmd+Tab → the tap swallows Tab and sends `begin` → the manager takes an inventory snapshot and
   selects index 1 (the previous window; index 0 when there is only one; `begin(backward)`
   selects the last).
2. A 120 ms timer starts. If the session is still active when it fires, the panel is shown and
   thumbnail captures start for the visible tiles.
3. `next`, `previous` and `move` change the selection (wrapping around). In a grid, up and down
   keep the column.
4. `commit` → cancel the timer, hide the panel, `WindowFocuser.focus(selected)`. A quick tap
   therefore switches with no panel ever shown.
5. `cancel` → hide the panel; focus is unchanged.
6. An empty inventory → the session ends immediately; nothing is shown.

## Dock previews (phase 2)

### `DockHoverReader`

- Finds the Dock process (`com.apple.dock`), takes the Accessibility element of its icon list,
  and observes `kAXSelectedChildrenChangedNotification`. The Dock marks the hovered icon as
  selected.
- For the hovered item, reads its subrole (only `AXApplicationDockItem` counts; folders, Trash,
  minimized-window tiles and separators are ignored), its URL (to resolve the bundle identifier
  and the running app) and its screen frame.
- Publishes `hovered: DockHover?` (running app PID, icon frame in screen coordinates) on the main
  thread.
- Re-attaches when the Dock restarts (the Dock's PID changes).

### `DockPreviewPanel`

- After about 300 ms of hover on one app, it shows a small HUD panel next to the icon (above for a
  bottom Dock, to the side for a left or right Dock), kept inside the screen's visible frame.
  `PreviewPlacement` is a pure function: (icon frame, Dock side, screen frame, panel size) →
  panel origin.
- Content: that app's windows from `WindowInventory` (same desktop scope as the switcher),
  showing thumbnails and titles. Apps with no windows show nothing.
- The panel stays open while the pointer is over the icon or the panel, and closes shortly after
  the pointer leaves both. Clicking a thumbnail calls `WindowFocuser.focus` and closes the panel.
- Thumbnails are captured only while the panel is open.
- Known limitation: the Dock occasionally doesn't report a hover change through Accessibility, so
  a preview may sometimes not appear. There is no reliable fix from outside the Dock.

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| Accessibility (already used by thetoolbox) | key tap, window titles, focusing, Dock hover | the switcher and previews stay off; macOS Cmd+Tab works normally |
| Screen Recording (new) | thumbnails | app icons instead of thumbnails |

Both grants are tied to the code-signing identity, so the Developer ID release build keeps them
across updates (see CLAUDE.md).

## Error handling summary

- Private desktop calls missing → all windows are listed instead of only the current desktop.
- Accessibility call times out for an app → that app's minimized windows and titles are skipped;
  CG data is used as-is.
- Thumbnail capture fails → keep the cached image, or show the app icon.
- Window gone at commit → activate its app.
- Tap disabled by the system → re-enable immediately.
- Secure input on (password fields) → the tap sees no keys, so macOS's Cmd+Tab works there.

## Testing

Unit tests in `Tests/thetoolboxTests/`:

- `SwitcherKeysTests` — begin forward/backward, next/previous, wraparound, arrows, Esc, commit on
  Cmd release, quick tap, swallowed key-ups after the session ends, other keys swallowed during a
  session, disabled = pass-through, repeats, a custom trigger (e.g. Option+Tab), and rejection
  of a modifier-free shortcut.
- `WindowListPolicyTests` — current vs all desktops, MRU order kept, minimized/hidden appended
  and toggled by settings, fullscreen always included, own windows excluded, fallback when
  desktop info is unavailable.
- `SwitcherSelectionTests` — initial index for 0/1/N windows, grid up/down movement with a short
  last row.
- `PreviewPlacementTests` — bottom/left/right Dock, clamping at screen edges.

Manual checklist (real Mac):

1. Quick Cmd+Tab tap flips to the previous window with no panel; holding shows the panel.
2. Tab, Shift+Tab, arrows, hover and click, Esc.
3. Cmd+Q while the panel is up does nothing.
4. Two displays: the panel appears on the display under the mouse; windows on both displays'
   current desktops are listed.
5. A fullscreen app is listed and switching to it works.
6. In a password field, Cmd+Tab falls back to the macOS switcher.
7. Turning the feature off restores the macOS switcher immediately.
8. With and without Screen Recording.
9. "All desktops" mode: picking a window on another desktop switches to it.
10. Dock previews with a bottom, left and right Dock, with auto-hide, and after `killall Dock`.

## Delivery

- Phase 1 (switcher, settings tab, permissions row, tests) is one commit and can ship on its own.
- Phase 2 (Dock previews) is a second commit.
- `README.md` gains a feature entry for each phase; DockWindow is credited as inspiration.
