// Synthetic protocol vectors: no Bluetooth device or game data needed.
#include "../joycon_rumble.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void expect(dm_vibration value, const uint8_t expected[4]) {
    uint8_t encoded[4]; dm_joycon_encode_rumble(value, encoded);
    assert(!memcmp(encoded, expected, sizeof encoded));
}
int main(void) {
    expect((dm_vibration){0, 160, 0, 320}, (uint8_t[]){0, 1, 0x40, 0x40});
    expect((dm_vibration){1, 160, 1, 320}, (uint8_t[]){0, 0xc9, 0x40, 0x72});
    expect((dm_vibration){1, 80, 1, 160}, (uint8_t[]){0x80, 0xc8, 0x20, 0x72});
    expect((dm_vibration){1, 1, 1, 1}, (uint8_t[]){4, 0xc8, 1, 0x72});
    expect((dm_vibration){1, 1e30f, 1, 1e30f}, (uint8_t[]){0xfc, 0xc9, 0x7f, 0x72});
    expect((dm_vibration){2, NAN, 4, -1}, (uint8_t[]){0, 0xc9, 0x40, 0x72});
    expect((dm_vibration){NAN, 160, INFINITY, 320}, (uint8_t[]){0, 1, 0x40, 0x40});
    expect((dm_vibration){-1, 160, -4, 320}, (uint8_t[]){0, 1, 0x40, 0x40});
    expect((dm_vibration){514.0f/65535, 160, 514.0f/65535, 320}, (uint8_t[]){0, 3, 0xc0, 0x40});
    expect((dm_vibration){0.01f, 160, 0.01f, 320}, (uint8_t[]){0, 5, 0x40, 0x41});
    unsigned previous = 0;
    for (int i = 0; i <= 65535; i++) {
        unsigned amplitude = dm_joycon_rumble_amplitude((float)i / 65535.0f);
        assert(amplitude >= previous && amplitude <= 100);
        previous = amplitude;
        uint8_t out[4]; dm_joycon_encode_rumble((dm_vibration){(float)i/65535, 160, (float)i/65535, 320}, out);
        if (amplitude) {
            assert((out[1] >> 1) == amplitude);
            assert(((unsigned)(out[3] - 0x40) * 2 + (out[2] >> 7)) == amplitude);
            assert((out[2] & 0x7f) == 0x40);
        }
    }
    puts("Joy-Con rumble protocol vectors and amplitude sweep passed");
    return 0;
}
