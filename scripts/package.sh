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
#
# Signing: when this Mac has a "Developer ID Application" and a "Developer ID Installer"
# certificate and a notarytool profile (default name shoji-notary), the apps are signed with the
# hardened runtime, the .pkg and .dmg are signed, notarized by Apple and stapled — they open
# without any Gatekeeper warning. Otherwise (or with --unsigned) the build is unsigned, as before.
#   SHOJI_SIGN_APP / SHOJI_SIGN_INSTALLER / SHOJI_NOTARY_PROFILE override the defaults.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PARENT="$(dirname "$ROOT")"

REPOS=("$ROOT" "$PARENT/shoji-machines" "$PARENT/shoji-containers")
APPS=("build/Shoji.app" "build/Shoji Machines.app" "build/Shoji Containers.app")
# Nerd Fonts bundled with the installer (user request 2026-11-15): the Mono variant's four
# styles of each family (Fira Code has no italics). They ship inside Shoji.app
# (Contents/Resources/Fonts, with their SIL OFL licenses) and the installer's postinstall copies
# them into /Library/Fonts — the package never carries /Library/Fonts itself, which could reset
# that folder's permissions. Downloads are cached in build/nerd-fonts/<version> and checked
# against these pinned SHA-256s (from the release's SHA-256.txt).
NERD_VERSION="v3.5.1"
NERD_FAMILIES=(CascadiaCode JetBrainsMono FiraCode)
NERD_SHA256=(ae598e9401e2846aa3ee364513715de0490b844a4b54f0768991f45f23aa8369
             04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf
             68e3bd6164864b8b514605bc34e3a87ac401c8c48682fcce6478c70263340207)

# Entitlements for the release signature (none = no file).
ENTITLEMENTS=("$ROOT/Resources/Shoji.entitlements" "$PARENT/shoji-machines/Resources/Machines.entitlements" "")

UNSIGNED=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    *) echo "unknown option: $arg (try --unsigned)" >&2; exit 2 ;;
  esac
done
APP_ID="${SHOJI_SIGN_APP:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
INST_ID="${SHOJI_SIGN_INSTALLER:-$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)}"
NOTARY="${SHOJI_NOTARY_PROFILE:-shoji-notary}"
SIGNED=0
if [ $UNSIGNED -eq 0 ]; then
  if [ -n "$APP_ID" ] && [ -n "$INST_ID" ]; then
    SIGNED=1
    echo "==> Signing as \"$APP_ID\" / \"$INST_ID\", notarizing with profile $NOTARY"
  else
    echo "note: no Developer ID Application + Installer certificates — building UNSIGNED (Gatekeeper will warn)"
  fi
fi

# Send a file to Apple's notary service, wait, and staple the ticket to it. Stops the build if
# Apple rejects it (and prints Apple's log, which names the problem).
notarize() {
  local file="$1" out id status
  echo "==> Notarizing $(basename "$file") (usually a few minutes)"
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY" --wait --output-format plist)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$out" 2>/dev/null || true)"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$out" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization failed ($status):" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY" >&2 || echo "$out" >&2
    exit 1
  fi
  xcrun stapler staple -q "$file"
  echo "    accepted and stapled ($id)"
}

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

echo "==> Nerd Fonts $NERD_VERSION"
FONT_CACHE="build/nerd-fonts/$NERD_VERSION"
FONTS="build/nerd-fonts/staged"
rm -rf "$FONTS" && mkdir -p "$FONT_CACHE" "$FONTS"
for i in "${!NERD_FAMILIES[@]}"; do
  fam="${NERD_FAMILIES[$i]}"
  archive="$FONT_CACHE/$fam.tar.xz"
  if [ ! -f "$archive" ] || [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "${NERD_SHA256[$i]}" ]; then
    curl -fsSL --retry 3 -o "$archive.part" \
      "https://github.com/ryanoasis/nerd-fonts/releases/download/$NERD_VERSION/$fam.tar.xz"
    mv "$archive.part" "$archive"
  fi
  [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" = "${NERD_SHA256[$i]}" ] \
    || { echo "checksum mismatch for $fam.tar.xz — refusing to package it" >&2; rm -f "$archive"; exit 1; }
  tmp="$(mktemp -d)"
  tar -xJf "$archive" -C "$tmp"
  n=0
  for style in Regular Bold Italic BoldItalic; do
    for f in "$tmp"/*NerdFontMono-"$style".ttf; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in *NLNerdFont*) continue ;; esac # JetBrains Mono "NL": no ligatures
      cp "$f" "$FONTS/" && n=$((n + 1))
    done
  done
  for lic in LICENSE OFL.txt; do [ -f "$tmp/$lic" ] && cp "$tmp/$lic" "$FONTS/$fam-LICENSE.txt"; done
  rm -rf "$tmp"
  [ $n -gt 0 ] || { echo "no Mono fonts found in $fam.tar.xz" >&2; exit 1; }
  echo "    $fam: $n styles"
done

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
STAMP="$(date +%Y%m%d)"
VERSION="0.1.$(date +%Y%m%d%H%M)"          # increases with every package (for upgrades)
NAME="Shoji-$STAMP-$COMMIT"
WORK="build/package"
rm -rf "$WORK" && mkdir -p "$WORK/root/Applications" "$WORK/dmg"

echo "==> Packaging $NAME"
for i in "${!REPOS[@]}"; do
  app="$WORK/root/Applications/$(basename "${APPS[$i]}")"
  ditto --norsrc --noextattr "${REPOS[$i]}/${APPS[$i]}" "$app"
  if [ "$(basename "$app")" = "Shoji.app" ]; then
    # The fonts travel in Shoji.app; postinstall copies them into /Library/Fonts.
    mkdir -p "$app/Contents/Resources/Fonts"
    cp "$FONTS"/* "$app/Contents/Resources/Fonts/"
    chmod 644 "$app/Contents/Resources/Fonts/"*
    # Adding files breaks the build's ad-hoc signature: unsigned packages re-sign it ad hoc
    # (same designated requirement as build-app.sh); signed ones get the Developer ID below.
    [ $SIGNED -eq 1 ] || codesign --force --sign - -r='designated => identifier "dev.shoji.Shoji"' "$app"
  fi
  if [ $SIGNED -eq 1 ]; then
    # Developer ID + hardened runtime + secure timestamp: what notarization requires. (The
    # build scripts' ad-hoc signatures stay for development builds.)
    ent=()
    [ -n "${ENTITLEMENTS[$i]}" ] && ent=(--entitlements "${ENTITLEMENTS[$i]}")
    codesign --force --timestamp --options runtime ${ent[@]+"${ent[@]}"} --sign "$APP_ID" "$app"
    codesign --verify --strict --deep "$app"
  fi
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
# Modern payload compression (macOS 13+, which the installer requires anyway): with the fonts
# it halves the package (17 MB → 9 MB). pkgbuild prints "write: Permission denied" lines in a
# sandboxed shell — harmless.
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/components.plist" --identifier dev.shoji.pkg \
  --version "$VERSION" --install-location / --scripts scripts/pkg/scripts \
  --compression latest --min-os-version 13.0 "$WORK/Shoji-component.pkg"

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
sign_pkg=()
[ $SIGNED -eq 1 ] && sign_pkg=(--sign "$INST_ID" --timestamp)
productbuild --quiet --distribution "$WORK/distribution.xml" --package-path "$WORK" \
  --resources scripts/pkg/resources ${sign_pkg[@]+"${sign_pkg[@]}"} "$PKG"
[ $SIGNED -eq 1 ] && notarize "$PKG"

# The DMG: the installer, a README and the build's versions.
cp "$PKG" "$WORK/dmg/Install Shoji.pkg"
{
  echo "Built $(date '+%Y-%m-%d %H:%M') on $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m)"
  echo "Package version $VERSION"
  echo "Nerd Fonts $NERD_VERSION: ${NERD_FAMILIES[*]}"
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

GATEKEEPER_NOTE
After installing: open Shoji and allow it in System Settings → Privacy & Security →
Accessibility. ⌥/ lists every keybinding.

Also installs three Nerd Fonts into /Library/Fonts for the terminal: CaskaydiaCove (Cascadia
Code), JetBrainsMono and FiraCode Nerd Font Mono — pick one in Shoji's Settings → Terminal. They
are SIL Open Font License fonts (licenses in /Applications/Shoji.app/Contents/Resources/Fonts)
and stay installed if Shoji is removed; delete them in Font Book if you don't want them.

Needs an Apple Silicon Mac with macOS 13 or later. kitty is optional (⌥↩ opens Terminal without it).
Shoji Containers needs Docker Desktop, OrbStack or Colima. Settings and VMs live in
~/.config/shoji.
EOF
if [ $SIGNED -eq 1 ]; then
  note="The installer is signed by the developer and notarized by Apple."
else
  note='The package isn'"'"'t notarized by Apple. If macOS says it "can'"'"'t be opened" or "Apple could not
verify" it: open System Settings → Privacy & Security, scroll down, click "Open Anyway" for
"Install Shoji.pkg", and open it again. (Or Control-click the package and choose Open.)'
fi
NOTE="$note" perl -0pi -e 's/GATEKEEPER_NOTE/$ENV{NOTE}/' "$WORK/dmg/README.txt"
DMG="build/$NAME.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Shoji" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG"
if [ $SIGNED -eq 1 ]; then
  codesign --timestamp --sign "$APP_ID" "$DMG"
  notarize "$DMG"
  # What a downloaded copy will meet: Gatekeeper's verdict on the installer and the disk image.
  spctl --assess --type install -v "$PKG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
# A fixed name for the latest build, e.g. to share or keep in one place.
cp -f "$DMG" build/Shoji.dmg
echo "Packaged $PKG ($(du -h "$PKG" | cut -f1 | tr -d ' ')) and $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "Latest: build/Shoji.dmg ($([ $SIGNED -eq 1 ] && echo "signed and notarized" || echo UNSIGNED))"
