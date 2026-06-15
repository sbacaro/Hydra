#!/bin/bash
# Hydra Audio — GPL-3.0
# Fetch the prebuilt Sparkle XCFramework + CLI tools into ThirdParty/Sparkle.
#
# Sparkle powers in-app auto-updates (Sources/HydraApp/Updater.swift). Its bin/
# tools (generate_keys, sign_update, generate_appcast) sign and publish updates —
# see .github/workflows/release.yml and Packaging/RELEASING.md.
#
# Called automatically by Scripts/generate_xcodeproj.rb so the framework is on disk
# before the project is built (an embedded XCFramework must exist at "planning"
# time, before any build phase runs). Safe to run by hand too; idempotent.
set -euo pipefail

# Pinned for reproducibility + integrity. Bump both together (sha256 of the .tar.xz).
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.2}"
SPARKLE_SHA256="1cb340cbbef04c6c0d162078610c25e2221031d794a3449d89f2f56f4df77c95"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$PROJECT_DIR/ThirdParty/Sparkle"
MARKER="$DEST/.sparkle-version"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

log()  { printf '\033[1;35m[sparkle]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[sparkle] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Idempotent: skip when the pinned version is already fully present. (Existence of
# a key tool — not just the dir — guards against a partial / cloud-evicted copy.)
if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$SPARKLE_VERSION" ] \
   && [ -d "$DEST/Sparkle.framework" ] && [ -x "$DEST/bin/sign_update" ]; then
  log "Sparkle $SPARKLE_VERSION already present — skipping."
  exit 0
fi

command -v curl >/dev/null || fail "curl not found"
command -v tar  >/dev/null || fail "tar not found"

log "Fetching Sparkle $SPARKLE_VERSION ..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/sparkle.tar.xz"

curl -fSL "$URL" -o "$TARBALL" || fail "download failed: $URL"

# Verify the pinned checksum before trusting the archive.
if command -v shasum >/dev/null 2>&1; then
  echo "$SPARKLE_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1 \
    || fail "sha256 mismatch — refusing to use a tampered or corrupt Sparkle archive."
else
  log "WARNING: shasum unavailable — skipping integrity check."
fi

mkdir -p "$TMP/x"
tar -xJf "$TARBALL" -C "$TMP/x" || fail "extract failed (need xz-capable tar)"

# The binary .tar.xz ships a universal Sparkle.framework (arm64+x86_64) and the
# bin/ tools. (The XCFramework only ships in the separate SPM zip; the plain
# framework embeds just as well for a universal app.)
FW="$(find "$TMP/x" -maxdepth 3 -type d -name 'Sparkle.framework' | head -1)"
BIN="$(find "$TMP/x" -maxdepth 3 -type d -name 'bin' | head -1)"
[ -n "$FW" ] || fail "Sparkle.framework not found in archive"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$FW" "$DEST/Sparkle.framework"
[ -n "$BIN" ] && cp -R "$BIN" "$DEST/bin"
echo "$SPARKLE_VERSION" > "$MARKER"
log "Sparkle $SPARKLE_VERSION ready → ThirdParty/Sparkle"
