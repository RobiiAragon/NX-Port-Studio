#include "dm.h"
#include "display_mode.h"
#include <stdatomic.h>

extern uint8_t *dm_fps_state;
static double g_display_width, g_display_height;
static pthread_mutex_t g_display_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_display_loaded;
static _Atomic int g_display_ready;
static _Atomic double g_display_aspect;

int dm_display_aspect_candidate(void) {
    // Installation is evidence of original-byte checks, not visual approval.
    if (strcmp(dm_main_build(), "fe941ed5ba14be5d505698da1bbf4fe7")) return 0;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main"))
        return g_mod[i].display_aspect && dm_fps_state && g_mod[i].fps_state_off &&
               g_mod[i].base + g_mod[i].fps_state_off == dm_fps_state;
    return 0;
}

int dm_display_aspect_qualified(void) {
    // Open: MK8 3.0.5 menu backgrounds expose unpainted side areas. Camera/UI
    // arithmetic passed native tests, but this is not a qualified visual mod.
    // No iPhone gameplay validation has been performed.
    return 0;
}

static void display_activate(void) {  // caller holds g_display_lock; modules are immutable after preload
    if (atomic_load(&g_display_ready) || !(g_display_width > 0 && g_display_height > 0)) return;
    if (!dm_display_aspect_candidate()) return;
    const char *wide = getenv("DM_DISPLAY_WIDE");
    double aspect = 0;
    // A developer can exercise the byte-verified candidate in an isolated run.
    // Neither this env var nor preferences can grant missing rewrite stubs.
    if (wide && !strcmp(wide, "1")) {
        aspect = g_display_width / g_display_height;
        aspect = fmax(16.0 / 9.0, fmin(43.0 / 18.0, aspect));
        if (aspect <= 16.0 / 9.0 + 1e-6) aspect = 0;
    }
    float multiplier = aspect > 0 ? (float)(aspect / (16.0 / 9.0)) : 1.0f;
    float output = (float)aspect;
    memcpy(dm_fps_state + 0x38, &multiplier, sizeof multiplier);
    memcpy(dm_fps_state + 0x3c, &output, sizeof output);
    atomic_store(&g_display_aspect, output);
    atomic_store(&g_display_ready, 1);
    if (aspect > 0) LOG("display: candidate camera aspect %.6f, multiplier %.6f; UI horizontal scale compensated; frame step unchanged", aspect, multiplier);
}

void dm_display_apply(void) {
    pthread_mutex_lock(&g_display_lock);
    g_display_loaded = 1;
    display_activate();
    pthread_mutex_unlock(&g_display_lock);
}

void dm_display_configure(double width, double height) {
    if (atomic_load(&g_display_ready) || !(width > 0 && height > 0) || !isfinite(width) || !isfinite(height)) return;
    pthread_mutex_lock(&g_display_lock);
    g_display_width = width; g_display_height = height;
    if (g_display_loaded) display_activate();
    pthread_mutex_unlock(&g_display_lock);
}

double dm_display_output_aspect(void) { return atomic_load(&g_display_aspect); }
