#!/bin/bash
# Hydra Audio — GPL-3.0
# HOST: builds EVERYTHING in one command and stages it in dist/.
# The project folder is shared with the test VM over SMB; the VM then runs
# `bash Scripts/vm_install.sh` to install from dist/. Nothing is installed here.
#
# Usage:
#   ./Scripts/host_build.sh               # tests + driver + binaries → dist/
#   ./Scripts/host_build.sh --skip-tests  # same, without swift test
#
# Output (dist/):
#   HydraVirtualSoundcard.driver   the 256×256 backplane (customized BlackHole)
#   hydrad                         daemon (universal arm64 + x86_64)
#   HydraApp                       SwiftUI app (universal)
#   BUILD_INFO.txt                 version + build metadata

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
DRIVER_NAME="HydraVirtualSoundcard"

log()  { printf '\033[1;35m[hydra build]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[hydra build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — install Xcode"
command -v swift >/dev/null 2>&1 || fail "swift not found"

SKIP_TESTS=false
[[ "${1:-}" == "--skip-tests" ]] && SKIP_TESTS=true

cd "$PROJECT_DIR"

# 0. Third-party SDKs --------------------------------------------------------
"$PROJECT_DIR/Scripts/fetch_vst3sdk.sh"

# 1. Tests ------------------------------------------------------------------
if ! $SKIP_TESTS; then
    log "Running unit tests ..."
    swift test || fail "tests failed — not staging a broken build"
else
    log "Skipping tests (--skip-tests)"
fi

# 2. Backplane driver -------------------------------------------------------
log "Building backplane driver ..."
"$PROJECT_DIR/Backplane/build_and_install.sh" build

DRIVER_BUNDLE="$PROJECT_DIR/Backplane/work/BlackHole/build/$DRIVER_NAME.driver"
[[ -d "$DRIVER_BUNDLE" ]] || fail "driver bundle not found at $DRIVER_BUNDLE"

# 3. Swift binaries (universal) ---------------------------------------------
log "Building hydrad + HydraApp (release, arm64 + x86_64) ..."
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
[[ -x "$BIN_PATH/hydrad" && -x "$BIN_PATH/HydraApp" ]] || fail "binaries missing in $BIN_PATH"

# Ad-hoc sign so they run on the VM (Apple Silicon requires a signature).
codesign --force -s - "$BIN_PATH/hydrad"
codesign --force -s - "$BIN_PATH/HydraApp"

# 4. Stage dist/ -------------------------------------------------------------
log "Staging dist/ ..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$DRIVER_BUNDLE" "$DIST_DIR/"
cp "$BIN_PATH/hydrad" "$BIN_PATH/HydraApp" "$DIST_DIR/"

VERSION_LINE="$(grep 'public static let version' "$PROJECT_DIR/Sources/HydraCore/HydraConstants.swift" | sed 's/.*"\(.*\)".*/\1/')"
STAGE_LINE="$(grep 'public static let stage' "$PROJECT_DIR/Sources/HydraCore/HydraConstants.swift" | sed 's/.*"\(.*\)".*/\1/')"
cat > "$DIST_DIR/BUILD_INFO.txt" <<EOF
Hydra $VERSION_LINE $STAGE_LINE
Built: $(date '+%Y-%m-%d %H:%M:%S') on $(hostname) ($(uname -m))
Driver: $DRIVER_NAME.driver (BlackHole customized — GPL-3.0, see THIRD_PARTY_NOTICES.md)
Binaries: hydrad, HydraApp (universal, ad-hoc signed)
EOF

log "Done. dist/ contents:"
ls -la "$DIST_DIR"
log "On the VM, run:  bash Scripts/vm_install.sh"
