#include "dm.h"
#include "display_mode.h"
#include <stdatomic.h>
#include <TargetConditionals.h>

extern uint8_t *dm_fps_state;
static double g_display_width, g_display_height;
static pthread_mutex_t g_display_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_display_loaded;
static _Atomic int g_display_ready;
static double g_display_pending;
static int g_display_wide;
static float g_display_last_factor = 1;

int dm_display_aspect_candidate(void) {
    // Installation is evidence of original-byte checks, not visual approval.
    if (strcmp(dm_main_build(), "fe941ed5ba14be5d505698da1bbf4fe7")) return 0;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main"))
        return g_mod[i].display_aspect == 4 && dm_fps_state && g_mod[i].fps_state_off &&
               g_mod[i].base + g_mod[i].fps_state_off == dm_fps_state;
    return 0;
}

int dm_display_aspect_qualified(void) {
    // Exact-build hooks admit only active local one-player GP. Mac live resize,
    // original HUD and real two-player proportional fallback passed private QA.
#if TARGET_OS_OSX
    return dm_display_aspect_candidate();
#else
    // No iPhone gameplay qualification has been performed.
    return 0;
#endif
}

static void display_request(void) {  // caller holds g_display_lock
    double aspect = g_display_wide ? g_display_width / g_display_height : 0;
    if (aspect > 0) {
        aspect = fmax(16.0 / 9.0, fmin(43.0 / 18.0, aspect));
        if (aspect <= 16.0 / 9.0 + 1e-6) aspect = 0;
    }
    g_display_pending = aspect;
}

static void display_publish(void) { // caller holds g_display_lock; game frame boundary only
    float multiplier = g_display_pending > 0 ? (float)(g_display_pending / (16.0 / 9.0)) : 1.0f;
    float output = (float)g_display_pending;
    memcpy(dm_fps_state + 0x38, &multiplier, sizeof multiplier);
    memcpy(dm_fps_state + 0x3c, &output, sizeof output);
    // The first camera or UI draw of the next game frame latches this request.
    __atomic_store_n((uint32_t *)(dm_fps_state + 0x40), 0, __ATOMIC_RELEASE);
}

static void display_activate(void) {  // caller holds g_display_lock; modules are immutable after preload
    if (atomic_load(&g_display_ready) || !(g_display_width > 0 && g_display_height > 0)) return;
    if (!dm_display_aspect_candidate()) return;
    const char *wide = getenv("DM_DISPLAY_WIDE");
    // A developer can exercise the byte-verified candidate in an isolated run.
    // Neither this env var nor preferences can grant missing rewrite stubs.
    g_display_wide = wide && !strcmp(wide, "1");
    display_request(); display_publish();
    atomic_store(&g_display_ready, 1);
    if (g_display_pending > 0) LOG("display: candidate camera aspect %.6f; camera/UI latch one aspect per game frame; frame step unchanged", g_display_pending);
}

void dm_display_apply(void) {
    pthread_mutex_lock(&g_display_lock);
    g_display_loaded = 1;
    display_activate();
    pthread_mutex_unlock(&g_display_lock);
}

void dm_display_configure(double width, double height) {
    if (!(width > 0 && height > 0) || !isfinite(width) || !isfinite(height)) return;
    pthread_mutex_lock(&g_display_lock);
    g_display_width = width; g_display_height = height;
    if (atomic_load(&g_display_ready)) display_request();
    else if (g_display_loaded) display_activate();
    pthread_mutex_unlock(&g_display_lock);
}

void dm_display_set_wide(int enabled) {
    pthread_mutex_lock(&g_display_lock);
    g_display_wide = enabled != 0;
    if (atomic_load(&g_display_ready)) display_request();
    pthread_mutex_unlock(&g_display_lock);
}

double dm_display_output_aspect(void) {
    if (!atomic_load(&g_display_ready)) return 0;
    pthread_mutex_lock(&g_display_lock);
    float factor;
    memcpy(&factor, dm_fps_state + 0x40, sizeof factor);
    // Games can re-present an unchanged frame while unfocused, without asking
    // either projection hook to build a new picture. Keep that picture's aspect.
    if (factor == 0) factor = g_display_last_factor;
    if (!isfinite(factor) || factor < 1 || factor > 1.343751f) factor = 1;
    g_display_last_factor = factor;
    double aspect = factor > 1.000001f ? factor * (16.0 / 9.0) : 0;
    static double last = -1;
    if (getenv("DM_DISPLAY_TRACE") && last != aspect) {
        LOG("display: frame aspect %.6f (%s)", aspect, aspect > 0 ? "wide local GP" : "proportional fallback"); last = aspect;
    }
    display_publish();
    pthread_mutex_unlock(&g_display_lock);
    return aspect;
}
