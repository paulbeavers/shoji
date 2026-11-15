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

Mouse: drag a tiled window onto another to swap them; drag its edges to resize the split.

## Good to know

- Use a single macOS Space — Shoji's workspaces replace Spaces.
- Only the main display is managed for now.
- Windows of hidden workspaces are parked just off the bottom-right corner of the screen.
- Fixed-size windows, dialogs and the apps listed in Settings → Programs → Always float, float.
- Native full-screen windows (green button) are left to macOS.
