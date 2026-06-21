// Hydra Audio — GPL-3.0
// C interface to the VST3 hosting shim (implemented in hydra_vst.mm over the
// Steinberg VST3 SDK, used under its GPLv3 option — see THIRD_PARTY_NOTICES).
// Pure C so Swift imports it without C++ interop.

#ifndef HYDRA_VST_H
#define HYDRA_VST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[256];
    char vendor[256];
    /// VST3 subcategory string, e.g. "Fx", "Fx|Reverb", "Instrument|Synth".
    /// Empty when the plugin declares none. Used by the app's plugin manager
    /// to group/filter by type (effect vs instrument vs EQ ...).
    char category[256];
} hydra_vst_class_info;

/// Opens a .vst3 bundle and returns an opaque module handle (NULL on failure).
/// `class_count` receives the number of audio-effect classes inside.
void *hydra_vst_open_module(const char *path, int32_t *class_count);

/// Info for the audio-effect class at `index` (0-based among effect classes).
bool hydra_vst_class_info_at(void *module, int32_t index, hydra_vst_class_info *out);

void hydra_vst_close_module(void *module);

/// Creates a processing instance of the effect class at `class_index` inside
/// the bundle at `path`, configured stereo in/out, 32-bit float, realtime.
/// Returns NULL on failure.
void *hydra_vst_create_instance(const char *path, int32_t class_index,
                                double sample_rate, int32_t max_block_frames);

/// Processes one block. `in2`/`out2` are arrays of 2 channel pointers
/// (deinterleaved float). RT-safe. Returns false if the plugin failed.
bool hydra_vst_process(void *instance, float *const *in2, float *const *out2,
                       int32_t frames);

void hydra_vst_destroy_instance(void *instance);

/// True if the plugin provides an editor view.
bool hydra_vst_has_editor(void *instance);

/// Opens (or refocuses) the plugin's editor window. MUST be called on the
/// main thread. Parameter changes made in the GUI reach the audio thread
/// through a lock-free queue.
bool hydra_vst_open_editor(void *instance, const char *title);

/// Sets a normalised parameter (0..1) from outside the GUI — e.g. the daemon,
/// over the out-of-process plugin-host command channel. Call on the main thread;
/// the change reaches the audio thread via the same lock-free ring as GUI edits,
/// and the editor (if open) is updated to match.
void hydra_vst_set_parameter(void *instance, uint32_t param_id, double value);

#ifdef __cplusplus
}
#endif

#endif /* HYDRA_VST_H */
