#!/usr/bin/env bash
# Build Shoji, Shoji Machines and Shoji Containers and package them as a macOS installer:
#
#   ./scripts/package.sh     → build/Shoji-<date>-<commit>.pkg  (double-click: the macOS Installer)
#                              build/Shoji-<date>-<commit>.dmg  (the .pkg + README, for sharing)
#                              build/Shoji.dmg                  (the same DMG, under a fixed name)
#
# The companion apps are built from their sibling repos (../shoji-machines, ../shoji-containers).
# The package installs all three into /Applications; its scripts (scripts/pkg/scripts) quit
# running copies first and register the apps afterwards. Installer pages: scripts/pkg/resources.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PARENT="$(dirname "$ROOT")"

REPOS=("$ROOT" "$PARENT/shoji-machines" "$PARENT/shoji-containers")
APPS=("build/Shoji.app" "build/Shoji Machines.app" "build/Shoji Containers.app")

for repo in "${REPOS[@]}"; do
  [ -x "$repo/scripts/build-app.sh" ] || { echo "Missing $repo (clone it next to shoji)"; exit 1; }
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    echo "note: $(basename "$repo") has uncommitted changes (its build is stamped \"(modified)\")"
  fi
done

for repo in "${REPOS[@]}"; do
  echo "==> Building $(basename "$repo")"
  (cd "$repo" && ./scripts/build-app.sh)
done

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
STAMP="$(date +%Y%m%d)"
VERSION="0.1.$(date +%Y%m%d%H%M)"          # increases with every package (for upgrades)
NAME="Shoji-$STAMP-$COMMIT"
WORK="build/package"
rm -rf "$WORK" && mkdir -p "$WORK/root/Applications" "$WORK/dmg"

echo "==> Packaging $NAME"
for i in "${!REPOS[@]}"; do
  ditto "${REPOS[$i]}/${APPS[$i]}" "$WORK/root/Applications/$(basename "${APPS[$i]}")"
done

# Every app goes to /Applications — never "relocated" to wherever a copy with the same bundle id
# already lives (the Installer's default; on a dev Mac that's the repos' build/ folders), and
# always replaced, whatever the version numbers say.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
# (Set the key, or add it: `pkgbuild --analyze` leaves some keys out, depending on the macOS.)
plset() { /usr/libexec/PlistBuddy -c "Set $1 $3" "$WORK/components.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add $1 $2 $3" "$WORK/components.plist"; }
for i in $(seq 0 2); do
  plset ":$i:BundleIsRelocatable" bool false
  plset ":$i:BundleIsVersionChecked" bool false
  plset ":$i:BundleOverwriteAction" string upgrade
done
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/components.plist" --identifier dev.shoji.pkg \
  --version "$VERSION" --install-location / --scripts scripts/pkg/scripts "$WORK/Shoji-component.pkg"

cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Shoji</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="dev.shoji.pkg"/></choices-outline>
    <choice id="dev.shoji.pkg" title="Shoji" visible="false"><pkg-ref id="dev.shoji.pkg"/></choice>
    <pkg-ref id="dev.shoji.pkg" version="$VERSION" onConclusion="none">Shoji-component.pkg</pkg-ref>
</installer-gui-script>
EOF
PKG="build/$NAME.pkg"
productbuild --quiet --distribution "$WORK/distribution.xml" --package-path "$WORK" \
  --resources scripts/pkg/resources "$PKG"

# The DMG: the installer, a README and the build's versions.
cp "$PKG" "$WORK/dmg/Install Shoji.pkg"
{
  echo "Built $(date '+%Y-%m-%d %H:%M') on $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m)"
  echo "Package version $VERSION"
  for repo in "${REPOS[@]}"; do
    c="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && c="$c (modified)"
    printf '%-18s %s\n' "$(basename "$repo")" "$c"
  done
} > "$WORK/dmg/VERSIONS.txt"
cat > "$WORK/dmg/README.txt" <<'EOF'
Shoji — a Hyprland-style tiling window manager for macOS,
with Shoji Machines (Linux VMs) and Shoji Containers (Docker).

Install: double-click "Install Shoji.pkg" and follow the Installer. It puts the three apps in
/Applications (quitting running copies first; Shoji Machines shuts its VMs down cleanly).

The package isn't notarized by Apple. If macOS says it "can't be opened" or "Apple could not
verify" it: open System Settings → Privacy & Security, scroll down, click "Open Anyway" for
"Install Shoji.pkg", and open it again. (Or Control-click the package and choose Open.)

After installing: open Shoji and allow it in System Settings → Privacy & Security →
Accessibility. ⌥/ lists every keybinding.

Needs an Apple Silicon Mac with macOS 13 or later, and kitty (brew install --cask kitty).
Shoji Containers needs Docker Desktop, OrbStack or Colima. Settings and VMs live in
~/.config/shoji.
EOF
DMG="build/$NAME.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Shoji" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG"
# A fixed name for the latest build, e.g. to share or keep in one place.
cp -f "$DMG" build/Shoji.dmg
echo "Packaged $PKG ($(du -h "$PKG" | cut -f1 | tr -d ' ')) and $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "Latest: build/Shoji.dmg"
