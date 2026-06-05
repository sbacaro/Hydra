#!/bin/bash
# Hydra Audio — GPL-3.0
# VM: installs everything in one command, from the SMB-shared project folder.
# Run AFTER ./Scripts/host_build.sh produced dist/ on the host.
#
# Usage (from the shared folder, on the VM):
#   bash Scripts/vm_install.sh             # install driver + binaries, restart coreaudiod
#   bash Scripts/vm_install.sh uninstall   # remove everything
#   bash Scripts/vm_install.sh status      # check what is installed/visible
#
# Notes:
# - Use `bash ...` (execute bits may not survive SMB).
# - Binaries are copied to the VM's local disk (running off SMB is unreliable).
# - SIP stays on; the driver is a userspace HAL plugin, ad-hoc signed.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
DRIVER_NAME="HydraVirtualSoundcard"
DEVICE_NAME="Hydra Virtual Soundcard"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALL_DIR="/usr/local/hydra"

log()  { printf '\033[1;35m[hydra vm]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[hydra vm] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

restart_coreaudiod() {
    log "Restarting coreaudiod ..."
    # `launchctl kickstart` on coreaudiod is blocked by SIP on recent macOS.
    # killall works: launchd respawns coreaudiod automatically.
    sudo killall coreaudiod 2>/dev/null || true
    sleep 3
}

device_visible() {
    system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEVICE_NAME"
}

# NDI runtime: proprietary, so it can't be bundled with Hydra (GPL). Vizrt's
# license DOES allow apps to fetch the official redistributable directly —
# that's what this does, making it feel built-in (like the driver install).
NDI_REDIST_URL="https://ndi.link/NDIRedistV6Apple"

install_ndi_runtime() {
    if [[ -f /usr/local/lib/libndi.dylib ]]; then
        log "NDI runtime: already installed."
        return 0
    fi
    log "NDI runtime not found — downloading the official Vizrt installer ..."
    local pkg=/tmp/ndi_runtime.pkg
    if curl -fsSL -o "$pkg" "$NDI_REDIST_URL"; then
        log "Installing NDI runtime (sudo required) ..."
        if sudo installer -pkg "$pkg" -target / >/dev/null; then
            log "NDI runtime installed."
        else
            log "WARNING: NDI runtime install failed — NDI features stay off (everything else works)."
        fi
        rm -f "$pkg"
    else
        log "WARNING: could not download the NDI runtime (offline?) — NDI features stay off."
        log "         Manual install: $NDI_REDIST_URL"
    fi
}

do_install() {
    [[ -d "$DIST_DIR/$DRIVER_NAME.driver" ]] || fail "dist/ not found or incomplete — run ./Scripts/host_build.sh on the host first"
    [[ -f "$DIST_DIR/hydrad" && -f "$DIST_DIR/HydraApp" ]] || fail "binaries missing in dist/"

    log "Installing driver to $HAL_DIR (sudo required) ..."
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME.driver"
    sudo cp -R "$DIST_DIR/$DRIVER_NAME.driver" "$HAL_DIR/"
    sudo chown -R root:wheel "$HAL_DIR/$DRIVER_NAME.driver"
    # Clear quarantine if SMB/Finder added it.
    sudo xattr -dr com.apple.quarantine "$HAL_DIR/$DRIVER_NAME.driver" 2>/dev/null || true

    log "Installing binaries to $INSTALL_DIR (local disk) ..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp "$DIST_DIR/hydrad" "$DIST_DIR/HydraApp" "$INSTALL_DIR/"
    sudo chmod +x "$INSTALL_DIR/hydrad" "$INSTALL_DIR/HydraApp"
    sudo xattr -d com.apple.quarantine "$INSTALL_DIR/hydrad" "$INSTALL_DIR/HydraApp" 2>/dev/null || true

    install_ndi_runtime

    restart_coreaudiod

    if device_visible; then
        log "OK: \"$DEVICE_NAME\" is live (check Audio MIDI Setup: 256 in / 256 out)."
    else
        log "Driver installed but device not visible yet — open Audio MIDI Setup;"
        log "if absent, check Console.app for coreaudiod messages."
    fi

    [[ -f "$DIST_DIR/BUILD_INFO.txt" ]] && { log "Build:"; sed 's/^/    /' "$DIST_DIR/BUILD_INFO.txt"; }

    log "Phase 1 test:"
    log "  terminal 1:  $INSTALL_DIR/hydrad"
    log "  terminal 2:  $INSTALL_DIR/HydraApp"
    log "Expected: app shows Daemon: Connected + Backplane 256 in / 256 out."
}

do_uninstall() {
    log "Removing driver and binaries (sudo required) ..."
    sudo rm -rf "$HAL_DIR/$DRIVER_NAME.driver"
    sudo rm -rf "$INSTALL_DIR"
    restart_coreaudiod
    log "Removed."
}

do_status() {
    if [[ -d "$HAL_DIR/$DRIVER_NAME.driver" ]]; then
        log "Driver: installed at $HAL_DIR/$DRIVER_NAME.driver"
    else
        log "Driver: NOT installed"
    fi
    if device_visible; then
        log "Device: \"$DEVICE_NAME\" visible to Core Audio"
    else
        log "Device: not visible"
    fi
    if [[ -f /usr/local/lib/libndi.dylib ]]; then
        log "NDI runtime: installed"
    else
        log "NDI runtime: NOT installed (NDI features off)"
    fi
    for bin in hydrad HydraApp; do
        if [[ -x "$INSTALL_DIR/$bin" ]]; then
            log "Binary: $INSTALL_DIR/$bin OK"
        else
            log "Binary: $bin NOT installed"
        fi
    done
}

case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         fail "unknown action: $1 (use: install | uninstall | status)" ;;
esac
