#!/bin/bash
# Hydra Audio — GPL-3.0
# Builds the Hydra backplane: a customized BlackHole (256 in × 256 out),
# named "Hydra Virtual Soundcard", and installs it as a userspace HAL plugin.
# SIP stays ON — no system security is reduced. Ad-hoc signing is enough for
# local use; Developer ID + notarization only matter for distributing to others.
#
# Usage:
#   ./build_and_install.sh            # build + install (asks for sudo at install)
#   ./build_and_install.sh build      # build only
#   ./build_and_install.sh install    # install a previously built driver
#   ./build_and_install.sh uninstall  # remove the driver
#
# BlackHole by Existential Audio Inc. (GPL-3.0) — credited in THIRD_PARTY_NOTICES.md.

set -euo pipefail

# ----- Single source of truth (mirror of Sources/HydraCore/HydraConstants.swift) -----
DEVICE_NAME="Hydra Virtual Soundcard"   # name shown in Audio MIDI Setup
DRIVER_NAME="HydraVirtualSoundcard"     # internal name (no spaces; used in UIDs)
BUNDLE_ID="audio.hydra.virtualsoundcard"
CHANNELS=256
BLACKHOLE_REPO="https://github.com/ExistentialAudio/BlackHole.git"
BLACKHOLE_TAG="${BLACKHOLE_TAG:-v0.6.1}"   # pinned; override: BLACKHOLE_TAG=vX.Y.Z ./build_and_install.sh
# --------------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
SRC_DIR="$WORK_DIR/BlackHole"
BUILD_DIR="$SRC_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/$DRIVER_NAME.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

ACTION="${1:-all}"

log()  { printf '\033[1;35m[hydra]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[hydra] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_xcode() {
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
    # sed reads the whole input (unlike head), avoiding a SIGPIPE that would
    # kill the script under `set -o pipefail`.
    xcodebuild -version | sed -n '1p'
}

fetch_source() {
    mkdir -p "$WORK_DIR"
    if [[ -d "$SRC_DIR/.git" ]]; then
        log "BlackHole source already present ($SRC_DIR)"
    else
        log "Cloning BlackHole @ $BLACKHOLE_TAG ..."
        git clone --depth 1 --branch "$BLACKHOLE_TAG" "$BLACKHOLE_REPO" "$SRC_DIR" \
            || fail "clone failed — check the tag ($BLACKHOLE_TAG) and your network"
    fi
}

customize_source() {
    # In BlackHole v0.6.x the customization defines live in BlackHole/BlackHole.c
    # (all #ifndef-guarded), so defining them first is the supported mechanism.
    local source_file="$SRC_DIR/BlackHole/BlackHole.c"
    [[ -f "$source_file" ]] || fail "BlackHole.c not found at $source_file (did the repo layout change?)"

    # V5: no volume/mute controls + Hydra device icon. If an older override
    # block is present, re-clone so the new patches apply cleanly.
    if grep -q "HYDRA_OVERRIDES_V5" "$source_file"; then
        log "Overrides (V5) already applied to BlackHole.c"
        return
    fi
    if grep -q "HYDRA_OVERRIDES" "$source_file"; then
        log "Older overrides found — refreshing BlackHole source ..."
        rm -rf "$SRC_DIR"
        fetch_source
    fi

    log "Applying Hydra overrides V5 to BlackHole.c (channels=$CHANNELS, name=\"$DEVICE_NAME\", no volume/mute controls, Hydra icon)"
    local overrides
    overrides=$(cat <<EOF
// ===== HYDRA_OVERRIDES_V5 (inserted by Backplane/build_and_install.sh) =====
// Hydra backplane: ${CHANNELS}x${CHANNELS} straight loopback. All patching
// intelligence lives in the Hydra engine, not in this driver.
// kHas_Driver_Name_Format=false: exact device name, no "%ich" suffix;
// UIDs then derive from kDriver_Name (no spaces).
// The device publishes NO user controls at all (volume/mute/clock-source/
// pitch entries removed from the object lists by build_and_install.sh) and a
// single fixed sample rate, so nothing about the backplane can be changed
// from Control Center or Audio MIDI Setup — the Hydra app is the only
// control surface. The backplane is bit-perfect by construction.
#define kHas_Driver_Name_Format false
#define kNumber_Of_Channels ${CHANNELS}
#define kDriver_Name "${DRIVER_NAME}"
#define kDevice_Name "${DEVICE_NAME}"
#define kPlugIn_BundleID "${BUNDLE_ID}"
#define kPlugIn_Icon "Hydra.icns"
#define kEnableVolumeControl false
#define kSampleRates 48000
// ===== end HYDRA_OVERRIDES_V5 =====

EOF
)
    printf '%s\n%s' "$overrides" "$(cat "$source_file")" > "$source_file"

    # 1. Unpublish ALL user-facing control objects (device object lists):
    #    volume, mute, clock source and pitch. Control Center greys the
    #    slider out and Audio MIDI Setup shows nothing editable.
    sed -i '' \
        -e '/^[[:space:]]*{ kObjectID_Volume_Input_Master,/d' \
        -e '/^[[:space:]]*{ kObjectID_Mute_Input_Master,/d' \
        -e '/^[[:space:]]*{ kObjectID_Volume_Output_Master,/d' \
        -e '/^[[:space:]]*{ kObjectID_Mute_Output_Master,/d' \
        -e '/^[[:space:]]*{ kObjectID_Pitch_Adjust,/d' \
        -e '/^[[:space:]]*{ kObjectID_ClockSource,/d' \
        "$source_file"
    if grep -q '^[[:space:]]*{ kObjectID_ClockSource,' "$source_file"; then
        fail "control-list patch did not apply — BlackHole source layout changed?"
    fi
    log "Volume/mute/clock/pitch controls unpublished"

    # 2. Belt and suspenders: neutralize the mute setter too.
    sed -i '' 's/gMute_Master_Value = \*((const UInt32\*)inData) != 0;/gMute_Master_Value = false; \/* HYDRA: mute locked off *\//' "$source_file"
    grep -q "HYDRA: mute locked off" "$source_file" \
        && log "Mute setter neutralized" \
        || fail "mute patch did not apply — BlackHole source layout changed?"
}

build_driver() {
    log "Building (Release, universal: arm64 + x86_64) ..."
    ( cd "$SRC_DIR" && xcodebuild \
        -project BlackHole.xcodeproj \
        -target BlackHole \
        -configuration Release \
        CONFIGURATION_BUILD_DIR=build \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO \
        > "$WORK_DIR/xcodebuild.log" 2>&1 ) \
        || fail "xcodebuild failed — see $WORK_DIR/xcodebuild.log"

    [[ -d "$BUILD_DIR/BlackHole.driver" ]] || fail "build output missing: $BUILD_DIR/BlackHole.driver"

    rm -rf "$DRIVER_BUNDLE"
    mv "$BUILD_DIR/BlackHole.driver" "$DRIVER_BUNDLE"

    log "Embedding Hydra device icon ..."
    mkdir -p "$DRIVER_BUNDLE/Contents/Resources"
    iconutil -c icns "$SCRIPT_DIR/HydraIcon.iconset" \
        -o "$DRIVER_BUNDLE/Contents/Resources/Hydra.icns" \
        || fail "iconutil failed — is Backplane/HydraIcon.iconset present?"

    log "Ad-hoc signing ..."
    codesign --force --deep -s - "$DRIVER_BUNDLE"

    log "Built: $DRIVER_BUNDLE"
}

install_driver() {
    [[ -d "$DRIVER_BUNDLE" ]] || fail "nothing built yet — run: $0 build"
    log "Installing to $HAL_DIR (sudo required) ..."
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME.driver"
    sudo cp -R "$DRIVER_BUNDLE" "$HAL_DIR/"
    sudo chown -R root:wheel "$HAL_DIR/$DRIVER_NAME.driver"

    log "Restarting coreaudiod ..."
    # `launchctl kickstart` is blocked by SIP on recent macOS; killall works
    # (launchd respawns coreaudiod automatically).
    sudo killall coreaudiod 2>/dev/null || true
    sleep 3

    if system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE_NAME"; then
        log "OK: \"$DEVICE_NAME\" is live. Check Audio MIDI Setup → ${CHANNELS} ins / ${CHANNELS} outs."
    else
        log "Installed, but device not visible yet. Open Audio MIDI Setup to confirm;"
        log "if absent, check Console.app for coreaudiod messages."
    fi
}

uninstall_driver() {
    log "Removing $HAL_DIR/$DRIVER_NAME.driver (sudo required) ..."
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME.driver"
    sudo killall coreaudiod 2>/dev/null || true
    log "Removed."
}

case "$ACTION" in
    all)       require_xcode; fetch_source; customize_source; build_driver; install_driver ;;
    build)     require_xcode; fetch_source; customize_source; build_driver ;;
    install)   install_driver ;;
    uninstall) uninstall_driver ;;
    *)         fail "unknown action: $ACTION (use: all | build | install | uninstall)" ;;
esac
