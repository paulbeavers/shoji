# CLAUDE.md — Shoji

Shoji is a **true tiling window manager for macOS** (Swift/AppKit, SwiftPM + build script, no
Xcode project), styled after Hyprland: it manages other apps' real windows, shows its
workspaces as pills in the **macOS menu bar** (status item), and uses the macOS menu bar and Dock as
they are. Sibling of
`../mactile` (MacLucent, the all-in-one tiled workspace with built-in apps) and `../lucent`
(the Hyprland config whose themes and keybindings it mirrors). Shoji has **no built-in apps**.

## Build, run

```bash
./scripts/build-app.sh            # release → build/Shoji.app (debug: ./scripts/build-app.sh debug)
open build/Shoji.app
build/Shoji.app/Contents/MacOS/Shoji --preview out.png   # offscreen render of the menu bar pills and sample tiles only
```

- Rebuild `build/Shoji.app` after every change.
- Signed ad-hoc **with `-r='designated => identifier "dev.shoji.Shoji"'`** so the Accessibility
  grant survives rebuilds (TCC keys on the designated requirement). Keep it.
- Bundle id `dev.shoji.Shoji`; `LSUIElement` (no Dock icon / menu bar of its own).
- Themes: `scripts/sync-themes.sh` copies `../lucent/config/hypr/themes/*.theme` into
  `Resources/Themes` (committed copy, so the repo builds alone).
- Config in `~/.config/shoji/` (`SHOJI_CONFIG_DIR` overrides — use it in tests).

## Packaging (`scripts/package.sh`, user request 2026-11-14)

Builds all three repos (`../shoji-machines`, `../shoji-containers` must sit next to shoji) and makes
`build/Shoji-<date>-<commit>.pkg` (macOS Installer: welcome/conclusion pages in
`scripts/pkg/resources`, arm64 + macOS 13 checks in the distribution) and a `.dmg` holding the
pkg, README.txt and VERSIONS.txt, also copied to `build/Shoji.dmg` (fixed name, latest build). The user wanted a native installer, not a shell script (an
`install.sh` + `.command` was tried first — and macOS silently refuses to *execute* a script
from a quarantined DMG anyway).
- `pkgbuild --analyze` → component plist with **`BundleIsRelocatable false`** (else the Installer
  installs into wherever an app with the same bundle id already is — the repos' build/ folders
  on a dev Mac), `BundleIsVersionChecked false` (CFBundleVersion is always 1). The keys may be
  missing from the analysis — Set or Add them.
- `scripts/pkg/scripts/preinstall` (root): SIGTERM the running apps (Shoji Machines' handler
  shuts VMs down cleanly; waits up to 45 s; remembers whether Shoji was running).
  `postinstall`: `lsregister -f` each app as the console user (`launchctl asuser … sudo -u`),
  clear quarantine, reopen Shoji if it was running.
- Unsigned/not notarized (no Developer ID): Gatekeeper asks once (Open Anyway). Never install
  the package on the dev Mac from a test — inspect it with `pkgutil --expand-full` instead.

## Website: https://shoji.pbcs.io (user request 2026-11-14/15)

`web/` (index.html, style.css, assets/) is the public download page, hosted like starch's site
(`../starch`, https://starch.pbcs.io): a **private** S3 bucket `shoji-downloads-133313813536`
(us-east-1) read only by CloudFront `E18KDRAD68WK90` (Origin Access Control, Block Public Access
on, direct S3 URLs return 403), ACM certificate for shoji.pbcs.io, A/AAAA alias in the Route 53
zone `pbcs.io`.
- Publish: `./scripts/package.sh` then `./scripts/deploy-web.sh` (`--no-dmg` = page only,
  `--dry-run`). It uploads the newest `build/Shoji-<date>-<commit>.dmg` + `.sha256` (skipped when
  the checksum is unchanged), server-side copies it to `Shoji.dmg` (stable "latest" URL), fills
  `DOWNLOAD-URL` / `DOWNLOAD-SIZE` / `RELEASE-VERSION` into a staged copy of the page (the repo
  keeps the placeholders), uploads, and invalidates CloudFront. The page is `no-cache`.
- `./scripts/deploy-cdn.sh` was a one-time setup (certificate, OAC, distribution, bucket policy,
  DNS) — idempotent, only re-run if that infrastructure changes. Only it writes the bucket policy.
- The scripts use macOS tools (`perl -pi`, `shasum -a 256`, `date -j`); starch's originals use
  GNU `sed -i`/`sha256sum`. AWS credentials expire: if `aws sts get-caller-identity` fails, ask the
  user to run `! aws login`.
- **The site is for end users, not developers** (user: "This is an end user facing site").
  Plain language, no build commands, terminals, config syntax, git hashes, checksums, `brew`, or
  jargon (Hyprland, dwindle, SIP, Accessibility API). The release label is a date ("14 November
  2026"). The hero drawing is an inline SVG of ordinary apps (Safari, Notes, Music, Calendar)
  tiled with the workspace pills — screen capture isn't permitted here. Check claims against
  the code (e.g. theme count = `Resources/Themes`).
- Preview before publishing: render the staged page with a small WKWebView snapshot tool
  (`takeSnapshot`) at 1280 and 390 px wide and look at it. Remove old PNGs first — a failed run
  once left stale images that looked like the new page.
- The page doesn't mention kitty: Mod+Return falls back to the Mac's Terminal when kitty isn't
  installed (`Programs.bundleID(for: .terminal)`: Settings' pick if installed → kitty → Terminal).

## Architecture (Sources/Shoji)

| File | Role |
|---|---|
| `main.swift`, `AppDelegate.swift` | Accessory app; Accessibility permission screen; starts chrome, WM, hotkeys; signal → clean quit |
| `WM/AX.swift` | Accessibility wrappers (`_AXUIElementGetWindow` for window ids), AX ↔ AppKit coordinates, `ManagedWindow` |
| `WM/WindowManager.swift` | AXObserver per app, window lifecycle, workspaces (park off-screen), layout, focus, commands |
| `WM/LayoutTree.swift` | MacLucent's dwindle tree (+ `adopt(resizedTo:)`: user edge drags → split ratios) |
| `WM/Workspace.swift` | Virtual workspace: tree, floating list, focus history, fullscreen |
| `WM/Hotkeys.swift` | Carbon `RegisterEventHotKey` + the `Bindings` table (Lucent's ALT-mod keybinds) |
| `System/SystemChrome.swift` | Only puts back menu bar / Dock auto-hide settings that early versions changed (backup file) |
| `System/ThemeSync.swift` | Picking a theme also sets macOS Dark/Light, the starch-lattice wallpaper, kitty's `theme.conf` (+ SIGUSR1 reload) and the nearest macOS accent colour |
| `System/Programs.swift` | Terminal/browser/editor/files; "new window" = activate + ⌘N |
| `Stats/` | Mod+I Stats window, **tiled** (from MacLucent's Stats tile): `StatsWindow` + `AppsSampler`, `StatsViews` (tiles, sparklines, tables), `SystemStats` (ProcStats/HostStats). `--preview-stats <png>` renders it offscreen |
| `UI/WorkspaceMenu.swift` | Workspace pills: blank placeholder status item + `PillsPanel` overlay that draws them and takes clicks |
| `UI/Launcher.swift` | App launcher (Mod+⇧D), keybindings sheet (Mod+/) |
| `UI/SettingsWindow.swift`, `UI/ThemeGrid.swift` | Settings (from MacLucent's), theme cards |
| `Core/Config.swift`, `Core/Themes.swift` | Settings model/persistence; Lucent theme parser |

## Design decisions

- **Virtual workspaces like AeroSpace**, not macOS Spaces: hidden workspaces' windows are moved so
  their top-left sits at the main screen's bottom-right corner. `restoreAllWindows()` on quit
  (and windows found parked at launch are pulled back) — never lose windows.
- **No private SkyLight/SIP APIs.** Only `_AXUIElementGetWindow` (stable, used by every Mac WM).
- Hotkeys via Carbon (no Input Monitoring permission; keys are consumed). Default Mod = ⌥
  (⌘ would collide with every app's shortcuts).
- App focus uses AX `kAXFrontmostAttribute` + `AXRaise` (works without Shoji being active; plain
  `NSRunningApplication.activate` is limited by cooperative activation on macOS 14+).
- Our own moves are recognised by `expectedFrame`; anything else on a tiled window is settled after
  mouse-up: same size → swap with the tile under its centre, else edges → split ratios.
- Focus-on-activate (dock click / ⌘Tab to a window on another workspace switches there) is
  ignored for 0.5 s after Shoji's own workspace switch, to avoid ping-pong.
- **No Shoji bar (removed 2026-11-14, user decision):** on the notched MacBook it sat below the
  notch; the user asked for the workspaces in the macOS menu bar instead. `WorkspaceMenu` draws the
  pills into the status item's image (drawing handler, so labels follow the menu bar's light/dark
  look; active pill = theme gradient) and hit-tests clicks by x. The menu bar is no longer
  auto-hidden. Tiling area = `visibleFrame` (menu bar and Dock excluded) minus outer gaps;
  "fullscreen" = the whole visible frame (a window can't cover the menu bar).
- **The macOS Dock is used, not a Shoji dock (user decision, 2026-11-14).** The tiling area is
  `NSScreen.visibleFrame` (which leaves out the Dock on any side, or nothing when it auto-hides)
  with the top taken from Shoji's bar; a 2 s check relayouts when `visibleFrame` changes (the Dock
  shown/hidden/moved isn't always announced). Dock clicks to a window on another workspace switch
  there via focus-on-activate.
- Only the main display is managed (stage 1).
- **Windows that don't fit their tile (user request 2026-11-14).** `apply` reads the window's
  actual frame after setting it: slightly smaller (Terminal.app's character cells) → centered;
  bigger (app minimum size) → pulled back inside the area, and the tiled window is **relocated
  once** (`ManagedWindow.relocated`) by `relocate(_:minimum:)` to the first other workspace where
  half of an existing tile fits, else the first empty workspace, then Shoji switches there. Too
  big for a whole screen → floated. Logged to `~/Library/Logs/Shoji/shoji.log`.
- **Windows are found by scanning, not only by notifications:** `AX.windows(ofApp:)` (AXWindows +
  children + focused/main) on observe, on app activation and every 2 s for the frontmost app —
  NX Studio sometimes never sent kAXWindowCreated. New windows are focused (Hyprland-like).
  Unknown/empty subroles count as normal windows when closable or resizable.
- **No window borders (removed 2026-11-14, user decision).** They were click-through ring windows
  just outside each window; the user saw they didn't touch the windows and looked drawn separately.
  macOS windows' corner radius varies by style (toolbar windows are much rounder) and isn't exposed,
  and a separate window lags behind moves and sits over the window's shadow. Doing it properly needs
  private SkyLight APIs (as JankyBorders does). Don't re-add without that. The theme gradient
  (`activeBorder`) still colours the active workspace pill.

## Hard-won details (2026-11-14)

- **Menu bar pills are an overlay, not the status item.** macOS 26+ draws its own pressed
  highlight on any clicked menu bar item (the user saw the whole capsule flash; keyboard switches
  didn't flash). The status item is a blank placeholder image of the pills' width (only resized
  when the pill count changes); `PillsPanel` (non-activating, level statusBar+1) sits exactly on
  its window, follows it (move/resize/occlusion notifications + 0.5 s poll), hides with the menu
  bar, and copies its appearance. The panel must take clicks on transparent pixels
  (`ignoresMouseEvents = false` + a 1 % fill) — empty workspaces are just a number, and clicks
  there fell through to the item (flash, no switch). Workspace switches run async, after AppKit
  finishes the click (switching mid-click stuck the old button).
- **Focus follows mouse** focuses a tile only if it is the topmost window under the pointer
  (CGWindowList z-order) — else Finder's Empty Trash alert got buried — and never while a
  floating window has focus (focusing a tile raises it above System Settings etc.; macOS can't
  keep floats above tiles). Click or keyboard to leave a float.
- **Mislabelled windows:** Adobe Bridge's main window is role `AXLayoutArea`, subrole
  `AXFloatingWindow`. Any element with its own window-server id (`_AXUIElementGetWindow`) that
  isn't a sheet/drawer/popover/menu/help tag is a top-level window; mislabelled ones' subroles
  are ignored (judged by closable/resizable).
- **Unmanaged windows show on every workspace** (only managed ones are parked). Every 2 s Shoji
  compares the window server's on-screen normal windows per app with what it manages and rescans
  apps that have more (Bridge was busy, AX error -25204, when its window opened). Also rescans the
  frontmost app and apps launched in the last minute; windows of an app launched < 15 s ago are
  focused as new.
- kitty: ⌘↩ makes panes inside one OS window (kitty's own layout — no gaps/rounding); ⌘N / Mod+↩
  make OS windows that Shoji tiles. The user's startup.session opens 2 panes; that's theirs.

## Session: windows stay on their workspaces across restarts (2026-11-14)

`~/.config/shoji/session.json` (`WM/Session.swift`): per workspace the dwindle tree (split axes,
ratios, window ids at the leaves), floating windows (frame, pinned), focus, plus the current
workspace. Saved 1 s after any change (`notifyChange`) and on quit *before* `restoreAllWindows`
brings parked windows on screen. At start the scan matches windows by window-server id (stable
while the app keeps running — the Shoji-restart case): floating ones go straight to their
workspace; tiled ones wait in `restoredTiled` until `finishRestore()` rebuilds each tree
(`Node.build`, collapsing splits whose windows are gone), re-inserts windows not in the session,
parks other workspaces' windows and returns to the saved workspace. Before this, every window
landed on workspace 1 after a restart (user report).

## shoji.conf and mouse binds (user request 2026-11-14)

- **`System/UserConfig.swift`** — `~/.config/shoji/shoji.conf`, hyprland.conf-style: `$var = …`,
  `bind = MODS, KEY, dispatcher, arg` (MODS `$mod` = Settings' modifier, SHIFT CTRL ALT CMD;
  `Key.named`), `windowrule = EFFECT, app:<name|bundle id>, title:<regex>` (float, tile, center,
  size w h, workspace n [silent]), `workspace = N, floating`, `exec`, `exec-once` (once per
  boot — marker `/tmp/shoji-<uid>/exec-once-<kern.boottime>` — not on Shoji restarts). Written
  commented on first start (`defaultFile`); reloaded via a DispatchSource on the config folder
  (editors replace files) with mtime check; errors → log + `ConfigErrorBanner` (red, 10 s).
  Config binds come first in `Bindings.all()` and replace built-ins on the same key+modifiers;
  `Dispatcher` runs them. Rules apply in `addWindow` (not to windows restored from the session).
  `Shoji --check-config` prints the parse. Settings keeps the visual options.
- **`WM/MouseBinds.swift`** — CGEventTap (session, head insert; re-enabled on
  tapDisabledByTimeout). Exactly the Settings modifier + left/right mouse down on a managed window
  (CGWindowList topmost) is swallowed and starts a drag: floating = move/resize frame; tiled move =
  window follows the pointer, drop swaps with the tile under the pointer; tiled resize =
  `LayoutTree.adopt` live. Resize from the corner nearest the grab. ~60 Hz throttle.
- **No scratchpad (removed 2026-11-14, user decision).** A Hyprland-style special workspace
  (Mod+S, a hidden layer of windows that opened a kitty shell when empty, like Lucent's
  special:magic) was built and removed: to the user "scratchpad" means MacLucent's notes app, and
  a key that opens a shell made no sense to them. Don't re-add a special workspace unless asked.

## Shoji's own windows

Shoji never manages its own windows (the launcher and keybindings sheet float) — except Stats and
Settings, which the user wanted tiled (2026-11-14): `WindowManager.tileOwnWindow(_:)` finds its
AX element in Shoji's own process (an observer for `getpid()` with per-window notifications only)
and adds it to `ownTiled`; `addWindow` rejects every other window of Shoji's pid.
`releaseOwnWindow` on close. Mod+Q on an own window calls `performClose` (Shoji has no menu for
⌘W). Mod+I: open → tile in the current workspace; open elsewhere → go to it; focused → close.
Stats' **Shoji CPU/memory count the whole family**: Shoji, Shoji Machines, its VMs and Shoji
Containers (table "Shoji apps"), and those are left out of "Managed apps". VMs run in
Virtualization.framework XPC helpers (parent launchd); Shoji Machines' are picked out by their
responsible pid (`ProcStats.virtualMachineProcesses`, private
`responsibility_get_pid_responsible_for_pid` via dlsym) — Docker Desktop's VM uses the same helper
and must not be counted.

## Windows settings (Settings → Windows)

Shoji's own windows are `ShojiWindow`s: ⌘W and Esc close them (Shoji has no menu bar to carry
⌘W). With title bars hidden there's no close button, so Settings has a Done button and Mod+,
toggles it like Mod+I toggles Stats. `--preview-settings <png>` / `--preview-stats <png>` render
them offscreen.


`windowOpacity` (0.3–1) and `hideTitleBars` are window appearance Shoji applies wherever it can:
Shoji's own Settings and Stats windows (`ShojiWindow.applyWindowSettings`), kitty, through `~/.config/kitty/shoji.conf` (`background_opacity`, `hide_window_decorations
titlebar-only`; included at the end of kitty.conf), and Shoji Machines, which reads the keys from
settings.json. They were `kittyOpacity` / `kittyHideTitlebar` under Terminal until 2026-11-14 (user:
"is it weird to have machines read kitty config?"); the old keys are still read, never written.

## Companion apps: `../shoji-machines` (Mod+M) and `../shoji-containers` (Mod+O)

Both are separate repos and regular apps, found by bundle id (`dev.shoji.Machines`,
`dev.shoji.Containers`) through Launch Services — `Programs.openCompanion`. Both read Shoji's
settings.json (theme, Windows settings) and follow `dev.shoji.settingsChanged`.

### Shoji Machines (VMs) — separate repo `../shoji-machines`

The VM companion app is its own repo (user decision 2026-11-14: first bundled here, then split
out). Shoji only opens it: Mod+M / "Machines…" → `Programs.openMachines()` finds bundle id
`dev.shoji.Machines` through Launch Services (its build script runs `lsregister`). `Config.save()`
posts the distributed notification `dev.shoji.settingsChanged` so it recolours on theme changes.

## Theme sync (`ThemeSync`, user request 2026-11-14)

Mirrors Lucent's theme.sh: each of the four is a Settings toggle (default on), applied on theme
pick and by "Apply now".
- Appearance: AppleScript to System Events (`NSAppleEventsUsageDescription`; macOS asks once).
- Wallpaper: bundled `Resources/Wallpapers/starch-lattice[-light]-{3840x2160,5120x2160}.png`
  (copied from `../lucent/wallpapers`), dark/light by theme mode, size by screen aspect.
- kitty: writes `~/.config/kitty/theme.conf` (kitty.conf includes it) with Lucent's foot mapping
  (incl. the light-theme black/white swap and the theme's `terminal` key — Lucent Light uses the
  dark mocha-blue-contrast terminal on purpose). The user's original is kept once as
  `theme.conf.before-shoji`. Running kitty reloads on SIGUSR1.
- Accent: `AppleAccentColor`/`AppleHighlightColor` from mauve's hue (8 macOS presets) + the
  distributed notifications System Settings posts.
- Test kitty output with `CFFIXED_USER_HOME=<scratch> Shoji --write-kitty <themeID>` — never write
  the user's real kitty config, wallpaper, appearance or accent from a test.

## Testing — the user runs a real desktop

- **Never run the window manager in a test**: it would rearrange the user's real windows and
  change their menu bar/Dock settings. Use `--preview <png>` (offscreen render; no permission, no
  system changes) with `SHOJI_CONFIG_DIR=<scratch>`.
- The shell has no Accessibility permission, so WM behaviour is verified by the user by hand.
- Never `pkill`/`killall` Shoji by name from a test (it's the user's WM); never change Dock/menu-bar
  settings from tests. (The user restarts it themselves with `pkill -x Shoji` — that's a clean quit.)

## Working with this user

- Commit and push only when asked; split unrelated changes; Co-Authored-By line at the end.
- After building, say whether it's built and how to relaunch (`open build/Shoji.app`).
- Prefers ⌥ as modifier; Lucent themes; Hyprland look.

## Ideas / next stages

- Multi-monitor, scrolling layout
  (Lucent's Mod+T), animations, inactive dim, per-app rules file, wallpaper per theme.
- Name: "Shoji" is also used by a macOS window-zone app with a pending software trademark (found
  by the MacLucent rename check). The user published the public site anyway (2026-11-15) — worth
  checking before anything commercial.
