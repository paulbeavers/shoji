# Shoji

A Hyprland-style tiling window manager for macOS. Shoji arranges your real app windows —
dwindle tiling, gaps, virtual workspaces — with its workspaces shown in the macOS menu bar.
The macOS menu bar and Dock stay as they are; tiled windows keep clear of both. Themes and settings are shared with the Lucent
Hyprland config (and MacLucent).

## Build and run

```bash
./scripts/build-app.sh      # → build/Shoji.app
open build/Shoji.app
```

On first launch Shoji asks for **Accessibility** permission (System Settings → Privacy & Security →
Accessibility). It starts by itself once allowed. Its workspace pills appear in the menu bar:
click one to switch, right-click for the menu. Quitting Shoji (Mod+Shift+M, the menu, or
`pkill -x Shoji`) brings every window from hidden workspaces back on screen.

Requirements: macOS 13 or later, a Swift toolchain (Xcode Command Line Tools). No SIP changes.

## Installing on another Mac

```bash
./scripts/package.sh      # builds Shoji + ../shoji-machines + ../shoji-containers
                          # → build/Shoji-<date>-<commit>.pkg, a .dmg with it + a README,
                          #   and build/Shoji.dmg (the latest, under a fixed name)
```

Copy the `.pkg` (or the `.dmg`) to the other Mac and double-click it: the macOS Installer puts
**Shoji**, **Shoji Machines** and **Shoji Containers** in /Applications. Then open Shoji and allow
it under Accessibility. The other Mac needs Apple Silicon and macOS 13+ (kitty is optional — ⌥↩
falls back to Terminal; Containers needs Docker) — no developer tools.

On a Mac with **Developer ID Application** and **Developer ID Installer** certificates and a
`notarytool` profile named `shoji-notary`, `package.sh` signs the apps (hardened runtime), signs
the `.pkg` and `.dmg`, has Apple notarize both and staples the tickets — they open without any
Gatekeeper warning. Without them (or with `--unsigned`) the build is unsigned and macOS asks once
(System Settings → Privacy & Security → **Open Anyway**).

### The website

`web/` is the download page, published to https://shoji.pbcs.io (S3 behind CloudFront, like
starch's site):

```bash
./scripts/package.sh       # the DMG to publish
./scripts/deploy-web.sh    # upload the DMG (if it changed) and the page, invalidate CloudFront
./scripts/deploy-cdn.sh    # once: certificate, CloudFront, bucket lockdown, DNS
```

The page keeps `DOWNLOAD-URL`, `DOWNLOAD-SIZE` and `RELEASE-VERSION` placeholders; the deploy
fills them into a copy. `Shoji.dmg` on the site is always the latest.

## Machines (Linux VMs)

**Mod+M** opens **Shoji Machines**, the companion app from the sibling repo `shoji-machines`
(build it there first): create Linux server
VMs (Debian, Ubuntu, Fedora, Rocky, Alma, Alpine cloud images on Apple's Virtualization
framework), start and stop them, open a VM's console or an SSH session in a kitty window, delete
them. VMs run in Shoji Machines, so they keep running when Shoji restarts; quitting Shoji Machines
shuts them down cleanly. VMs live in `~/.config/shoji/vms`.

## Containers (Docker)

**Mod+O** opens **Shoji Containers**, the companion app from the sibling repo `shoji-containers`:
Docker containers (grouped by Compose project, live CPU/memory) and images — start, stop,
restart, remove, pull, prune; shell, logs and `docker run` in kitty windows.

## Keybindings

Mod is **⌥** by default (Settings: ⌥, ⌃⌥ or ⌘) — the Lucent config's ALT-mod bindings.

| Keys | Action |
|---|---|
| Mod+↩ / Mod+⇧↩ | Terminal / floating terminal |
| Mod+⇧D | App launcher |
| Mod+E / B / N | File manager / browser / editor |
| Mod+Q | Close window |
| Mod+J | Flip split axis |
| Mod+F / Mod+⇧F | Fullscreen / maximise within gaps |
| Mod+⌃V / Mod+⌃C | Toggle floating / centre |
| Mod+⇧P | Pin across workspaces |
| Mod+←→↑↓ (H L K) | Focus |
| Mod+⇧←→↑↓ (H J K L) | Move (swap) window |
| Mod+⌃←→↑↓ | Resize |
| Mod+1…0 / Mod+⇧1…0 | Workspace / move window there |
| Mod+⌃1…5 | Move window, stay here |
| Mod+Tab, Mod+] / Mod+⇧Tab, Mod+[ | Next / previous workspace |
| Mod+⌃Tab / Mod+` | Cycle windows / last window |
| Mod+, / Mod+/ | Settings / keybindings sheet |
| Mod+M | Machines (Linux VMs) |
| Mod+O | Containers (Docker) |
| Mod+I | Stats (Shoji, managed apps, system) |
| Mod+⇧M | Exit Shoji |

Mouse: **Mod + drag** moves any window (drop a tile on another to swap them), **Mod + right-drag**
resizes it from the nearest corner (tiles move their split borders). Dragging a tile's title bar
or edges works too.

## Config file

`~/.config/shoji/shoji.conf` (Settings → Config file, or "Edit shoji.conf…" in the menu bar
menu) is hyprland.conf-style and reloads on save:

```
bind = $mod, T, exec, open -na kitty --args htop
bind = $mod SHIFT, B, exec, open -na "Google Chrome"
windowrule = float, app:Calculator
windowrule = workspace 3 silent, app:Mail
windowrule = size 1100 700, app:kitty, title:^htop
workspace = 9, floating
exec-once = open -ga Docker
```

The first start writes a commented file listing every key, dispatcher and rule. Errors show in
a red banner (the rest still applies); `Shoji --check-config` prints what it understood.

## Good to know

- Use a single macOS Space — Shoji's workspaces replace Spaces.
- Only the main display is managed for now.
- Windows of hidden workspaces are parked just off the bottom-right corner of the screen.
- Fixed-size windows, dialogs and the apps listed in Settings → Programs → Always float, float.
- Native full-screen windows (green button) are left to macOS.
