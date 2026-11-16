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
- **Signed and notarized** (set up 2026-11-15): this Mac has "Developer ID Application" and
  "Developer ID Installer" certificates for team `484E8Z6LVX` (created on developer.apple.com
  from Keychain Access CSRs — Xcode refused although the user is Account Holder; double-clicking
  the .cer failed with -25294, `security import <cer> -k ~/Library/Keychains/login.keychain-db`
  worked) and a notarytool keychain profile `shoji-notary`. `package.sh` finds them itself:
  re-signs the staged copies of the apps with `--options runtime --timestamp` (entitlements:
  `Resources/Shoji.entitlements` = apple-events for the Dark/Light switch; Machines'
  virtualization; none for Containers), `productbuild --sign`, notarizes + staples the pkg, then
  signs, notarizes + staples the DMG, and runs `spctl` on both ("Notarized Developer ID").
  Notarization takes a few minutes per file; a rejection stops the build and prints Apple's log.
  The build scripts' **ad-hoc** signatures (fixed DR on the bundle id) stay for dev builds, so
  the Accessibility grant for `build/Shoji.app` survives rebuilds. `--unsigned` forces the old
  unsigned build; `deploy-web.sh` refuses a DMG without a stapled ticket unless
  `--allow-unsigned`. Never install the package on the dev Mac from a test — inspect it with
  `pkgutil --expand-full` instead.
- **Nerd Fonts** (user request 2026-11-15): CascadiaCode (patched name **CaskaydiaCove** —
  Cascadia's OFL Reserved Font Name), JetBrainsMono, FiraCode from Nerd Fonts `v3.5.1`; only the
  `*NerdFontMono-{Regular,Bold,Italic,BoldItalic}` files (not JetBrains' "NL"; Fira has no
  italics). `package.sh` downloads the `.tar.xz` into `build/nerd-fonts/<version>` (cache),
  checks pinned SHA-256s, and puts the fonts + license files in the **staged Shoji.app**
  (`Contents/Resources/Fonts`; unsigned builds re-sign it ad hoc, signed ones get the Developer
  ID). `postinstall` copies them into `/Library/Fonts` with `install -m 644`. Never put
  `/Library/Fonts` in the payload: Installer would apply the package's permissions to that
  existing folder (root:admin 1775). Payload compression `--compression latest
  --min-os-version 13.0` (17 MB → 8.8 MB). kitty already bundles Symbols Nerd Font, so icons
  work in any font; the bundled fonts are about choice. To update: bump `NERD_VERSION` and the
  three hashes from the release's `SHA-256.txt`.
- First signed install on a Mac: the Developer ID signature is a new identity for macOS privacy
  settings, so Shoji's Accessibility permission (and System Events control) is asked for again.
- `write: Permission denied` (×4) during packaging is noise from the sandboxed shell; the
  packages are complete and Apple accepts them.

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

`terminalPadding` (0–24 pt, default 8) → kitty's `window_padding_width` in the same file. With the
title bar hidden, macOS rounds the window's corners into kitty's text (user saw it on another Mac;
this Mac's own kitty.conf had `window_padding_width 0 6`, which hid it — Shoji's file now overrides
that). Shoji can't change another app's corner radius, only keep the text clear of it. At launch
`ThemeSync.refreshKittySettings()` updates an existing kitty shoji.conf (so new keys arrive without
touching Settings); it never creates one, and it only rewrites/reloads kitty when the text changed.

Settings → **Terminal** (2026-11-15): Font (installed fixed-pitch families) and Font size →
`font_family` / `font_size` in kitty's shoji.conf; each starts on "kitty's setting (…)", which
writes nothing (label read from kitty.conf itself, `ThemeSync.kittyOwnFont`, incl. kitty's newer
`family="…"` syntax; kitty's defaults Menlo 13). Padding moved there from Windows. Reset to
defaults also rewrites kitty's file. `--preview-settings` renders the whole form.

There is **no corner-rounding setting** (removed 2026-11-15): it only ever rounded Shoji's launcher
and keybindings sheet, but users expected their windows' corners to change, which macOS doesn't
allow (yabai needs SIP off for it). `Config.rounding` is a constant; old `rounding` keys are ignored.

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

Discussed with the user 2026-11-15 and **put on hold** ("lets hold off for now" / "later") — don't
start these unprompted; when the user picks one up, start from the notes here.

### Multi-monitor support (planned, not started)
Today only the main display is managed (`WindowManager.screen` = `NSScreen.screens.first`;
windows centred elsewhere are ignored in `addWindow`; parking at the main screen's bottom-right).
Proposed design (Hyprland/AeroSpace model — user hasn't chosen yet):
- One shared pool of 10 workspaces; each display shows one. Mod+N: if N is visible on another
  display, focus that display; else show N on the focused display (the focused window's, else the
  pointer's). New windows join the workspace of the display they open on.
- Mod+arrows cross display edges (nearest window); Mod+Shift+arrows at an edge move the window to
  the next display; dragging (Mod+drag or title bar) onto another display moves it there.
- Menu-bar pills are one image on every display's menu bar: focused workspace = gradient,
  workspaces visible on other displays = outlined.
- **Parking** is the hard part: macOS keeps part of every window on some screen, so pick per window
  a display corner with no other display beyond it (bottom-right, or bottom-left with the window
  extending left); stacked layouts with no free corner → least-bad corner + log (AeroSpace has the
  same limit).
- Hot-plug: a vanished display's workspace is parked on the others; displays remembered by
  hardware UUID (`CGDisplayCreateUUIDFromDisplayID`), also in session.json.
- shoji.conf: `workspace = 6, monitor:2` / `monitor:<name>`; dispatchers `focusmonitor`,
  `movewindowtomonitor`, `moveworkspacetomonitor` (l|r|next).
- Launcher, help sheet, Settings, Stats on the focused display. Single-display behaviour must stay
  exactly as today.
- Two testable steps: (1) monitor model, per-display layout, adoption, parking, hot-plug, pills;
  (2) cross-display focus/move, drag, dispatchers, `monitor:` rule, per-display session.
- ~400–600 lines, mostly WindowManager.swift (+ Workspace, WorkspaceMenu, Launcher, Session,
  UserConfig). The dev Mac has **one display** (Dell U4025QW) — the user must test on two.
- Open questions for the user: shared pool vs fixed split (1–5 left, 6–10 right); their display
  arrangement and which Mac; one go or step 1 first.

### Native macOS Spaces — investigated, recommended against
Reading works without SIP through private SkyLight calls (`SLSCopyManagedDisplaySpaces`,
`SLSGetActiveSpace`, `SLSCopySpacesForWindows` — checked on this Mac). Controlling Spaces doesn't:
moving windows / creating / switching Spaces is only honoured from the Dock process (yabai's
scripting addition, SIP partly off). Without SIP: switch by posting "Switch to Desktop N" (off by
default here — needs enabling), with macOS's ~0.5 s animation; move windows by the Amethyst trick
(fake title-bar drag + switch — fails for kitty without a title bar); Spaces can't be created;
"Automatically rearrange Spaces" (on by default) must be turned off. Would rewrite most of the WM.
Gains (Mission Control/swipes, native fullscreen, no parking quirks) don't outweigh losing
instant, reliable workspaces — same choice as AeroSpace. Cheaper fix for the one real downside
(windows left parked off-screen if Shoji crashes): a "bring all windows back" menu command.

### Homebrew (planned, not started)
Own tap, not homebrew/cask (that needs notability — the repo had 0 stars; signing/notarization
already done). Repo `paulbeavers/homebrew-shoji`, `Casks/shoji.rb`: `pkg "Install Shoji.pkg"`,
`depends_on macos: ">= :ventura"`, `arch: :arm64`, `uninstall quit:` the three bundle ids +
`pkgutil: "dev.shoji.pkg"` + `delete:` the Nerd Fonts in /Library/Fonts (copied by postinstall, not
in the receipt), `zap trash: "~/.config/shoji"`. Needs real version numbers (every build is 0.1.0
and files are `Shoji-<date>-<commit>.dmg`) and `deploy-web.sh` updating the cask (version +
sha256) and pushing the tap. The name "shoji" is free in Homebrew. A .pkg cask asks for the
password; an `app`-stanza cask (+ font stanzas) would not, at the cost of a second package format.
Install: `brew install --cask paulbeavers/shoji/shoji`.

### Rename to Shitomi (decided 2026-11-15, on hold — the user will do it later)
**Why:** "Shoji" is crowded — at least five Mac apps use it, two of them window tilers:
shojimac.com (a paid automatic tiler, very close to this app), github.com/dvrd/shoji (an
open-source macOS tiling WM that also uses `~/.config/shoji`), getshoji.com (window zones, $4.99;
likely the pending trademark), plus a menu-bar dock/snapping app and a privacy screen. No USPTO
software registration for "Shoji" was found, but a same-name, same-category paid app is the risk.

**Name research (2026-11-15):** Shitomi (蔀, hinged lattice shutters on old Japanese buildings)
was clean everywhere: no apps, no GitHub projects; shitomi.app/.io had no DNS (likely free;
shitomi.com taken). Runners-up: Muntin (only a 0-star Windows layout repo; muntin.io free?),
Mullion (a 70★ Mac project — D3D on Metal for games — so some confusion). Rejected as taken by
similar tools: Kumiko (aimuzov/kumiko, a macOS tiling WM), Panewright (macOS tiling), Ranma
(Hyprland-like terminal WM + a macOS status bar), Sudare (commercial Mac launcher), Transom,
Noren, Amado, Koshi (small Mac/terminal utilities), Engawa (Mac writing app), Tessera (confusable
with Tesseract; domains taken). Still to do: a USPTO search (tmsearch.uspto.gov, classes 9/42).
Signing certificates are unaffected (Developer ID is per developer; no App IDs outside the store).

**Plan (shown to the user, approved name, not started):**
1. Names: Shitomi / Shitomi Machines / Shitomi Containers; bundle ids `dev.shitomi.Shitomi`,
   `.Machines`, `.Containers`; targets `Shitomi`, `ShitomiMachines`, `ShitomiContainers`; types
   (`ShojiLog` → `ShitomiLog`, …); `~/.config/shitomi/shitomi.conf`; `~/Library/Logs/Shitomi`;
   `SHOJI_*` env → `SHITOMI_*`; cross-app `dev.shoji.*` notifications → `dev.shitomi.*` (all three
   apps together); installer ids `dev.shitomi.pkg`. Keep the `shoji-notary` keychain label.
2. Migration: on first launch, if `~/.config/shitomi` is missing and `~/.config/shoji` exists, move
   it (instant on one volume, VMs included) and rename `shoji.conf`; kitty.conf's
   `include shoji.conf` → `include shitomi.conf` (rename the file; leave `.before-shoji` backups).
   The installer quits old Shoji apps (VMs shut down cleanly) and removes `/Applications/Shoji*.app`.
   Fonts stay. Users re-grant Accessibility (new bundle id); the old entry lingers.
3. GitHub: rename the repos to `shitomi`, `shitomi-machines`, `shitomi-containers` (GitHub
   redirects), update remotes, rename `~/gitwork/shoji*` folders (package.sh finds siblings by
   name); update all CLAUDE.md files, MacLucent's mention, and Claude's memory notes.
4. Website: `shitomi.pbcs.io` with a new bucket, certificate and CloudFront (deploy-cdn.sh);
   page text, asset and DMG names (`Shitomi.dmg` = latest); `shoji.pbcs.io` → a CloudFront
   Function 301-redirecting every path (old `Shoji.dmg` → newest `Shitomi.dmg`); keep the old
   bucket for now.
5. Order: rename + warning-free build → test the migration on scratch copies only (never the
   user's folders; never run the WM) → the user switches (`pkill -x Shoji; sleep 1; open
   ~/gitwork/shitomi/build/Shitomi.app`), grants Accessibility, checks settings/session/VMs →
   on "commit and push", one "Rename to Shitomi" commit per repo, then repo/folder renames →
   signed release, new site, redirect, verify.
Open questions for the user: keep old `Shoji-….dmg` downloads in the old bucket? Register
`shitomi.app` (optional — `shitomi.pbcs.io` doesn't need it)?

### Compared with AeroSpace / yabai / Amethyst (2026-11-15)
Shoji's gaps, beyond multi-monitor: a single layout (no master/stack, columns, accordion), no
CLI/socket for scripts and status bars (`shoji workspace 3`, `shoji query`), no binding modes, no
scratchpad/special workspace (removed at the user's request), no animations. Suggested order:
multi-monitor → small CLI → a second layout.

### Smaller ideas
- Scrolling layout (Lucent's Mod+T), animations, inactive dim.
- Website: a line in "Your look" about the bundled Nerd Fonts (offered, not asked for yet).
- Companion apps still need kitty for shells/consoles (Containers alerts when it's missing);
  a Terminal fallback there is a bigger change than Shoji's.
