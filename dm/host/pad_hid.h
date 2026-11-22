// Wired "input-only" Switch controllers (PowerA, HORI, PDP, ZUIKI): plain USB HID gamepads that a Switch reads without the Pro Controller protocol and that macOS
// GameController does not list (on macOS 27.2 a PowerA "NSW wired controller" 20D6:A713 shows GameControllerSupportedHIDDevice = No and GCController.controllers stays
// empty), so without pad_hid_mac.inc the game never sees them. Pure, so tests/t_pad_hid.c checks it without a controller.
// The IDs are SDL's k_eControllerType_SwitchInputOnlyController list and the report is SDL's SwitchInputOnlyControllerStatePacket_t (SDL_hidapi_switch.c,
// HandleInputOnlyControllerState): 8 bytes, no report ID: buttons 1..14 in bytes 0-1 (Y B A X L R ZL ZR, − + LS RS Home Capture), byte 2 the hat (0 up, clockwise to 7;
// 8..15 centered), bytes 3-6 LX LY RX RY (0..255, 0x80 centered, Y grows downward), byte 7 vendor. Checked against 20D6:A713's report descriptor and idle report
// (00 00 0f 80 80 80 80 00, 125 Hz); the other IDs are SDL's and untried here. No output or feature report is ever sent: these pads have no rumble, IMU or LEDs to drive.
#pragma once
#include "dm_input.h"
#include <stddef.h>
#include <stdint.h>

static const uint32_t dm_hid_pad_ids[] = {   // vendor << 16 | product
    0x0e6f0180, 0x0e6f0181, 0x0e6f0184, 0x0e6f0185, 0x0e6f0187, 0x0e6f0188,                          // PDP Faceoff / Fight Pad Pro / Rock Candy / Afterglow wired
    0x0f0d0092, 0x0f0d00aa, 0x0f0d00c1, 0x0f0d00f0,                                                  // HORI Pokkén DX, RAP V Hayabusa (Switch mode), HORIPAD, Taiko
    0x20d6a711, 0x20d6a712, 0x20d6a713, 0x20d6a714, 0x20d6a715, 0x20d6a716, 0x20d6a718,             // PowerA wired / Fusion (USB mode) / Spectra / Nano
    0x33dd0001, 0x33dd0002, 0x33dd0003,                                                              // ZUIKI MasCon
};
static inline int dm_hid_pad_known(int vendor, int product) {
    uint32_t id = (uint32_t)(vendor & 0xffff) << 16 | (uint32_t)(product & 0xffff);
    for (size_t i = 0; i < sizeof dm_hid_pad_ids / sizeof *dm_hid_pad_ids; i++) if (dm_hid_pad_ids[i] == id) return 1;
    return 0;
}
// 0..255 with 0x80 centered → -DM_STICK_MAX..DM_STICK_MAX, both ends reached and the center exactly 0 (GameController's axes reach the same range, pad_axis)
static inline int32_t dm_hid_pad_axis(uint8_t v) { int d = (int)v - 128; return d < 0 ? d * DM_STICK_MAX / 128 : d * DM_STICK_MAX / 127; }
// The controller's raw buttons in the Controls source space (bits 0..15 as DM_BTN_*, 18 Home, 19 Capture: the sources dm_controls_buttons remaps, as joycon_protocol.h's
// dm_joycon_extra_buttons gives them) and its sticks, up positive as on the Switch. 0 for a report too short to be one.
static inline int dm_hid_pad_decode(const uint8_t *r, size_t n, uint64_t *buttons, int32_t axes[4]) {
    if (n < 7) return 0;
    static const uint64_t bit[14] = {DM_BTN_Y, DM_BTN_B, DM_BTN_A, DM_BTN_X, DM_BTN_L, DM_BTN_R, DM_BTN_ZL, DM_BTN_ZR,
                                     DM_BTN_MINUS, DM_BTN_PLUS, DM_BTN_LS, DM_BTN_RS, 1ull << 18, 1ull << 19};
    static const uint64_t hat[8] = {DM_BTN_UP, DM_BTN_UP | DM_BTN_RIGHT, DM_BTN_RIGHT, DM_BTN_RIGHT | DM_BTN_DOWN,
                                    DM_BTN_DOWN, DM_BTN_DOWN | DM_BTN_LEFT, DM_BTN_LEFT, DM_BTN_LEFT | DM_BTN_UP};
    unsigned held = r[0] | (unsigned)r[1] << 8; uint64_t m = 0;
    for (int i = 0; i < 14; i++) if (held >> i & 1) m |= bit[i];
    if ((r[2] & 15) < 8) m |= hat[r[2] & 15];
    *buttons = m;
    axes[0] = dm_hid_pad_axis(r[3]); axes[1] = -dm_hid_pad_axis(r[4]);
    axes[2] = dm_hid_pad_axis(r[5]); axes[3] = -dm_hid_pad_axis(r[6]);
    return 1;
}
