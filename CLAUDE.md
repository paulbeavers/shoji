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

## Shoji Machines (VMs) — separate repo `../shoji-machines`

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

- Mod+drag to move / Mod+right-drag to resize (CGEventTap), multi-monitor, scrolling layout
  (Lucent's Mod+T), animations, inactive dim, per-app rules file, wallpaper per theme.
- Name: "Shoji" is also used by a macOS window-zone app with a pending software trademark (found
  by the MacLucent rename check) — fine for personal use; check before any public release.
