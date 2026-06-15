#!/bin/bash
# Hydra Audio — GPL-3.0
# Build a distributable Hydra .pkg installer.
#
# The installer places:
#   • Hydra.app                        → /Applications
#   • HydraVirtualSoundcard.driver     → /Library/Audio/Plug-Ins/HAL
# and a postinstall script fixes ownership and restarts coreaudiod so the
# virtual soundcard appears immediately. hydrad is embedded inside Hydra.app and
# registers itself as a LaunchAgent on first launch — the pkg doesn't touch it.
#
# Usage:
#   bash Packaging/build_pkg.sh
#
# Optional env vars for a signed / notarizable release:
#   APP_SIGN_ID        "Developer ID Application: NAME (TEAMID)"  — re-sign app + driver
#   INSTALLER_SIGN_ID  "Developer ID Installer: NAME (TEAMID)"    — sign the .pkg
# Without them the pkg is UNSIGNED (fine for local installs; Gatekeeper will warn
# on other Macs — sign + notarize for public distribution, see Packaging/README.md).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$PROJECT_DIR/Packaging"
PROJ="$PROJECT_DIR/Hydra.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
PRODUCTS="$BUILD_DIR/Build/Products/Release"
STAGE="$BUILD_DIR/pkgroot"
RES="$BUILD_DIR/pkg-resources"
OUT_DIR="$PROJECT_DIR/dist"

PKG_ID="audio.hydra.installer"
APP_NAME="Hydra"
DRIVER_NAME="HydraVirtualSoundcard"
HAL="Library/Audio/Plug-Ins/HAL"

log()  { printf '\033[1;35m[pkg]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[pkg] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "xcodebuild not found — install Xcode"
[ -d "$PROJ" ] || fail "Hydra.xcodeproj not found — run: ruby Scripts/generate_xcodeproj.rb"

# 1. Build the app (also builds + embeds the driver and hydrad).
log "Building $APP_NAME (Release, universal) — this takes a minute ..."
xcodebuild build \
  -project "$PROJ" -scheme "HydraApp" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  >/dev/null || fail "xcodebuild failed (build it once in Xcode first to surface errors)"

APP="$PRODUCTS/$APP_NAME.app"
DRIVER="$PRODUCTS/$DRIVER_NAME.driver"
[ -d "$APP" ]    || fail "built app missing: $APP"
[ -d "$DRIVER" ] || fail "built driver missing: $DRIVER"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
log "Version $VERSION"

# 2. Optional Developer ID re-sign (required before notarization).
if [ -n "${APP_SIGN_ID:-}" ]; then
  log "Codesigning driver + app with: $APP_SIGN_ID"
  codesign --force --options runtime --timestamp --sign "$APP_SIGN_ID" "$DRIVER"
  codesign --force --options runtime --timestamp --deep --sign "$APP_SIGN_ID" "$APP"
fi

# 3. Stage the install layout.
log "Staging payload ..."
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/$HAL"
cp -R "$APP"    "$STAGE/Applications/"
cp -R "$DRIVER" "$STAGE/$HAL/"

# 4. Component pkg (carries the postinstall).
chmod +x "$PKG_DIR/scripts/postinstall"
COMPONENT="$BUILD_DIR/Hydra-component.pkg"
CPLIST="$BUILD_DIR/component.plist"
log "pkgbuild (non-relocatable) ..."
# Force every bundle non-relocatable. Otherwise the installer treats Hydra.app as
# "relocatable", finds the build-products copy (which lives in this iCloud/Google
# Drive folder), and tries to update it IN PLACE — which fails with "Operation not
# permitted" because installd can't write to the cloud-sync filesystem. Marking the
# bundles non-relocatable makes it always install to /Applications + the HAL folder.
pkgbuild --analyze --root "$STAGE" "$CPLIST" >/dev/null
/usr/bin/python3 - "$CPLIST" <<'PY'
import sys, plistlib
path = sys.argv[1]
with open(path, "rb") as f:
    items = plistlib.load(f)
for d in items:
    if isinstance(d, dict):
        d["BundleIsRelocatable"] = False
with open(path, "wb") as f:
    plistlib.dump(items, f)
PY
pkgbuild \
  --root "$STAGE" \
  --component-plist "$CPLIST" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --scripts "$PKG_DIR/scripts" \
  --ownership recommended \
  "$COMPONENT" >/dev/null

# 5. Product archive (installer UI + license). Assemble resources with the
#    repo's LICENSE so the GPL is shown during install.
rm -rf "$RES"; mkdir -p "$RES"
cp "$PKG_DIR"/resources/* "$RES/"
cp "$PROJECT_DIR/LICENSE" "$RES/LICENSE"

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/Hydra-$VERSION.pkg"
log "productbuild ..."
# (avoid bash 3.2 empty-array-under-`set -u`; branch instead of "${arr[@]}")
if [ -n "${INSTALLER_SIGN_ID:-}" ]; then
  productbuild \
    --distribution "$PKG_DIR/distribution.xml" \
    --resources "$RES" \
    --package-path "$BUILD_DIR" \
    --sign "$INSTALLER_SIGN_ID" \
    "$OUT" >/dev/null
else
  productbuild \
    --distribution "$PKG_DIR/distribution.xml" \
    --resources "$RES" \
    --package-path "$BUILD_DIR" \
    "$OUT" >/dev/null
fi

log "Done → $OUT"
if [ -z "${INSTALLER_SIGN_ID:-}" ]; then
  log "NOTE: this pkg is UNSIGNED — fine to install locally, but other Macs need"
  log "a signed + notarized pkg. See Packaging/README.md."
fi
