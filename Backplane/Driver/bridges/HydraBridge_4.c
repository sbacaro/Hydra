// Hydra Audio — GPL-3.0
// Hydra Audio Bridge 4 — 4 in / 4 out loopback CoreAudio device.
// Sets the per-bridge overrides, then includes the shared driver implementation.
// TEMP (Fase 2): nasce VISÍVEL para teste. Na Fase 3 isto vira false e o engine
// adquire/solta o box conforme o toggle do usuário.
#define kNumber_Of_Channels 4
#define kDriver_Name        "HydraAudioBridge4"
#define kDevice_Name        "Hydra Audio Bridge 4"
#define kPlugIn_BundleID    "audio.hydra.bridge.4"
#define kBox_Aquired        true
#include "../Hydra.c"
