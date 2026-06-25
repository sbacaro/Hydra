#!/bin/bash
# Hydra Audio — GPL-3.0
# DEV helper: remove Hydra audio drivers from /Library/Audio/Plug-Ins/HAL and
# restart coreaudiod.
#
# Usage:
#   bash Scripts/bridges_uninstall.sh           # remove all 8 bridges
#   bash Scripts/bridges_uninstall.sh --all     # also remove the legacy 256-ch driver
#   bash Scripts/bridges_uninstall.sh 2A 4      # remove specific bridges

set -euo pipefail
HAL="/Library/Audio/Plug-Ins/HAL"
log() { printf '\033[1;35m[bridges]\033[0m %s\n' "$*"; }

targets=()
if [[ "${1:-}" == "--all" ]]; then
  targets=("$HAL"/HydraAudioBridge*.driver "$HAL/HydraVirtualSoundcard.driver")
elif [[ $# -gt 0 ]]; then
  for s in "$@"; do targets+=("$HAL/HydraAudioBridge$s.driver"); done
else
  targets=("$HAL"/HydraAudioBridge*.driver)
fi

removed=0
for t in "${targets[@]}"; do
  if [[ -d "$t" ]]; then
    sudo rm -rf "$t"
    log "removed $(basename "$t")"
    removed=$((removed+1))
  fi
done
[[ $removed -gt 0 ]] || log "nothing matched — already clean?"

log "Restarting coreaudiod ..."
sudo killall coreaudiod 2>/dev/null || true
sleep 2
log "Done."
