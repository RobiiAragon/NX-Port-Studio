// User control mappings shared by the Mac input adapter and its hardware-free tests.
#pragma once
#include "dm_input.h"
#include <math.h>
#include <string.h>

// GameController's Nintendo profiles expose the printed Nintendo A/B/X/Y names.
// Other extended profiles use the standard south=A/east=B/west=X/north=Y layout.
static inline int dm_controls_nintendo_profile(const char *category) {
    return category && (!strncmp(category,"Nintendo Switch",15) || !strcmp(category,"Switch Pro Controller"));
}
static inline uint64_t dm_controls_face_buttons(int nintendo,int a,int b,int x,int y) {
    return nintendo ? (a?DM_BTN_A:0)|(b?DM_BTN_B:0)|(x?DM_BTN_X:0)|(y?DM_BTN_Y:0)
                    : (a?DM_BTN_B:0)|(b?DM_BTN_A:0)|(x?DM_BTN_Y:0)|(y?DM_BTN_X:0);
}
enum { DM_CONTROL_COUNT = 25, DM_CONTROL_SHAKE = 24 };
typedef struct {
    int keys[DM_CONTROL_COUNT];       // Mac virtual key codes; -1 is unbound
    int buttons[17];                 // target A..Down, Shake -> source A..Down; -1 is unbound
    int swap_sticks, invert_lx, invert_ly, invert_rx, invert_ry, motion, combine;
} dm_controls;
static inline void dm_controls_defaults(dm_controls *c) {
    static const int keys[DM_CONTROL_COUNT] = {38,40,32,34,3,5,12,14,6,8,36,48,123,126,124,125,0,13,2,1,-1,-1,-1,-1,49};
    memset(c, 0, sizeof *c); memcpy(c->keys, keys, sizeof keys);
    for (int i = 0; i < 16; i++) c->buttons[i] = i;
    c->buttons[16] = -1; c->motion = 1;
}
static inline uint64_t dm_control_bit(int action) { return action < 16 ? 1ull << action : action == DM_CONTROL_SHAKE ? DM_BTN_SHAKE : 0; }
static inline uint64_t dm_controls_buttons(const dm_controls *c, uint64_t raw) {
    uint64_t mapped = 0;
    for (int i = 0; i < 17; i++) if (c->buttons[i] >= 0 && c->buttons[i] < 20 && (raw >> c->buttons[i] & 1))
        mapped |= i < 16 ? 1ull << i : DM_BTN_SHAKE;
    return mapped;
}
static inline void dm_controls_keyboard(const dm_controls *c, const unsigned char held[128], uint64_t *buttons, int32_t axes[4]) {
    int active[DM_CONTROL_COUNT] = {0}; *buttons = 0;
    for (int i = 0; i < DM_CONTROL_COUNT; i++) {
        int key = c->keys[i]; active[i] = key >= 0 && key < 128 && held[key];
        if (active[i]) *buttons |= dm_control_bit(i);
    }
    axes[0] = (active[18] - active[16]) * DM_STICK_MAX;
    axes[1] = (active[17] - active[19]) * DM_STICK_MAX;
    axes[2] = (active[22] - active[20]) * DM_STICK_MAX;
    axes[3] = (active[21] - active[23]) * DM_STICK_MAX;
}
static inline void dm_controls_sticks(const dm_controls *c, int32_t a[4]) {
    if (c->swap_sticks) { int32_t x = a[0], y = a[1]; a[0] = a[2]; a[1] = a[3]; a[2] = x; a[3] = y; }
    if (c->invert_lx) a[0] = -a[0]; if (c->invert_ly) a[1] = -a[1];
    if (c->invert_rx) a[2] = -a[2]; if (c->invert_ry) a[3] = -a[3];
}
// Apple GCMotion: acceleration is in G, rotation rate radians/s, attitude a quaternion.
// Nintendo SixAxisSensorState uses G, revolutions/s, revolutions and a 3x3 direction basis.
static inline void dm_motion_convert(dm_motion_state *out, const double acceleration[3], const double rotation[3], const double quaternion[4]) {
    const double tau = 6.2831853071795864769;
    memset(out, 0, sizeof *out);
    for (int i = 0; i < 3; i++) { out->acc[i] = (float)acceleration[i]; out->gyro[i] = (float)(rotation[i] / tau); }
    double x = quaternion[0], y = quaternion[1], z = quaternion[2], w = quaternion[3];
    double norm = sqrt(x*x + y*y + z*z + w*w);
    if (!isfinite(norm) || norm < 1e-9) { x = y = z = 0; w = 1; }
    else { x /= norm; y /= norm; z /= norm; w /= norm; }
    out->angle[0] = (float)(atan2(2*(w*x+y*z), 1-2*(x*x+y*y)) / tau);
    out->angle[1] = (float)(asin(fmax(-1, fmin(1, 2*(w*y-z*x)))) / tau);
    out->angle[2] = (float)(atan2(2*(w*z+x*y), 1-2*(y*y+z*z)) / tau);
    float d[9] = {1-2*(y*y+z*z), 2*(x*y+w*z), 2*(x*z-w*y),
                  2*(x*y-w*z), 1-2*(x*x+z*z), 2*(y*z+w*x),
                  2*(x*z+w*y), 2*(y*z-w*x), 1-2*(x*x+y*y)};
    memcpy(out->dir, d, sizeof d);
}
