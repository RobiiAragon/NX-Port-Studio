// Altered SDL-derived amplitude quantization for nxnative's Nintendo Joy-Con output.
// Frequency encoding follows the original protocol measurements cited below; unlike
// SDL's two-intensity rumble API, this keeps both guest frequencies for each motor.
// https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c
// https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/rumble_data_table.md
/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
#pragma once
#include "hle_haptics.h"
#include <math.h>
#include <stdint.h>

// The measured amplitude thresholds below are adapted from SDL's Switch driver,
// contributed by Valve under the zlib license above. Their index encodes both
// amplitudes: the high band uses index*2; the low band packs its parity separately.
static inline unsigned dm_joycon_rumble_amplitude(float value) {
    static const uint16_t thresholds[101] = {
        0, 514, 775, 921, 1096, 1303, 1550, 1843, 2192, 2606,
        3100, 3686, 4383, 5213, 6199, 7372, 7698, 8039, 8395, 8767,
        9155, 9560, 9984, 10426, 10887, 11369, 11873, 12398, 12947, 13520,
        14119, 14744, 15067, 15397, 15734, 16079, 16431, 16790, 17158, 17534,
        17918, 18310, 18711, 19121, 19540, 19967, 20405, 20851, 21308, 21775,
        22251, 22739, 23236, 23745, 24265, 24797, 25340, 25894, 26462, 27041,
        27633, 28238, 28856, 29488, 30134, 30794, 31468, 32157, 32861, 33581,
        34316, 35068, 35836, 36620, 37422, 38242, 39079, 39935, 40809, 41703,
        42616, 43549, 44503, 45477, 46473, 47491, 48531, 49593, 50679, 51789,
        52923, 54082, 55266, 56476, 57713, 58977, 60268, 61588, 62936, 64315,
        65535
    };
    if (!isfinite(value) || value <= 0) return 0;
    if (value >= 1) return 100;
    unsigned scaled = (unsigned)lroundf(value * 65535.0f);
    unsigned index = 0;
    while (index < 100 && scaled > thresholds[index]) index++;
    return index;
}

// Clamp the encoded value, avoiding underflow in the band-specific offsets.
// LF codes 1..127 represent 40.875885..626.286Hz, HF codes 4..508
// (in steps of four) represent 81.75177..1252.572Hz. These are device limits.
static inline unsigned dm_joycon_rumble_frequency(float value, int high) {
    if (!isfinite(value) || value <= 0) value = high ? 320.0f : 160.0f;
    long code = lround(log2((double)value / 10.0) * 32.0);
    long minimum = high ? 97 : 65, maximum = high ? 223 : 191;
    if (code < minimum) code = minimum;
    if (code > maximum) code = maximum;
    return high ? (unsigned)(code - 96) * 4 : (unsigned)(code - 64);
}

// One four-byte hardware motor block. The caller chooses left/right routing and
// supplies the report header, command sequence and periodic refresh separately.
static inline void dm_joycon_encode_rumble(dm_vibration value, uint8_t out[4]) {
    unsigned high_amplitude = dm_joycon_rumble_amplitude(value.amplitude_high);
    unsigned low_amplitude = dm_joycon_rumble_amplitude(value.amplitude_low);
    if (!high_amplitude && !low_amplitude) {
        out[0] = 0x00; out[1] = 0x01; out[2] = 0x40; out[3] = 0x40;
        return;
    }
    unsigned high_frequency = dm_joycon_rumble_frequency(value.frequency_high, 1);
    unsigned low_frequency = dm_joycon_rumble_frequency(value.frequency_low, 0);
    out[0] = (uint8_t)high_frequency;
    out[1] = (uint8_t)((high_amplitude * 2) | ((high_frequency >> 8) & 1));
    out[2] = (uint8_t)(low_frequency | ((low_amplitude & 1) << 7));
    out[3] = (uint8_t)(0x40 + low_amplitude / 2);
}
