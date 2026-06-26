// Hydra Audio — GPL-3.0
// Shared-memory transport between the daemon (hydrad) and an out-of-process
// VST plugin host (hydra-plugin-host). The whole point is crash isolation: a
// plugin that segfaults takes down the host process, NOT the audio daemon.
//
// Design (RT-safe on the daemon's audio thread — no syscalls, no locks):
//   • One POSIX shm region per hosted chain. Layout = this header, immediately
//     followed by an interleaved input buffer and an interleaved output buffer.
//   • Lock-free handshake via sequence counters with acquire/release ordering:
//       - daemon writes `input`, sets `frames`, then bumps `inputSeq`.
//       - host busy-polls `inputSeq`, processes the chain, writes `output`,
//         then bumps `outputSeq` (and `heartbeat` for liveness).
//       - daemon reads `outputSeq`: if it advanced since last cycle it adopts
//         `output`; otherwise it passes the input through (graceful bypass).
//   • The daemon NEVER blocks: it always has *a* result (this block's or, on a
//     slow/dead host, the dry signal). Cost is at most one block of latency on
//     inserted strips.
//
// The atomic helpers below use the C11 __atomic builtins and are imported into
// Swift as ordinary functions, so both the daemon and the host operate on the
// same memory with correct ordering without needing Swift's Atomic-over-shm.

#ifndef HYDRA_PLUGIN_SHM_H
#define HYDRA_PLUGIN_SHM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// All pointers below are non-null, so Swift imports them as non-optional
// `UnsafeMutablePointer<...>` (no force-unwrap needed at the buffer/atomic sites).
#pragma clang assume_nonnull begin

/// 'HYPD' — sanity check that a mapping is actually ours.
#define HYDRA_PLUGIN_SHM_MAGIC 0x48595044u
/// Bump when this struct layout changes; daemon and host must agree.
/// v2 added the daemon→host command ring (open editor / set parameter).
#define HYDRA_PLUGIN_SHM_ABI   2u
/// Number of audio block slots for input and output. Each cycle uses the slot
/// `seq % SLOTS`, so the producer never overwrites a buffer the consumer is
/// still reading (no torn audio) given the ~1-block pipeline depth. 4 gives
/// generous headroom against scheduling jitter.
#define HYDRA_PLUGIN_SHM_SLOTS 4u
/// Capacity of the daemon→host control command ring (SPSC).
#define HYDRA_PLUGIN_CMD_SLOTS 64u

/// Control command kinds (daemon → host).
enum {
    HYDRA_CMD_NONE         = 0,
    HYDRA_CMD_OPEN_EDITOR  = 1,   // open plugin `instance`'s editor window
    HYDRA_CMD_SET_PARAM    = 2,   // set `paramId` = `value` on plugin `instance`
    HYDRA_CMD_CLOSE_EDITOR = 3,   // close plugin `instance`'s editor window
};

/// One control command. `instance` indexes the chain (0-based, in load order).
typedef struct {
    uint32_t type;       // HYDRA_CMD_*
    int32_t  instance;   // target plugin in the chain
    uint32_t paramId;    // for SET_PARAM
    float    value;      // for SET_PARAM (normalised 0..1)
} hydra_plugin_cmd;

/// Fixed-layout control block at the start of the shared region.
typedef struct {
    uint32_t magic;        // HYDRA_PLUGIN_SHM_MAGIC
    uint32_t abiVersion;   // HYDRA_PLUGIN_SHM_ABI
    int32_t  channels;     // channel count (set at creation, never changes)
    int32_t  maxFrames;    // per-channel capacity of each buffer
    int32_t  frames;       // frames in the current block (daemon writes)
    int32_t  _pad;
    uint64_t inputSeq;     // daemon bumps after writing the input buffer
    uint64_t outputSeq;    // host bumps after writing the output buffer
    uint64_t heartbeat;    // host bumps every loop iteration (liveness)
    uint32_t hostReady;    // host sets 1 once the chain is loaded
    uint32_t hostFailed;   // host sets 1 if the chain could not be loaded
    // Control command ring (daemon writes, host drains on its main run loop).
    uint64_t cmdWriteSeq;  // daemon bumps after writing a command
    uint64_t cmdReadSeq;   // host bumps after consuming a command
    hydra_plugin_cmd commands[HYDRA_PLUGIN_CMD_SLOTS];
    // float input [channels * maxFrames]   immediately follows
    // float output[channels * maxFrames]   follows the input buffer
} hydra_plugin_shm;

/// Floats per block buffer (one slot, one direction).
static inline size_t hydra_plugin_shm_slot_floats(int32_t channels, int32_t maxFrames) {
    return (size_t)channels * (size_t)maxFrames;
}

/// Total bytes to allocate: header + SLOTS input buffers + SLOTS output buffers.
static inline size_t hydra_plugin_shm_bytes(int32_t channels, int32_t maxFrames) {
    return sizeof(hydra_plugin_shm)
         + (size_t)2 * (size_t)HYDRA_PLUGIN_SHM_SLOTS
         * hydra_plugin_shm_slot_floats(channels, maxFrames) * sizeof(float);
}

/// Interleaved input buffer (daemon → host) for `slot` in [0, SLOTS).
static inline float *hydra_plugin_shm_input(hydra_plugin_shm *s, uint64_t slot) {
    float *base = (float *)((char *)s + sizeof(hydra_plugin_shm));
    return base + (slot % HYDRA_PLUGIN_SHM_SLOTS)
                  * hydra_plugin_shm_slot_floats(s->channels, s->maxFrames);
}

/// Interleaved output buffer (host → daemon) for `slot` in [0, SLOTS).
static inline float *hydra_plugin_shm_output(hydra_plugin_shm *s, uint64_t slot) {
    float *base = (float *)((char *)s + sizeof(hydra_plugin_shm))
                + (size_t)HYDRA_PLUGIN_SHM_SLOTS
                  * hydra_plugin_shm_slot_floats(s->channels, s->maxFrames);
    return base + (slot % HYDRA_PLUGIN_SHM_SLOTS)
                  * hydra_plugin_shm_slot_floats(s->channels, s->maxFrames);
}

/// Command slot for sequence `seq` (the fixed C array is otherwise a tuple in
/// Swift; this hands back a usable pointer).
static inline hydra_plugin_cmd *hydra_plugin_shm_cmd(hydra_plugin_shm *s, uint64_t seq) {
    return &s->commands[(size_t)(seq % HYDRA_PLUGIN_CMD_SLOTS)];
}

// --- Atomic accessors (acquire/release) shared by both processes -------------

static inline uint64_t hydra_shm_load_u64(const uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}
static inline void hydra_shm_store_u64(uint64_t *p, uint64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}
static inline uint32_t hydra_shm_load_u32(const uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}
static inline void hydra_shm_store_u32(uint32_t *p, uint32_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

// --- POSIX shm helpers (non-variadic, so Swift can call them) ---------------
// `shm_open`/`ftruncate` are clumsy to call directly from Swift; these wrap the
// create-and-size and open paths into plain C functions.

/// Unlink any stale region, create + size a new one. Returns an fd or -1.
int hydra_shm_create(const char *name, size_t bytes);

/// Open an existing region read/write. Returns an fd or -1.
int hydra_shm_open_rw(const char *name);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* HYDRA_PLUGIN_SHM_H */
