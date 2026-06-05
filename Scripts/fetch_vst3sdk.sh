#!/bin/bash
# Hydra Audio — GPL-3.0
# Fetches the Steinberg VST3 SDK (GPLv3 option) into ThirdParty/vst3sdk.
# Only the hosting headers/sources are compiled (see Sources/HydraVST).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_DIR="$PROJECT_DIR/ThirdParty/vst3sdk"
SDK_TAG="${VST3SDK_TAG:-v3.7.9_build_61}"

log() { printf '\033[1;35m[vst3sdk]\033[0m %s\n' "$*"; }

if [[ -d "$SDK_DIR/pluginterfaces" ]]; then
    log "VST3 SDK already present ($SDK_DIR)"
    exit 0
fi

log "Cloning VST3 SDK @ $SDK_TAG (with submodules — this takes a minute) ..."
mkdir -p "$PROJECT_DIR/ThirdParty"
git clone --depth 1 --branch "$SDK_TAG" --recurse-submodules --shallow-submodules \
    https://github.com/steinbergmedia/vst3sdk.git "$SDK_DIR"
log "Done: $SDK_DIR"
