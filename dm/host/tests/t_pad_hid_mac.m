// pad_hid_mac.inc with front_mac.m's hooks stubbed: player slots, publish-on-change, focus release / resume, DM_PAD_MERGE and removal, with fake devices (no controller).
// --live [seconds]: the real IOHIDManager instead, printing what each player would get from a connected wired pad (press its buttons to check the mapping; no game needed).
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>   // before the fake below renames the input-callback registration
#include "../controls_map.h"
#include "../pad_slots.h"
#include <stdio.h>
static int g_live, checks, failures, logs;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "pad hid mac failed at %d\n", __LINE__); } } while (0)
#define LOG(...) do { logs++; if (g_live) { printf(__VA_ARGS__); printf("\n"); fflush(stdout); } } while (0)
static int g_input_on = 1, g_merge;
static pad_slots g_slots;
static dm_controls g_controls;
static NSArray<NSString *> *(^g_controls_extra_pads)(void);
static int published, players_mask; static uint64_t pub_buttons[DM_PLAYERS]; static int32_t pub_axes[DM_PLAYERS][4];
void dm_pad_set_player(int p, uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    published++; pub_buttons[p] = b; int32_t a[4] = {lx, ly, rx, ry}; memcpy(pub_axes[p], a, sizeof a);
    if (g_live) { printf("player %d: buttons %#llx sticks %d %d %d %d\n", p + 1, (unsigned long long)b, lx, ly, rx, ry); fflush(stdout); }
}
void dm_pad_players(uint32_t mask) { players_mask = (int)mask; }
static int pad_supported(GCController *c) { return c.physicalInputProfile.allButtons.count != 0; }
static void npad_name(int p, char *out, size_t cap) { snprintf(out, cap, "%d", p); }
static void hid_pads_merge(uint64_t *m, int32_t axes[4]);
static void pad_merged(uint64_t *m, int32_t axes[4]) { hid_pads_merge(m, axes); }
static void pad_publish(int p, uint64_t m, int32_t axes[4]) { dm_controls_sticks(&g_controls, axes); dm_pad_set_player(p, dm_controls_buttons(&g_controls, m), axes[0], axes[1], axes[2], axes[3]); }
static int registered;
static void fake_register(IOHIDDeviceRef d, uint8_t *report, CFIndex n, IOHIDReportCallback cb, void *ctx);
#define IOHIDDeviceRegisterInputReportCallback fake_register
#include "../pad_hid_mac.inc"
#undef IOHIDDeviceRegisterInputReportCallback
static void fake_register(IOHIDDeviceRef d, uint8_t *report, CFIndex n, IOHIDReportCallback cb, void *ctx) {
    if (g_live) IOHIDDeviceRegisterInputReportCallback(d, report, n, cb, ctx); else registered += cb ? 1 : -1;
}
static DmHidPad *fake_pad(int i, const char *name) {
    DmHidPad *d = &g_hid_pads[i]; memset(d, 0, sizeof *d);
    d->device = (__bridge_retained IOHIDDeviceRef)[NSObject new]; snprintf(d->name, sizeof d->name, "%s", name); registered++;
    return d;
}
static void report(DmHidPad *d, const uint8_t r[8]) { hid_pad_report(d, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0, (uint8_t *)r, 8); }
int main(int argc, char **argv) { @autoreleasepool {
    dm_controls_defaults(&g_controls);
    if (argc > 1 && !strcmp(argv[1], "--live")) {
        g_live = 1; double seconds = argc > 2 ? atof(argv[2]) : 10;
        hid_pads_start(); if (!g_hid_manager) return 1;
        printf("listening %.0f s for wired Switch pads GameController does not list (DM_PAD_HID); GameController lists %lu controllers\n", seconds, (unsigned long)GCController.controllers.count);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
        for (NSString *line in g_controls_extra_pads()) printf("Controls window: %s\n", line.UTF8String);
        return !hid_pads_any();
    }
    const uint8_t idle[8] = {0, 0, 0x0f, 0x80, 0x80, 0x80, 0x80, 0}, a_up[8] = {0x04, 0, 0x00, 0x80, 0x00, 0x80, 0x80, 0}, home[8] = {0, 0x10, 0x0f, 0x80, 0x80, 0x80, 0x80, 0};
    // A pad takes player 1 and publishes on its first report, then only on a change
    DmHidPad *d = fake_pad(0, "NSW wired controller");
    hid_pads_yield(nil); hid_pads_claim();
    CHECK(pad_slot_of(&g_slots, d) == 0); CHECK(players_mask == 1); CHECK(published == 0);   // nothing decoded yet: nothing to publish
    report(d, idle); CHECK(published == 1 && pub_buttons[0] == 0);
    for (int i = 0; i < 100; i++) report(d, idle);
    CHECK(published == 1);   // the 125 Hz idle stream publishes nothing more
    report(d, a_up); CHECK(published == 2 && pub_buttons[0] == (DM_BTN_A | DM_BTN_UP) && pub_axes[0][1] == DM_STICK_MAX);
    report(d, home); CHECK(published == 3 && pub_buttons[0] == 0);   // Home is a Controls source only, unbound by default
    // Focus: released while away, its current state published again on return
    g_input_on = 0; report(d, a_up); hid_pads_release(); CHECK(pub_buttons[0] == 0 && pub_axes[0][1] == 0);
    int before = published; report(d, idle); report(d, a_up); CHECK(published == before);
    g_input_on = 1; hid_pads_resume(); CHECK(pub_buttons[0] == (DM_BTN_A | DM_BTN_UP));
    // A second pad is player 2; Controls… resetting the slots gives both their players back
    DmHidPad *e = fake_pad(1, "HORIPAD S");
    hid_pads_claim(); CHECK(pad_slot_of(&g_slots, e) == 1); CHECK(players_mask == 3);
    report(e, idle); CHECK(pub_buttons[1] == 0);
    memset(&g_slots, 0, sizeof g_slots); hid_pads_claim(); CHECK(pad_slot_of(&g_slots, d) == 0 && pad_slot_of(&g_slots, e) == 1);
    // Bindings and stick settings apply as to any controller
    g_controls.invert_ly = 1; report(d, idle); report(d, a_up); CHECK(pub_axes[0][1] == -DM_STICK_MAX); g_controls.invert_ly = 0;
    // Removal frees the player and leaves nothing pressed
    report(d, a_up);
    IOHIDDeviceRef dev = d->device; CFRetain(dev); hid_pad_removed(NULL, kIOReturnSuccess, NULL, dev); CFRelease(dev);
    CHECK(!g_hid_pads[0].device); CHECK(pad_slot_of(&g_slots, d) < 0); CHECK(pub_buttons[0] == 0); CHECK(players_mask == 2); CHECK(registered == 1);
    // DM_PAD_MERGE: every pad into player 1, buttons ORed, the stronger deflection per axis
    g_merge = 1; d = fake_pad(0, "NSW wired controller");
    const uint8_t b_left[8] = {0x02, 0, 0x0f, 0x40, 0x80, 0x80, 0x80, 0}, x_right[8] = {0x08, 0, 0x0f, 0xff, 0x80, 0x80, 0x80, 0};
    report(d, b_left); report(e, x_right);
    CHECK(pub_buttons[0] == (DM_BTN_B | DM_BTN_X)); CHECK(pub_axes[0][0] == DM_STICK_MAX);
    dev = e->device; CFRetain(dev); hid_pad_removed(NULL, kIOReturnSuccess, NULL, dev); CFRelease(dev);
    CHECK(pub_buttons[0] == DM_BTN_B && pub_axes[0][0] < 0);   // what the other pad still holds stays, the removed one's is gone
    printf("pad hid mac: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}}
