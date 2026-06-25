// Hydra Audio — GPL-3.0
// Hydra Audio Bridge 64 — 64 in / 64 out loopback CoreAudio device.
// Sets the per-bridge overrides, then includes the shared driver implementation.
// TEMP (Fase 2): nasce VISÍVEL para teste. Na Fase 3 isto vira false e o engine
// adquire/solta o box conforme o toggle do usuário.
#define kNumber_Of_Channels 64
#define kDriver_Name        "HydraAudioBridge64"
#define kDevice_Name        "Hydra Audio Bridge 64"
#define kPlugIn_BundleID    "audio.hydra.bridge.64"
#define kBox_Aquired        true
#include "../Hydra.c"
