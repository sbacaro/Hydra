#!/bin/bash
# Hydra Audio — GPL-3.0
# DEV helper: build + install all 8 Hydra Audio Bridge drivers, then restart
# coreaudiod so they appear in Audio MIDI Setup. For iterating during the
# multi-bridge migration — the shipping app will embed + install these itself.
#
# Usage:
#   bash Scripts/bridges_install.sh          # build + install all 8
#   bash Scripts/bridges_install.sh 2A 4     # only specific bridges
#
# Requires: the Xcode project has been generated (xcodegen generate, or
# ruby Scripts/generate_xcodeproj.rb) AFTER the bridge targets were added.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAL="/Library/Audio/Plug-Ins/HAL"
DD="$PROJ_DIR/.bridgebuild"

log()  { printf '\033[1;35m[bridges]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[bridges] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

PROJECT="$(ls -d "$PROJ_DIR"/*.xcodeproj 2>/dev/null | head -1)"
[[ -n "$PROJECT" ]] || fail "no .xcodeproj found — run 'xcodegen generate' first."
log "Project: $PROJECT"

# target name : built product (.driver) name. The hidden engine hub is built +
# installed first (always) — the engine routes the bridges THROUGH it.
declare -a ALL=(
  "HydraVirtualSoundcard:HydraVirtualSoundcard"
  "HydraBridge2A:HydraAudioBridge2A"
  "HydraBridge2B:HydraAudioBridge2B"
  "HydraBridge4:HydraAudioBridge4"
  "HydraBridge8:HydraAudioBridge8"
  "HydraBridge16:HydraAudioBridge16"
  "HydraBridge32:HydraAudioBridge32"
  "HydraBridge64:HydraAudioBridge64"
  "HydraBridge128:HydraAudioBridge128"
)

# Optional filter by suffix (e.g. "2A 4 128").
SELECT=("$@")
selected() {
  [[ ${#SELECT[@]} -eq 0 ]] && return 0
  local suffix="${1#HydraBridge}"
  for s in "${SELECT[@]}"; do [[ "$s" == "$suffix" ]] && return 0; done
  return 1
}

built=()
for entry in "${ALL[@]}"; do
  target="${entry%%:*}"; product="${entry##*:}"
  selected "$target" || continue
  log "Building $target ..."
  # NB: -target can't be combined with -derivedDataPath (xcodebuild wants a
  # -scheme for that). CONFIGURATION_BUILD_DIR drops the .driver straight here.
  xcodebuild build \
    -project "$PROJECT" -target "$target" -configuration Release \
    CONFIGURATION_BUILD_DIR="$DD" CODE_SIGNING_ALLOWED=NO >/dev/null \
    || fail "build failed for $target"
  drv="$DD/$product.driver"
  [[ -d "$drv" ]] || fail "built bundle not found: $drv"
  codesign --force -s - "$drv"          # ad-hoc sign (required on Apple Silicon)
  built+=("$drv")
done

[[ ${#built[@]} -gt 0 ]] || fail "nothing built (check the bridge suffixes)."

log "Installing ${#built[@]} bridge(s) to $HAL (sudo required) ..."
for drv in "${built[@]}"; do
  name="$(basename "$drv")"
  sudo rm -rf "$HAL/$name"
  sudo cp -R "$drv" "$HAL/"
  sudo chown -R root:wheel "$HAL/$name"
  sudo xattr -dr com.apple.quarantine "$HAL/$name" 2>/dev/null || true
  log "  installed $name"
done

log "Restarting coreaudiod (system audio blips for ~1-2s) ..."
sudo killall coreaudiod 2>/dev/null || true
sleep 3

log "Done. Visible Hydra devices now:"
system_profiler SPAudioDataType 2>/dev/null | grep -i "Hydra Audio Bridge" || log "  (none detected yet — give it a few seconds and re-check Audio MIDI Setup)"
