// Output geometry and exact-build display-mod policy. Fullscreen and pixel
// resolution do not imply a wider camera or a faster simulation.
#pragma once
#include <math.h>

typedef struct { double x, y, width, height; } dm_display_rect;
static inline dm_display_rect dm_display_fit(double cw, double ch, double dw, double dh) {
    if (!(cw > 0 && ch > 0 && dw > 0 && dh > 0) ||
        !isfinite(cw) || !isfinite(ch) || !isfinite(dw) || !isfinite(dh)) return (dm_display_rect){0};
    double scale = fmin(dw / cw, dh / ch);
    double w = round(cw * scale), h = round(ch * scale);
    return (dm_display_rect){floor((dw - w) / 2), floor((dh - h) / 2), w, h};
}

int dm_display_aspect_candidate(void);  // installed camera/UI stubs, matching main build and state page
int dm_display_aspect_qualified(void);  // visual qualification on this platform, separate from byte verification
void dm_display_configure(double width, double height);  // latest effective drawable; adopted at the next game-frame boundary
void dm_display_set_wide(int enabled);  // live request, adopted at a game-frame boundary
void dm_display_apply(void);            // after loader initialization (iOS can supply the screen before it completes)
double dm_display_output_aspect(void);  // game enqueue only: take this frame's camera/UI latch, publish the next request; zero = native
