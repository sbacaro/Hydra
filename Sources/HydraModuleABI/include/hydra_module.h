// Hydra Audio — GPL-3.0
// Generic module ABI — a stable C interface that lets external, separately
// built modules provide network audio SOURCES (and later sinks) to Hydra
// without any module-specific code living in the distributed daemon.
//
// The distributed Hydra ships only this loader/ABI (a plain, vendor-neutral
// plugin host — nothing protocol-specific). A module is a .dylib the user
// drops into  ~/Library/Application Support/Hydra/modules/  that exports a
// single entry point:
//
//     const HydraModule *hydra_module_entry(void);
//
// This keeps any protocol implementation (e.g. an experimental, personal
// interop module) entirely outside the shipped binary.

#ifndef HYDRA_MODULE_H
#define HYDRA_MODULE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HYDRA_MODULE_ABI_VERSION 1

// A source the module discovered on the network and can receive from.
typedef struct {
    const char *id;        // stable unique id (module namespace)
    const char *name;      // human label shown in the UI
    int32_t     channels;  // channel count (0 = unknown yet)
    int32_t     subscribed; // 0/1 — currently receiving
} HydraModuleSource;

// A SINK the module can transmit to the network (Hydra → module → network).
// The TX members on HydraModule are APPENDED (the ABI version stays 1); a
// sinks-aware host detects support via `list_sinks != NULL`, and an older host
// simply never reads the appended fields. MUST stay byte-identical to the module
// copy in Modules/HydraDante/include/hydra_module.h.
typedef struct {
    const char *id;        // stable unique id (module namespace)
    const char *name;      // human label shown in the UI
    int32_t     channels;  // channel count of this sink
} HydraModuleSink;

// Host callbacks handed to the module at start(). The module calls these to
// deliver audio it received and to report status. `ctx` is opaque host state.
typedef struct {
    void *ctx;

    // The module's source list changed (added/removed/format known). The
    // host will re-query list_sources().
    void (*sources_changed)(void *ctx);

    // Deliver received audio for a subscribed source: interleaved float32,
    // `frames` frames of `channels` channels at `rate` Hz. The host resamples
    // to the engine clock, so the module need not match the engine rate.
    void (*deliver_audio)(void *ctx, const char *source_id,
                          const float *interleaved, int32_t channels,
                          int32_t frames, double rate);

    // Free-form log line (shown in the daemon log).
    void (*log)(void *ctx, const char *message);
} HydraHost;

// The module's exported interface (a vtable + identity). `self` is the
// module's own opaque instance, passed back into every call.
typedef struct {
    int32_t     abi_version;   // must equal HYDRA_MODULE_ABI_VERSION
    const char *name;          // e.g. "Dante"
    const char *version;       // module version string
    void       *instance;      // module instance (opaque to the host)

    // Lifecycle. start() returns 0 on success.
    int32_t (*start)(void *self, const HydraHost *host);
    void    (*stop)(void *self);

    // Discovery: fill up to `max` entries, return the count written.
    int32_t (*list_sources)(void *self, HydraModuleSource *out, int32_t max);

    // Subscribe (subscribe=1) or unsubscribe (0) to a source's audio.
    // Returns 0 on success.
    int32_t (*subscribe)(void *self, const char *source_id, int32_t subscribe);

    // ---- Appended (abi stays 1): TX / sinks (audio Hydra → module → network) ----
    // List the module's transmit destinations; fill up to `max`, return count.
    // NULL = the module has no sinks (RX-only).
    int32_t (*list_sinks)(void *self, HydraModuleSink *out, int32_t max);

    // Deliver audio Hydra routed to a sink: interleaved float32, `frames` frames of
    // `channels` channels at `rate` Hz. Called on the host's module thread.
    void    (*send_audio)(void *self, const char *sink_id, const float *interleaved,
                          int32_t channels, int32_t frames, double rate);
} HydraModule;

// Each module .dylib must export exactly this symbol.
typedef const HydraModule *(*hydra_module_entry_fn)(void);

#ifdef __cplusplus
}
#endif

#endif // HYDRA_MODULE_H
