// Hydra Audio — GPL-3.0
// Hydra Engine hub — the INTERNAL clock + mixing device the engine runs its
// IOProc on. The engine finds it by name ("Hydra Engine" — see
// Hydra.backplaneDeviceName) and routes all bridge/device/network taps through
// its matrix pass.
//
// It keeps the legacy UID/bundle id (HydraVirtualSoundcard_UID /
// audio.hydra.virtualsoundcard) so existing engine code and the original
// Info.plist factory UUID keep working. The box stays acquired by default so the
// device is always present for the engine.
//
// HIDDEN: kDevice_IsHidden only sets the device's kAudioDevicePropertyIsHidden
// flag (see Hydra.c GetDevicePropertyData) — the device STAYS in the system
// device list (kAudioHardwarePropertyDevices), so the engine's findDevice(named:)
// still locates it. Audio MIDI Setup / System Settings just filter it out, so the
// user never sees it. They see only the Hydra Audio Bridges.
#define kNumber_Of_Channels 256
#define kDriver_Name        "HydraVirtualSoundcard"
#define kDevice_Name        "Hydra Engine"
#define kPlugIn_BundleID    "audio.hydra.virtualsoundcard"
#define kDevice_IsHidden    true
#include "Hydra.c"
