#!/bin/bash
# Hydra Audio — GPL-3.0
# LOCAL install (no VM): build + install the part that can't just be "Run" from
# Xcode — the backplane driver (a HAL plugin that must live in
# /Library/Audio/Plug-Ins/HAL).
#
# hydrad and HydraApp do NOT need this: run them straight from Xcode (⌘R), or
# from dist/ after host_build.sh. Run hydrad as the built .app at least once so
# macOS shows the Local Network permission dialog — click Allow.
#
# Usage:
#   ./Scripts/install_local.sh            # build driver and install
#   ./Scripts/install_local.sh uninstall  # remove the driver
#   ./Scripts/install_local.sh status     # what's installed / visible

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$PROJECT_DIR/Hydra.xcodeproj"
BUILD_DIR="$PROJECT_DIR/.xcodebuild"
PRODUCTS="$BUILD_DIR/Build/Products/Release"
DRIVER_NAME="HydraVirtualSoundcard"
DEVICE_NAME="Hydra Virtual Soundcard"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
MODDIR="$HOME/Library/Application Support/Hydra/modules"
CONFDIR="$HOME/Library/Application Support/Hydra"

log()  { printf '\033[1;35m[hydra local]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[hydra local] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Hydra Dev"'; then
    SIGN_ID="Hydra Dev"
else
    SIGN_ID="-"
fi

restart_coreaudiod() {
    log "Restarting coreaudiod ..."
    # `launchctl kickstart` on coreaudiod is SIP-blocked on recent macOS.
    sudo killall coreaudiod 2>/dev/null || true
    sleep 3
}

device_visible() { system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE_NAME"; }

do_install() {
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — install Xcode"
    [[ -d "$PROJ" ]] || fail "Hydra.xcodeproj not found — run: ruby Scripts/generate_xcodeproj.rb"

    log "Building driver (universal, release) ..."
    xcodebuild build -project "$PROJ" -scheme "HydraVirtualSoundcard.driver" -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_ID" \
        || fail "xcodebuild failed for the driver"

    [[ -d "$PRODUCTS/$DRIVER_NAME.driver" ]] || fail "driver missing in $PRODUCTS"

    log "Installing driver to $HAL_DIR (sudo) ..."
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME.driver"
    sudo cp -R "$PRODUCTS/$DRIVER_NAME.driver" "$HAL_DIR/"
    sudo chown -R root:wheel "$HAL_DIR/$DRIVER_NAME.driver"
    sudo xattr -dr com.apple.quarantine "$HAL_DIR/$DRIVER_NAME.driver" 2>/dev/null || true

    restart_coreaudiod

    if device_visible; then
        log "OK: \"$DEVICE_NAME\" is live (Audio MIDI Setup: 256 in / 256 out)."
    else
        log "Driver installed but device not visible yet — open Audio MIDI Setup;"
        log "if absent, check Console.app for coreaudiod messages."
    fi
    log "Now run hydrad + HydraApp from Xcode (⌘R). On hydrad's first run, click"
    log "ALLOW on the Local Network dialog (or enable it in System Settings →"
    log "Privacy & Security → Local Network)."
}

do_uninstall() {
    log "Removing driver from $HAL_DIR (sudo) ..."
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME.driver"
    restart_coreaudiod
    log "Removed."
}

do_status() {
    [[ -d "$HAL_DIR/$DRIVER_NAME.driver" ]] && log "Driver: installed" || log "Driver: NOT installed"
    device_visible && log "Device: \"$DEVICE_NAME\" visible" || log "Device: not visible"
}

case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         fail "unknown action: $1 (use: install | uninstall | status)" ;;
esac
