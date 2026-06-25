// Hydra Audio — GPL-3.0
// Hydra Audio Bridge 2-B — 2 in / 2 out loopback CoreAudio device.
// Sets the per-bridge overrides, then includes the shared driver implementation.
// TEMP (Fase 2): nasce VISÍVEL para teste. Na Fase 3 isto vira false e o engine
// adquire/solta o box conforme o toggle do usuário.
#define kNumber_Of_Channels 2
#define kDriver_Name        "HydraAudioBridge2B"
#define kDevice_Name        "Hydra Audio Bridge 2-B"
#define kPlugIn_BundleID    "audio.hydra.bridge.2b"
#define kBox_Aquired        true
#include "../Hydra.c"
