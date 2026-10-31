// Rewriter-generated camera/UI machine code on synthetic memory. No game data.
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

static void *capture_layout(void *out, const void *info, unsigned flags) {
    if (!info || !((uintptr_t *)out)[3]) return out;
    assert((flags & 0x11) == 0x11);
    memcpy(out, info, 0x100);
    return out;
}

int main(void) {
    size_t size = 0x1400000;
    uint8_t *image = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(image != MAP_FAILED);
    uint32_t code[] = {CODE_WORDS};
    memcpy(image + 0x10000, code, sizeof code);
    *(uint32_t *)(image + 0x3cb1b8) = 0xd65f03c0;
    const unsigned entries[] = {0x59e198, 0x73f3bc};
    for (unsigned i = 0; i < 2; i++) {
        unsigned entry = entries[i];
        *(uint32_t *)(image + entry + 4) = 0x910183ff;
        *(uint32_t *)(image + entry + 8) = 0x58000050;
        *(uint32_t *)(image + entry + 12) = 0xd61f0200;
        void *fn = (void *)capture_layout;
        memcpy(image + entry + 16, &fn, sizeof fn);
    }
    *(uintptr_t *)(image + 0x12f6388) = (uintptr_t)(image + 0x21000);
    *(uintptr_t *)(image + 0x21000) = (uintptr_t)(image + 0x22000);
    *(uintptr_t *)(image + 0x22020) = (uintptr_t)(image + 0x23000);
    *(uintptr_t *)(image + 0x25240) = (uintptr_t)(image + 0x26000);
    *(uintptr_t *)(image + 0x26010) = (uintptr_t)(image + 0x27000);
    *(uintptr_t *)(image + 0x241b0) = (uintptr_t)(image + 0x28000);
    *(uintptr_t *)(image + 0x28238) = (uintptr_t)(image + 0x29000);
    *(uintptr_t *)(image + 0x290b0) = (uintptr_t)(image + 0x2a000);
    *(uintptr_t *)(image + 0x28218) = (uintptr_t)(image + 0x2b000);
    sys_icache_invalidate(image, size);
    assert(mprotect(image, size, PROT_READ | PROT_EXEC) == 0);
    assert(mprotect(image + 0x20000, 0x10000, PROT_READ | PROT_WRITE) == 0);
    float (*projection)(float, float) = (void *)(image + 0x10000);
    void *(*layouts[])(void *, const void *, unsigned) = {(void *)(image + HUD_OFFSET), (void *)(image + HUD2_OFFSET)};
    // End the 8-byte-aligned input at a guard page: copying its used fields may
    // not read any trailing padding beyond +0xf7.
    uint8_t *source = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(source != MAP_FAILED && mprotect(source + 0x4000, 0x4000, PROT_NONE) == 0);
    float *info = (float *)(source + 0x4000 - 0xf8);
    float original[62], result[64];
    for (unsigned i = 0; i < 62; i++) original[i] = (float)(i + 1);
    original[20] = 1;
    memcpy(info, original, sizeof original);
    for (unsigned l = 0; l < 2; l++) {
        memset(result, 0, sizeof result);
        assert(layouts[l](result, info, 0x10) == result && result[20] == 0);
        ((uintptr_t *)result)[3] = 1;
        assert(layouts[l](result, NULL, 0x10) == result && result[20] == 0);
    }
    float factors[] = {0, 1, 1.21875f, 1.25f, 1.34375f};
    float ratios[] = {16.0f/9.0f, 8.0f/9.0f, 32.0f/9.0f};
    for (int scene = 0; scene < 3; scene++) {
        *(uintptr_t *)(image + 0x23008) = scene ? (uintptr_t)(image + 0x24000) : 0;
        *(uintptr_t *)(image + 0x24000) = (uintptr_t)(image + (scene == 2 ? 0x125e158 : 0x125a060));
        for (int mode = 0; mode < 14; mode++) {
            memset(image + 0x27000, 0, 12);
            if (mode > 0 && mode < 4) *(uint32_t *)(image + 0x27000 + (mode - 1) * 4) = mode == 3 ? 5 : 1;
            *(uintptr_t *)(image + 0x22028) = mode == 4 ? 0 : (uintptr_t)(image + 0x25000);
            *(uint32_t *)(image + 0x2a080) = mode >= 5 && mode <= 8 ? (unsigned)(mode == 5 ? 0 : mode - 4) : 1;
            *(uintptr_t *)(image + 0x2b050) = mode == 13 ? 0 : (uintptr_t)(image + 0x2c000);
            *(uint32_t *)(image + 0x2c038) = mode >= 9 && mode <= 12 ? (unsigned[]){0,2,5,7}[mode - 9] : 6;
            for (unsigned f = 0; f < sizeof factors / sizeof *factors; f++) {
                float factor = factors[f], effective = scene == 2 && mode == 0 && factor > 0 ? factor : 1;
                memcpy(image + 0x20038, &factor, 4); *(float *)(image + 0x20040) = 0;
                for (unsigned r = 0; r < sizeof ratios / sizeof *ratios; r++)
                    assert(fabsf(projection(1, ratios[r]) - ratios[r] * effective) < 1e-5f);
                for (unsigned l = 0; l < 2; l++) {
                    assert(layouts[l](result, info, 0x10) == result);
                    for (unsigned i = 20; i < 24; i++) assert(fabsf(result[i] - original[i] / effective) < 1e-5f);
                    for (unsigned i = 0; i < 62; i++) if (i < 20 || i >= 24) assert(result[i] == original[i]);
                    assert(result[62] == 0 && result[63] == 0);
                }
                float next = 1.25f; memcpy(image + 0x20038, &next, 4);
                for (unsigned draw = 0; draw < 3; draw++) {
                    layouts[draw % 2](result, info, 0x10);
                    assert(fabsf(result[20] - 1 / effective) < 1e-6f);
                }
                assert(!memcmp(info, original, sizeof original));
                *(float *)(image + 0x20040) = 0;
                float next_effective = scene == 2 && mode == 0 ? next : 1;
                layouts[0](result, info, 0x10);
                assert(fabsf(result[20] - 1 / next_effective) < 1e-6f);
                assert(fabsf(projection(1, ratios[0]) - ratios[0] * next_effective) < 1e-5f);
            }
        }
    }
    assert(munmap(source, 0x8000) == 0 && munmap(image, size) == 0);
    puts("native camera and HUD stubs passed");
    return 0;
}
