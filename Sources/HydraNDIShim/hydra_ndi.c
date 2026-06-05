// Hydra Audio — GPL-3.0
// NDI runtime loader + flat audio-only facade. See hydra_ndi.h.
//
// ABI declarations below are written against the public NDI SDK v5/v6
// headers (Processing.NDI.*). Only the audio subset Hydra needs is declared;
// video frames are never requested (receivers are created audio-only).

#include "include/hydra_ndi.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: - NDI ABI (subset)

typedef struct {
    const char *p_ndi_name;
    const char *p_url_address;
} NDIlib_source_t;

typedef struct {
    bool show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} NDIlib_find_create_t;

typedef struct {
    NDIlib_source_t source_to_connect_to;
    int color_format;       // NDIlib_recv_color_format_e
    int bandwidth;          // NDIlib_recv_bandwidth_e
    bool allow_video_fields;
    const char *p_ndi_recv_name;
} NDIlib_recv_create_v3_t;

enum { NDI_recv_bandwidth_audio_only = 10 };
enum { NDI_recv_color_format_fastest = 100 };

typedef struct {
    int sample_rate;
    int no_channels;
    int no_samples;
    int64_t timecode;
    uint32_t FourCC;        // NDIlib_FourCC_audio_type_e ('FLTP')
    uint8_t *p_data;
    union {
        int channel_stride_in_bytes;  // planar
        int data_size_in_bytes;
    };
    const char *p_metadata;
    int64_t timestamp;
} NDIlib_audio_frame_v3_t;

enum {
    NDI_frame_type_none = 0,
    NDI_frame_type_audio = 2,
};

#define NDI_FOURCC_FLTP ((uint32_t)('F' | ('L' << 8) | ('T' << 16) | ('P' << 24)))

typedef struct {
    const char *p_ndi_name;
    const char *p_groups;
    bool clock_video;
    bool clock_audio;
} NDIlib_send_create_t;

// MARK: - Resolved symbols

static void *g_lib = NULL;

static bool (*p_initialize)(void);
static const char *(*p_version)(void);
static void *(*p_find_create_v2)(const NDIlib_find_create_t *);
static void (*p_find_destroy)(void *);
static const NDIlib_source_t *(*p_find_get_current_sources)(void *, uint32_t *);
static void *(*p_recv_create_v3)(const NDIlib_recv_create_v3_t *);
static void (*p_recv_destroy)(void *);
static int (*p_recv_capture_v3)(void *, void *, NDIlib_audio_frame_v3_t *, void *, uint32_t);
static void (*p_recv_free_audio_v3)(void *, const NDIlib_audio_frame_v3_t *);
static void *(*p_send_create)(const NDIlib_send_create_t *);
static void (*p_send_destroy)(void *);
static void (*p_send_send_audio_v3)(void *, const NDIlib_audio_frame_v3_t *);

static void *try_dlopen(void) {
    // Same search order the official SDK documents for macOS.
    const char *env_dirs[] = { "NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5" };
    for (int i = 0; i < 2; i++) {
        const char *dir = getenv(env_dirs[i]);
        if (dir && dir[0]) {
            char path[1024];
            snprintf(path, sizeof(path), "%s/libndi.dylib", dir);
            void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
            if (lib) return lib;
        }
    }
    const char *paths[] = {
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        "libndi.dylib",
    };
    for (int i = 0; i < 3; i++) {
        void *lib = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (lib) return lib;
    }
    return NULL;
}

int hndi_load(void) {
    if (g_lib) return 1;
    void *lib = try_dlopen();
    if (!lib) return 0;

#define RESOLVE(var, sym) \
    do { *(void **)(&var) = dlsym(lib, sym); if (!var) { dlclose(lib); return 0; } } while (0)

    RESOLVE(p_initialize, "NDIlib_initialize");
    RESOLVE(p_version, "NDIlib_version");
    RESOLVE(p_find_create_v2, "NDIlib_find_create_v2");
    RESOLVE(p_find_destroy, "NDIlib_find_destroy");
    RESOLVE(p_find_get_current_sources, "NDIlib_find_get_current_sources");
    RESOLVE(p_recv_create_v3, "NDIlib_recv_create_v3");
    RESOLVE(p_recv_destroy, "NDIlib_recv_destroy");
    RESOLVE(p_recv_capture_v3, "NDIlib_recv_capture_v3");
    RESOLVE(p_recv_free_audio_v3, "NDIlib_recv_free_audio_v3");
    RESOLVE(p_send_create, "NDIlib_send_create");
    RESOLVE(p_send_destroy, "NDIlib_send_destroy");
    RESOLVE(p_send_send_audio_v3, "NDIlib_send_send_audio_v3");
#undef RESOLVE

    if (!p_initialize()) {
        dlclose(lib);
        return 0;
    }
    g_lib = lib;
    return 1;
}

const char *hndi_version(void) {
    return (g_lib && p_version) ? p_version() : "";
}

// MARK: - Find

void *hndi_find_create(void) {
    if (!g_lib) return NULL;
    NDIlib_find_create_t desc = { .show_local_sources = true, .p_groups = NULL, .p_extra_ips = NULL };
    return p_find_create_v2(&desc);
}

void hndi_find_destroy(void *find) {
    if (g_lib && find) p_find_destroy(find);
}

int hndi_find_sources(void *find, hndi_source_t *out, int max) {
    if (!g_lib || !find) return 0;
    uint32_t count = 0;
    const NDIlib_source_t *sources = p_find_get_current_sources(find, &count);
    if (!sources) return 0;
    int n = (int)count < max ? (int)count : max;
    for (int i = 0; i < n; i++) {
        strlcpy(out[i].name, sources[i].p_ndi_name ? sources[i].p_ndi_name : "", sizeof(out[i].name));
        strlcpy(out[i].url, sources[i].p_url_address ? sources[i].p_url_address : "", sizeof(out[i].url));
    }
    return n;
}

// MARK: - Receive

void *hndi_recv_create(const char *ndi_name, const char *url) {
    if (!g_lib) return NULL;
    NDIlib_recv_create_v3_t desc = {
        .source_to_connect_to = { .p_ndi_name = ndi_name, .p_url_address = url && url[0] ? url : NULL },
        .color_format = NDI_recv_color_format_fastest,
        .bandwidth = NDI_recv_bandwidth_audio_only,
        .allow_video_fields = false,
        .p_ndi_recv_name = "Hydra",
    };
    return p_recv_create_v3(&desc);
}

void hndi_recv_destroy(void *recv) {
    if (g_lib && recv) p_recv_destroy(recv);
}

int hndi_recv_audio(void *recv, float *interleaved, int max_frames,
                    int max_channels, int *out_channels, int *out_rate,
                    uint32_t timeout_ms) {
    if (!g_lib || !recv) return 0;
    NDIlib_audio_frame_v3_t frame;
    memset(&frame, 0, sizeof(frame));
    int type = p_recv_capture_v3(recv, NULL, &frame, NULL, timeout_ms);
    if (type != NDI_frame_type_audio || !frame.p_data) return 0;
    if (frame.FourCC != NDI_FOURCC_FLTP) {  // only planar float is defined for v3
        p_recv_free_audio_v3(recv, &frame);
        return 0;
    }

    int channels = frame.no_channels < max_channels ? frame.no_channels : max_channels;
    int frames = frame.no_samples < max_frames ? frame.no_samples : max_frames;
    int stride_floats = frame.channel_stride_in_bytes / (int)sizeof(float);

    const float *planar = (const float *)frame.p_data;
    for (int ch = 0; ch < channels; ch++) {
        const float *src = planar + ch * stride_floats;
        for (int f = 0; f < frames; f++) {
            interleaved[f * channels + ch] = src[f];
        }
    }
    if (out_channels) *out_channels = channels;
    if (out_rate) *out_rate = frame.sample_rate;
    p_recv_free_audio_v3(recv, &frame);
    return frames;
}

// MARK: - Send

typedef struct {
    void *instance;
    int channels;
    int rate;
    int capacity;       // frames the planar scratch can hold
    float *planar;
} hndi_send_ctx;

void *hndi_send_create(const char *name, int channels, int rate) {
    if (!g_lib || channels < 1) return NULL;
    NDIlib_send_create_t desc = {
        .p_ndi_name = name,
        .p_groups = NULL,
        .clock_video = false,
        .clock_audio = false,   // we pace from the audio engine's clock
    };
    void *instance = p_send_create(&desc);
    if (!instance) return NULL;

    hndi_send_ctx *ctx = calloc(1, sizeof(hndi_send_ctx));
    ctx->instance = instance;
    ctx->channels = channels;
    ctx->rate = rate;
    ctx->capacity = 8192;
    ctx->planar = calloc((size_t)ctx->capacity * channels, sizeof(float));
    return ctx;
}

void hndi_send_destroy(void *send) {
    hndi_send_ctx *ctx = send;
    if (!ctx) return;
    if (g_lib && ctx->instance) p_send_destroy(ctx->instance);
    free(ctx->planar);
    free(ctx);
}

void hndi_send_audio(void *send, const float *interleaved, int frames) {
    hndi_send_ctx *ctx = send;
    if (!g_lib || !ctx || frames < 1) return;
    if (frames > ctx->capacity) frames = ctx->capacity;

    for (int ch = 0; ch < ctx->channels; ch++) {
        float *dst = ctx->planar + ch * frames;
        for (int f = 0; f < frames; f++) {
            dst[f] = interleaved[f * ctx->channels + ch];
        }
    }
    NDIlib_audio_frame_v3_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.sample_rate = ctx->rate;
    frame.no_channels = ctx->channels;
    frame.no_samples = frames;
    frame.timecode = INT64_MAX;  // NDIlib_send_timecode_synthesize
    frame.FourCC = NDI_FOURCC_FLTP;
    frame.p_data = (uint8_t *)ctx->planar;
    frame.channel_stride_in_bytes = frames * (int)sizeof(float);
    p_send_send_audio_v3(ctx->instance, &frame);
}
