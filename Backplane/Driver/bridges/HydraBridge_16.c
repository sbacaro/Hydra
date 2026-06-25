// Hydra Audio — GPL-3.0
// Hydra Audio Bridge 16 — 16 in / 16 out loopback CoreAudio device.
// Sets the per-bridge overrides, then includes the shared driver implementation.
// TEMP (Fase 2): nasce VISÍVEL para teste. Na Fase 3 isto vira false e o engine
// adquire/solta o box conforme o toggle do usuário.
#define kNumber_Of_Channels 16
#define kDriver_Name        "HydraAudioBridge16"
#define kDevice_Name        "Hydra Audio Bridge 16"
#define kPlugIn_BundleID    "audio.hydra.bridge.16"
#define kBox_Aquired        true
#include "../Hydra.c"
