// pad_hid.h: the wired Switch pads GameController does not list, decoded without a controller. The idle report is the one a PowerA 20D6:A713 sends.
#include "../pad_hid.h"
#include "../controls_map.h"
#include <stdio.h>
static int checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "pad hid failed at %d\n", __LINE__); } } while (0)
static uint64_t buttons_of(const uint8_t r[8]) { uint64_t b = ~0ull; int32_t a[4]; return dm_hid_pad_decode(r, 8, &b, a) ? b : ~0ull; }
int main(void) {
    CHECK(dm_hid_pad_known(0x20d6, 0xa713)); CHECK(dm_hid_pad_known(0x0f0d, 0x00c1)); CHECK(dm_hid_pad_known(0x0e6f, 0x0180));
    CHECK(!dm_hid_pad_known(0x057e, 0x2009)); CHECK(!dm_hid_pad_known(0x045e, 0x0b20)); CHECK(!dm_hid_pad_known(0x20d6, 0x2009));   // Pro (GameController's), Xbox, a PowerA Xbox pad
    CHECK(sizeof dm_hid_pad_ids / sizeof *dm_hid_pad_ids == 20);   // SDL's k_eControllerType_SwitchInputOnlyController entries
    uint8_t idle[8] = {0x00, 0x00, 0x0f, 0x80, 0x80, 0x80, 0x80, 0x00}; uint64_t b = ~0ull; int32_t a[4] = {1, 1, 1, 1};
    CHECK(dm_hid_pad_decode(idle, sizeof idle, &b, a)); CHECK(b == 0); CHECK(!a[0] && !a[1] && !a[2] && !a[3]);
    CHECK(!dm_hid_pad_decode(idle, 6, &b, a)); CHECK(dm_hid_pad_decode(idle, 7, &b, a));   // the vendor byte is not needed
    // HID buttons 1..14 in report order: Y B A X L R ZL ZR − + LS RS Home Capture (Home / Capture as the Controls sources 18 / 19)
    const uint64_t want[14] = {DM_BTN_Y, DM_BTN_B, DM_BTN_A, DM_BTN_X, DM_BTN_L, DM_BTN_R, DM_BTN_ZL, DM_BTN_ZR, DM_BTN_MINUS, DM_BTN_PLUS, DM_BTN_LS, DM_BTN_RS, 1ull << 18, 1ull << 19};
    for (int i = 0; i < 14; i++) { uint8_t r[8]; memcpy(r, idle, 8); r[i / 8] = (uint8_t)(1u << (i % 8)); CHECK(buttons_of(r) == want[i]); }
    { uint8_t r[8]; memcpy(r, idle, 8); r[1] = 0xc0; CHECK(buttons_of(r) == 0); }   // the two padding bits after button 14
    // Hat: 0 up, clockwise; 8..15 centered. The high nibble is padding.
    const uint64_t hat[8] = {DM_BTN_UP, DM_BTN_UP | DM_BTN_RIGHT, DM_BTN_RIGHT, DM_BTN_RIGHT | DM_BTN_DOWN, DM_BTN_DOWN, DM_BTN_DOWN | DM_BTN_LEFT, DM_BTN_LEFT, DM_BTN_LEFT | DM_BTN_UP};
    for (int h = 0; h < 16; h++) { uint8_t r[8]; memcpy(r, idle, 8); r[2] = (uint8_t)(0xa0 | h); CHECK(buttons_of(r) == (h < 8 ? hat[h] : 0)); }
    // Sticks: both ends reach DM_STICK_MAX, Y up positive (HID Y grows downward)
    uint8_t r[8] = {0, 0, 0x0f, 0x00, 0x00, 0xff, 0xff, 0};
    CHECK(dm_hid_pad_decode(r, 8, &b, a)); CHECK(a[0] == -DM_STICK_MAX && a[1] == DM_STICK_MAX && a[2] == DM_STICK_MAX && a[3] == -DM_STICK_MAX);
    CHECK(dm_hid_pad_axis(0x81) > 0 && dm_hid_pad_axis(0x7f) < 0 && dm_hid_pad_axis(0x80) == 0);
    // Through the default Controls mapping: the face buttons keep their labels; Home and Capture stay off the game until bound
    dm_controls c; dm_controls_defaults(&c);
    { uint8_t p[8]; memcpy(p, idle, 8); p[0] = 0x0f; p[1] = 0x30; CHECK(dm_controls_buttons(&c, buttons_of(p)) == (DM_BTN_A | DM_BTN_B | DM_BTN_X | DM_BTN_Y)); }
    c.buttons[16] = 18;   // Home bound to Shake in Controls… (buttons[] is indexed by target: A..Down, then Shake)
    { uint8_t p[8]; memcpy(p, idle, 8); p[1] = 0x10; CHECK(dm_controls_buttons(&c, buttons_of(p)) == DM_BTN_SHAKE); }
    printf("pad hid: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
