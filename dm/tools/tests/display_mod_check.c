// Rewriter-generated camera/UI machine code on synthetic memory. No game data.
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

int main(void) {
    size_t size = 0xc00000;
    uint8_t *image = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(image != MAP_FAILED);
    uint32_t code[] = {CODE_WORDS};
    memcpy(image + 0x10000, code, sizeof code);
    // Synthetic continuation: return the computed aspect to the fixture.
    *(uint32_t *)(image + 0x3cb1b8) = 0xd65f03c0;
    // Original memcpy target is represented by a trampoline to the host memcpy.
    *(uint32_t *)(image + 0xb4e0b8) = 0x58000050;  // ldr x16,pc+8
    *(uint32_t *)(image + 0xb4e0bc) = 0xd61f0200;  // br x16
    void *copy = (void *)memcpy;
    memcpy(image + 0xb4e0c0, &copy, sizeof copy);
    sys_icache_invalidate(image, size);
    assert(mprotect(image, size, PROT_READ | PROT_EXEC) == 0);
    assert(mprotect(image + 0x20000, 0x4000, PROT_READ | PROT_WRITE) == 0);
    float (*projection)(float, float) = (void *)(image + 0x10000);
    void *(*hud)(void *, const void *, size_t) = (void *)(image + HUD_OFFSET);
    float factors[] = {0, 1, 1.21875f, 1.25f, 1.34375f};
    float ratios[] = {16.0f/9.0f, 8.0f/9.0f, 32.0f/9.0f};
    for (unsigned f = 0; f < sizeof factors / sizeof factors[0]; f++) {
        float factor = factors[f], effective = factor > 0 ? factor : 1;
        memcpy(image + 0x20038, &factor, sizeof factor);
        for (unsigned r = 0; r < sizeof ratios / sizeof ratios[0]; r++)
            assert(fabsf(projection(1, ratios[r]) - ratios[r] * effective) < 1e-5f);
        float matrix[12] = {1,0,0,0,0,1,0,0,0,0,1,0}, result[12];
        memset(result, 0xff, sizeof result);
        assert(hud(result, matrix, sizeof matrix) == result);
        assert(fabsf(result[0] - 1 / effective) < 1e-6f);
        assert(!memcmp(result + 1, matrix + 1, sizeof matrix - sizeof(float)));
    }
    assert(munmap(image, size) == 0);
    puts("native camera and HUD stubs passed");
    return 0;
}
