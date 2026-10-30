// Display policy and geometry on synthetic module memory; no game or UI.
#include "../dm.h"
#include "../display_mode.h"
#include <assert.h>
#include <sys/wait.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
uint8_t *dm_fps_state;

static void policy(int which) {
    uint8_t *memory = calloc(1, 0x8000);
    assert(memory);
    g_nmod = 1; strcpy(g_mod[0].name, "main");
    strcpy(g_mod[0].build_id, "fe941ed5ba14be5d505698da1bbf4fe7");
    g_mod[0].base = memory; g_mod[0].fps_state_off = 0x4000;
    g_mod[0].display_aspect = 1; dm_fps_state = memory + 0x4000;
    assert(dm_display_aspect_candidate());
    assert(!dm_display_aspect_qualified());
    if (which == 1) g_mod[0].build_id[0] = '0';
    if (which == 2) g_mod[0].display_aspect = 0;
    if (which == 3) dm_fps_state = memory;
    if (which == 4) unsetenv("DM_DISPLAY_WIDE"); else setenv("DM_DISPLAY_WIDE", "1", 1);
    dm_display_configure(NAN, 900);
    dm_display_configure(1950, 900);
    // The screen may arrive before the iOS background loader: no module reads or writes yet.
    assert(!dm_display_output_aspect());
    dm_display_apply();
    float multiplier, aspect;
    memcpy(&multiplier, memory + 0x4038, 4); memcpy(&aspect, memory + 0x403c, 4);
    if (which >= 1 && which <= 3) {
        assert(!dm_display_aspect_candidate() && !dm_display_output_aspect());
        assert(multiplier == 0 && aspect == 0); // env cannot grant missing / wrong-build stubs
    } else if (which == 4) {
        assert(multiplier == 1 && aspect == 0 && !dm_display_output_aspect());
    } else {
        assert(fabsf(multiplier - 1.21875f) < 1e-6f);
        assert(fabs(dm_display_output_aspect() - 1950.0/900) < 1e-6);
        dm_display_configure(3200, 900);
        assert(dm_display_output_aspect() == aspect); // fixed camera/UI aspect, resize only fits with borders
        assert(*(float *)(memory + 0x4000) == 0); // display mod never enables frame-step / FPS changes
    }
    free(memory);
}

int main(void) {
    dm_display_rect r = dm_display_fit(16, 9, 2868, 1320);
    assert(r.width == 2347 && r.height == 1320 && r.x == 260 && r.y == 0);
    r = dm_display_fit(1952, 900, 2868, 1320);
    assert(r.height == 1320 && r.width < 2868); // formerly stretched near matches under 1%
    r = dm_display_fit(4, 3, 1920, 1080);
    assert(r.x == 240 && r.y == 0 && r.width == 1440 && r.height == 1080);
    r = dm_display_fit(16, 9, 1200, 1200);
    assert(r.x == 0 && r.y == 262 && r.width == 1200 && r.height == 675);
    assert(dm_display_fit(0, 9, 1920, 1080).width == 0);
    assert(dm_display_fit(16, 9, INFINITY, 1080).width == 0);
    for (int i = 0; i < 5; i++) {
        pid_t child = fork(); assert(child >= 0);
        if (!child) { policy(i); _exit(0); }
        int status; assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("display aspect-fit, build/stub gates and unchanged game timing passed");
}
