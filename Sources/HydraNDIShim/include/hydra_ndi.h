// Hydra Audio — GPL-3.0
// Flat C facade over the (proprietary) NDI runtime, loaded with dlopen at
// runtime. Hydra never links or bundles the runtime: the user installs the
// official Vizrt redistributable (see Hydra.ndiRedistURL) and this shim
// resolves the symbols dynamically — the GPL/DistroAV pattern.
//
// Everything ABI-sensitive (struct layouts, enum values) lives in the .c
// file only; Swift sees just these opaque, audio-only calls.

#ifndef HYDRA_NDI_H
#define HYDRA_NDI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[256];
    char url[256];
} hndi_source_t;

/// Loads + initializes the NDI runtime. 1 = ready, 0 = not installed/failed.
/// Idempotent — safe to call repeatedly.
int hndi_load(void);

/// Runtime version string (only valid after hndi_load() == 1).
const char *hndi_version(void);

/// Discovery. find_sources fills `out` (up to `max`) and returns the count.
void *hndi_find_create(void);
void hndi_find_destroy(void *find);
int hndi_find_sources(void *find, hndi_source_t *out, int max);

/// Audio-only receiver for one source.
void *hndi_recv_create(const char *ndi_name, const char *url);
void hndi_recv_destroy(void *recv);

/// Blocks up to timeout_ms for one audio frame; converts planar float →
/// interleaved into `interleaved` (≤ max_frames × max_channels). Returns
/// frames written (0 = timeout/no audio). Reports the source format via
/// out_channels/out_rate (clamped to max_channels).
int hndi_recv_audio(void *recv, float *interleaved, int max_frames,
                    int max_channels, int *out_channels, int *out_rate,
                    uint32_t timeout_ms);

/// Sender: announces an NDI audio source named `name` on the network.
void *hndi_send_create(const char *name, int channels, int rate);
void hndi_send_destroy(void *send);

/// Sends interleaved float frames (converted to planar internally).
void hndi_send_audio(void *send, const float *interleaved, int frames);

#ifdef __cplusplus
}
#endif

#endif /* HYDRA_NDI_H */
